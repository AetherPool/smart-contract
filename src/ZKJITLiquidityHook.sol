// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IJITCoordinator} from "./interfaces/IJITCoordinator.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title ZKJITLiquidityHook
 * @notice Main hook orchestrator with JIT liquidity coordination and passive/active deposits
 * @dev Enhanced with deposit type selection and price-based liquidity calculations
 */
contract ZKJITLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencySettler for Currency;

    // ============ Module Contracts ============

    ILPPositionManager public immutable positionManager;
    IFHEConfigManager public immutable configManager;
    IDynamicFeeManager public immutable feeManager;
    IProfitManager public immutable profitManager;
    IJITCoordinator public immutable jitCoordinator;
    IFeeCalculator public immutable feeCalculator;

    // ============ Storage ============

    uint256 public currentSwapId;
    uint24 public currentAppliedFee;

    // ============ Structs for Stack Management ============

    struct JITExecutionParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 totalLiquidity;
    }

    // ============ Events ============

    event HookInitialized(
        address positionManager,
        address configManager,
        address feeManager,
        address profitManager,
        address jitCoordinator,
        address feeCalculator
    );

    event LiquidityDeposited(
        address indexed lp,
        PoolId indexed poolId,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        bool isJITEnabled
    );

    event LiquidityWithdrawn(
        address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    event SwapProcessed(PoolId indexed poolId, uint256 swapId, uint24 dynamicFee, uint256 eligibleLPs);
    event ActualFeesCollected(PoolId indexed poolId, uint256 swapId, uint256 fees0, uint256 fees1);

    // ============ Errors ============

    error MustUseDynamicFee();

    // ============ Callback Data ============

    struct AddLiquidityCallbackData {
        PoolKey poolKey;
        address sender;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        bool isJITEnabled;
    }

    struct RemoveLiquidityCallbackData {
        PoolKey poolKey;
        address withdrawer;
        uint256 tokenId;
        uint128 liquidityDelta;
    }

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        address _configManager,
        address _feeManager,
        address _profitManager,
        address _jitCoordinator,
        address _feeCalculator
    ) BaseHook(_poolManager) {
        positionManager = ILPPositionManager(_positionManager);
        configManager = IFHEConfigManager(_configManager);
        feeManager = IDynamicFeeManager(_feeManager);
        profitManager = IProfitManager(_profitManager);
        jitCoordinator = IJITCoordinator(_jitCoordinator);
        feeCalculator = IFeeCalculator(_feeCalculator);

        emit HookInitialized(
            _positionManager, _configManager, _feeManager, _profitManager, _jitCoordinator, _feeCalculator
        );
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    // ============ Hook Implementation (REFACTORED) ============

    /**
     * @notice Hook called before swap execution - REFACTORED to avoid stack too deep
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Calculate swap amount once
        uint128 swapAmount = _getSwapAmount(params);

        // Handle JIT liquidity injection
        uint256 eligibleCount = _handleJITInjection(key, sender, params, swapAmount);

        // Get and apply dynamic fee
        uint24 feeWithFlag = _applyDynamicFee();

        emit SwapProcessed(key.toId(), currentSwapId, currentAppliedFee, eligibleCount);

        return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), feeWithFlag);
    }

    /**
     * @notice Extract swap amount calculation to reduce stack depth
     */
    function _getSwapAmount(SwapParams calldata params) private pure returns (uint128) {
        return uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified));
    }

    /**
     * @notice Handle JIT injection logic separately
     * @return eligibleCount Number of eligible LPs
     */
    function _handleJITInjection(PoolKey calldata key, address sender, SwapParams calldata params, uint128 swapAmount)
        private
        returns (uint256 eligibleCount)
    {
        // Evaluate eligible LPs for JIT
        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, swapAmount);

        eligibleCount = eligibleLPs.length;

        if (eligibleCount == 0) {
            return 0;
        }

        // Create JIT operation
        currentSwapId = jitCoordinator.createMultiLPJIT(key, sender, swapAmount, params, eligibleLPs, contributions);

        // Get execution params
        JITExecutionParams memory jitParams = _getJITParams(currentSwapId);

        // Inject liquidity
        _executeJITInjection(key, currentSwapId, jitParams);

        // Record execution
        jitCoordinator.recordJITExecution(
            currentSwapId, jitParams.tickLower, jitParams.tickUpper, jitParams.totalLiquidity
        );

        return eligibleCount;
    }

    /**
     * @notice Get JIT execution parameters
     */
    function _getJITParams(uint256 swapId) private view returns (JITExecutionParams memory) {
        (int24 tickLower, int24 tickUpper, uint128 totalLiquidity,,) = jitCoordinator.getJITExecutionParams(swapId);

        return JITExecutionParams({tickLower: tickLower, tickUpper: tickUpper, totalLiquidity: totalLiquidity});
    }

    /**
     * @notice Execute JIT liquidity injection
     */
    function _executeJITInjection(PoolKey calldata key, uint256 swapId, JITExecutionParams memory params) private {
        // Add liquidity
        BalanceDelta delta = _injectLiquidity(key, swapId, params.tickLower, params.tickUpper, params.totalLiquidity);

        // Settle debts using claim tokens
        _settleJITDebts(key, delta);
    }

    /**
     * @notice Settle JIT debts by burning claim tokens
     */
    function _settleJITDebts(PoolKey calldata key, BalanceDelta delta) private {
        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), true);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), true);
        }
    }

    /**
     * @notice Apply dynamic fee and return flag
     */
    function _applyDynamicFee() private returns (uint24) {
        (uint24 dynamicFee,) = feeManager.getFee();
        currentAppliedFee = dynamicFee;
        return dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /**
     * @notice Inject liquidity into pool
     */
    function _injectLiquidity(PoolKey calldata key, uint256 swapId, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(swapId)
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, modParams, "");
        return delta;
    }

    /**
     * @notice Hook called after swap execution
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (currentSwapId > 0) {
            _handleJITRemoval(key, delta);
            currentSwapId = 0;
            currentAppliedFee = 0;
        }

        feeManager.updateMovingAverage();

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Handle JIT liquidity removal - extracted to reduce stack depth
     */
    function _handleJITRemoval(PoolKey calldata key, BalanceDelta swapDelta) private {
        // Get position details
        (bool isActive, int24 tickLower, int24 tickUpper, uint128 totalLiquidity) =
            jitCoordinator.getJITPositionForRemoval(currentSwapId);

        if (!isActive || totalLiquidity == 0) {
            return;
        }

        // Remove liquidity
        BalanceDelta removeDelta = _removeJITLiquidity(key, tickLower, tickUpper, totalLiquidity);

        // Take credits as claim tokens
        _takeJITCredits(key, removeDelta);

        // Process fees and get any auto-hedge transfers needed
        (address[] memory autoHedgeLPs, uint256[] memory amounts0, uint256[] memory amounts1) =
            jitCoordinator.removeJITLiquidityWithAutoHedge(key, currentSwapId, swapDelta, currentAppliedFee);

        // ✅ Transfer auto-hedge profits using claim tokens
        for (uint256 i = 0; i < autoHedgeLPs.length; i++) {
            if (amounts0[i] > 0 || amounts1[i] > 0) {
                _transferAutoHedgeProfits(key, autoHedgeLPs[i], amounts0[i], amounts1[i]);
            }
        }

        // Emit fees collected
        (uint256 fees0, uint256 fees1) = jitCoordinator.getJITFees(currentSwapId);
        emit ActualFeesCollected(key.toId(), currentSwapId, fees0, fees1);
    }

    /**
     * @notice Transfer auto-hedge profits using claim tokens
     * ✅ NEW: This is called by hook which has unlock context
     */
    function _transferAutoHedgeProfits(PoolKey calldata key, address lp, uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) {
            // Burn hook's claim tokens to cover the debt
            key.currency0.settle(poolManager, address(this), amount0, true);
            // Transfer actual tokens to LP
            key.currency0.take(poolManager, lp, amount0, false);
        }
        if (amount1 > 0) {
            key.currency1.settle(poolManager, address(this), amount1, true);
            key.currency1.take(poolManager, lp, amount1, false);
        }
    }

    /**
     * @notice Remove JIT liquidity from pool
     */
    function _removeJITLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 totalLiquidity)
        private
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(totalLiquidity)),
            salt: bytes32(currentSwapId)
        });

        (BalanceDelta removeDelta,) = poolManager.modifyLiquidity(key, removeParams, "");
        return removeDelta;
    }

    /**
     * @notice Take JIT credits as claim tokens
     */
    function _takeJITCredits(PoolKey calldata key, BalanceDelta delta) private {
        if (delta.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint256(int256(delta.amount0())), true);
        }
        if (delta.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint256(int256(delta.amount1())), true);
        }
    }

    // ============ Liquidity Functions ============

    /**
     * @notice Deposit liquidity with automatic liquidity calculation
     */
    function depositLiquidityWithAmounts(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bool isJITEnabled
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        (liquidity, amount0, amount1) =
            positionManager.calculateLiquidityForAmounts(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        bytes memory callbackData = abi.encodePacked(
            bytes1(0x01),
            abi.encode(
                AddLiquidityCallbackData({
                    poolKey: key,
                    sender: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0: amount0,
                    amount1: amount1,
                    isJITEnabled: isJITEnabled
                })
            )
        );

        bytes memory result = poolManager.unlock(callbackData);
        (tokenId, liquidity) = abi.decode(result, (uint256, uint128));

        emit LiquidityDeposited(msg.sender, key.toId(), tokenId, liquidity, amount0, amount1, isJITEnabled);

        return (tokenId, liquidity, amount0, amount1);
    }

    /**
     * @notice Withdraw liquidity using ERC1155 token
     */
    function withdrawLiquidity(PoolKey calldata key, uint256 tokenId, uint128 liquidityDelta)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory callbackData = abi.encodePacked(
            bytes1(0x02),
            abi.encode(
                RemoveLiquidityCallbackData({
                    poolKey: key,
                    withdrawer: msg.sender,
                    tokenId: tokenId,
                    liquidityDelta: liquidityDelta
                })
            )
        );

        bytes memory result = poolManager.unlock(callbackData);
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit LiquidityWithdrawn(msg.sender, key.toId(), tokenId, liquidityDelta, amount0, amount1);

        return (amount0, amount1);
    }

    /**
     * @notice Updated unlock callback to handle BOTH deposits and withdrawals
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        bytes1 callbackType = data[0];

        if (callbackType == 0x01) {
            return _handleAddLiquidity(data[1:]);
        } else if (callbackType == 0x02) {
            return _handleRemoveLiquidity(data[1:]);
        } else {
            revert("Unknown callback type");
        }
    }

    /**
     * @notice Handle add liquidity callback
     */
    function _handleAddLiquidity(bytes calldata data) private returns (bytes memory) {
        AddLiquidityCallbackData memory cb = abi.decode(data, (AddLiquidityCallbackData));

        // Transfer tokens from sender
        _transferTokensFromSender(cb);

        uint128 liquidity;

        if (cb.isJITEnabled) {
            // JIT: settle and mint claims
            _setupJITPosition(cb);
        } else {
            // Passive: add to pool
            liquidity = _setupPassivePosition(cb);
        }

        // Register position
        (uint256 tokenId, uint128 calculatedLiquidity) = positionManager.addLiquidity(
            cb.poolKey, cb.tickLower, cb.tickUpper, uint128(cb.amount0), uint128(cb.amount1), cb.sender, cb.isJITEnabled
        );

        // Update config manager
        configManager.updateDepositedAmounts(cb.poolKey, cb.sender, cb.amount0, cb.amount1);

        return abi.encode(tokenId, calculatedLiquidity);
    }

    /**
     * @notice Transfer tokens from sender to hook
     */
    function _transferTokensFromSender(AddLiquidityCallbackData memory cb) private {
        IERC20(Currency.unwrap(cb.poolKey.currency0)).transferFrom(cb.sender, address(this), cb.amount0);
        IERC20(Currency.unwrap(cb.poolKey.currency1)).transferFrom(cb.sender, address(this), cb.amount1);

        IERC20(Currency.unwrap(cb.poolKey.currency0)).approve(address(poolManager), cb.amount0);
        IERC20(Currency.unwrap(cb.poolKey.currency1)).approve(address(poolManager), cb.amount1);
    }

    /**
     * @notice Setup JIT position (settle and mint claims)
     */
    function _setupJITPosition(AddLiquidityCallbackData memory cb) private {
        cb.poolKey.currency0.settle(poolManager, address(this), cb.amount0, false);
        cb.poolKey.currency1.settle(poolManager, address(this), cb.amount1, false);

        cb.poolKey.currency0.take(poolManager, address(this), cb.amount0, true);
        cb.poolKey.currency1.take(poolManager, address(this), cb.amount1, true);
    }

    /**
     * @notice Setup passive position (add to pool)
     */
    function _setupPassivePosition(AddLiquidityCallbackData memory cb) private returns (uint128) {
        (uint128 liquidity,,) =
            positionManager.calculateLiquidityForAmounts(cb.poolKey, cb.tickLower, cb.tickUpper, cb.amount0, cb.amount1);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: cb.tickLower,
            tickUpper: cb.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(cb.poolKey, params, "");

        // Settle debts
        if (delta.amount0() < 0) {
            cb.poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            cb.poolKey.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }

        return liquidity;
    }

    /**
     * @notice Handle remove liquidity callback
     */
    function _handleRemoveLiquidity(bytes calldata data) private returns (bytes memory) {
        RemoveLiquidityCallbackData memory cb = abi.decode(data, (RemoveLiquidityCallbackData));

        ILPPositionManager.LPPosition memory position =
            positionManager.getPosition(cb.poolKey, cb.withdrawer, cb.tokenId);

        uint256 amount0;
        uint256 amount1;

        if (position.isJITEnabled) {
            (amount0, amount1) = _withdrawJITPosition(cb, position);
        } else {
            (amount0, amount1) = _withdrawPassivePosition(cb, position);
        }

        return abi.encode(amount0, amount1);
    }

    /**
     * @notice Withdraw JIT position
     */
    function _withdrawJITPosition(RemoveLiquidityCallbackData memory cb, ILPPositionManager.LPPosition memory)
        private
        returns (uint256, uint256)
    {
        (uint128 amt0, uint128 amt1) =
            positionManager.removeLiquidity(cb.poolKey, cb.tokenId, cb.liquidityDelta, cb.withdrawer);

        if (amt0 > 0) {
            cb.poolKey.currency0.settle(poolManager, address(this), amt0, true);
            cb.poolKey.currency0.take(poolManager, cb.withdrawer, amt0, false);
        }
        if (amt1 > 0) {
            cb.poolKey.currency1.settle(poolManager, address(this), amt1, true);
            cb.poolKey.currency1.take(poolManager, cb.withdrawer, amt1, false);
        }

        return (amt0, amt1);
    }

    /**
     * @notice Withdraw passive position
     */
    function _withdrawPassivePosition(
        RemoveLiquidityCallbackData memory cb,
        ILPPositionManager.LPPosition memory position
    ) private returns (uint256, uint256) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidityDelta: -int256(uint256(cb.liquidityDelta)),
            salt: bytes32(0)
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(cb.poolKey, params, "");

        uint256 amount0;
        uint256 amount1;

        if (delta.amount0() > 0) {
            amount0 = uint256(int256(delta.amount0()));
            cb.poolKey.currency0.take(poolManager, cb.withdrawer, amount0, false);
        }
        if (delta.amount1() > 0) {
            amount1 = uint256(int256(delta.amount1()));
            cb.poolKey.currency1.take(poolManager, cb.withdrawer, amount1, false);
        }

        positionManager.removeLiquidity(cb.poolKey, cb.tokenId, cb.liquidityDelta, cb.withdrawer);

        return (amount0, amount1);
    }

    // ============ View Functions ============

    function getModuleAddresses()
        external
        view
        returns (
            address _positionManager,
            address _configManager,
            address _feeManager,
            address _profitManager,
            address _jitCoordinator,
            address _feeCalculator
        )
    {
        return (
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator),
            address(feeCalculator)
        );
    }

    function getCurrentPrice(PoolKey calldata key) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return positionManager.getCurrentPrice(key);
    }

    function getPriceRatio(PoolKey calldata key) external view returns (uint256 ratio) {
        return positionManager.getPriceRatio(key);
    }

    function previewLiquidityForAmounts(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        return positionManager.calculateLiquidityForAmounts(key, tickLower, tickUpper, amount0Desired, amount1Desired);
    }

    function previewAmountsForLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return positionManager.calculateAmountsForLiquidity(key, tickLower, tickUpper, liquidity);
    }
}
