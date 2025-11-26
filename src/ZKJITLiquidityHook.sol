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
    // using CurrencyLibrary for Currency;
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

    event SwapProcessed(PoolId indexed poolId, uint256 swapId, uint24 dynamicFee, uint256 eligibleLPs);
    event ActualFeesCollected(PoolId indexed poolId, uint256 swapId, uint256 fees0, uint256 fees1);

    // ============ Errors ============

    error MustUseDynamicFee();
    error AddLiquidityThroughHook();

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

    struct SwapCallbackData {
        PoolKey poolKey;
        SwapParams params;
        address sender;
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

    // ============ Liquidity Deposit Functions ============

    /**
     * @notice Deposit liquidity with automatic liquidity calculation
     * @param key Pool key
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param isJITEnabled True for active JIT, false for passive liquidity
     * @return tokenId The position token ID
     * @return liquidity Calculated liquidity
     * @return amount0 Actual amount0 used
     * @return amount1 Actual amount1 used
     */
    function depositLiquidityWithAmounts(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bool isJITEnabled
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Calculate optimal liquidity and amounts based on current pool price
        (liquidity, amount0, amount1) =
            positionManager.calculateLiquidityForAmounts(key, tickLower, tickUpper, amount0Desired, amount1Desired);

        bytes memory callbackData = abi.encode(
            AddLiquidityCallbackData({
                poolKey: key,
                sender: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0: amount0,
                amount1: amount1,
                isJITEnabled: isJITEnabled
            })
        );

        bytes memory result = poolManager.unlock(callbackData);
        (tokenId, liquidity) = abi.decode(result, (uint256, uint128));

        emit LiquidityDeposited(msg.sender, key.toId(), tokenId, liquidity, amount0, amount1, isJITEnabled);

        return (tokenId, liquidity, amount0, amount1);
    }

    /**
     * @notice Deposit liquidity with specified liquidity amount (TO BE MADE REDUNDANT FOR NOW)
     * @param key Pool key
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param liquidity Liquidity amount
     * @param isJITEnabled True for active JIT, false for passive liquidity
     * @return tokenId The position token ID
     * @return amount0 Amount of token0 needed
     * @return amount1 Amount of token1 needed
     */
    function depositLiquidityWithLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool isJITEnabled
    ) external returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        // Calculate required token amounts for the specified liquidity
        (amount0, amount1) = positionManager.calculateAmountsForLiquidity(key, tickLower, tickUpper, liquidity);

        bytes memory callbackData = abi.encode(
            AddLiquidityCallbackData({
                poolKey: key,
                sender: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0: amount0,
                amount1: amount1,
                isJITEnabled: isJITEnabled
            })
        );

        bytes memory result = poolManager.unlock(callbackData);
        (tokenId,) = abi.decode(result, (uint256, uint128));

        emit LiquidityDeposited(msg.sender, key.toId(), tokenId, liquidity, amount0, amount1, isJITEnabled);

        return (tokenId, amount0, amount1);
    }

    // ============ Hook Implementation ============

    /**
     * @notice Hook called before swap execution
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint128 swapAmount =
            uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified));

        // Evaluate eligible LPs for JIT (only JIT-enabled positions)
        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, swapAmount);

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(0, 0);

        if (eligibleLPs.length > 0) {
            uint256 swapId =
                jitCoordinator.createMultiLPJIT(key, sender, swapAmount, params, eligibleLPs, contributions);

            currentSwapId = swapId;

            // Get execution parameters from coordinator
            (int24 tickLower, int24 tickUpper, uint128 totalLiquidity,,) = jitCoordinator.getJITExecutionParams(swapId);

            // Execute liquidity addition HERE where we have claim tokens
            ModifyLiquidityParams memory modParams = ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(totalLiquidity)),
                salt: bytes32(swapId)
            });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(key, modParams, "");

            // Settle the debts by burning our claim tokens
            // When adding liquidity, we OWE tokens to the pool (negative amounts = debts)
            if (delta.amount0() < 0) {
                // We owe token0 to the pool, burn our claims to settle
                key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), true);
            }
            if (delta.amount1() < 0) {
                // We owe token1 to the pool, burn our claims to settle
                key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), true);
            }

            // Record execution in coordinator
            jitCoordinator.recordJITExecution(swapId, tickLower, tickUpper, totalLiquidity);
        }

        // Get dynamic fee
        (uint24 dynamicFee,) = feeManager.getFee();
        uint24 feeWithFlag = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        currentAppliedFee = dynamicFee;

        emit SwapProcessed(key.toId(), currentSwapId, dynamicFee, eligibleLPs.length);

        return (this.beforeSwap.selector, beforeSwapDelta, feeWithFlag);
    }

    /**
     * @notice Callback for handling liquidity deposits
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        AddLiquidityCallbackData memory callbackData = abi.decode(data, (AddLiquidityCallbackData));

        // Transfer tokens from sender to this contract
        IERC20(Currency.unwrap(callbackData.poolKey.currency0)).transferFrom(
            callbackData.sender, address(this), callbackData.amount0
        );
        IERC20(Currency.unwrap(callbackData.poolKey.currency1)).transferFrom(
            callbackData.sender, address(this), callbackData.amount1
        );

        // Approve PoolManager
        IERC20(Currency.unwrap(callbackData.poolKey.currency0)).approve(address(poolManager), callbackData.amount0);
        IERC20(Currency.unwrap(callbackData.poolKey.currency1)).approve(address(poolManager), callbackData.amount1);

        uint128 liquidity;

        if (callbackData.isJITEnabled) {
            // JIT liquidity: settle to PM and mint claim tokens to hook
            callbackData.poolKey.currency0.settle(poolManager, address(this), callbackData.amount0, false);
            callbackData.poolKey.currency1.settle(poolManager, address(this), callbackData.amount1, false);

            callbackData.poolKey.currency0.take(poolManager, address(this), callbackData.amount0, true);
            callbackData.poolKey.currency1.take(poolManager, address(this), callbackData.amount1, true);
        } else {
            // Passive liquidity: calculate liquidity first, then add to pool
            (liquidity,,) = positionManager.calculateLiquidityForAmounts(
                callbackData.poolKey,
                callbackData.tickLower,
                callbackData.tickUpper,
                callbackData.amount0,
                callbackData.amount1
            );

            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: callbackData.tickLower,
                tickUpper: callbackData.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            });

            (BalanceDelta delta,) = poolManager.modifyLiquidity(callbackData.poolKey, params, "");

            // Settle the debits
            if (delta.amount0() > 0) {
                callbackData.poolKey.currency0.settle(
                    poolManager, address(this), uint256(int256(delta.amount0())), false
                );
            }
            if (delta.amount1() > 0) {
                callbackData.poolKey.currency1.settle(
                    poolManager, address(this), uint256(int256(delta.amount1())), false
                );
            }
        }

        // Register position with LPPositionManager (it calculates liquidity internally)
        (uint256 tokenId, uint128 calculatedLiquidity) = positionManager.depositLiquidity(
            callbackData.poolKey,
            callbackData.tickLower,
            callbackData.tickUpper,
            uint128(callbackData.amount0),
            uint128(callbackData.amount1),
            callbackData.sender,
            callbackData.isJITEnabled
        );

        // Update deposited amounts in config manager
        configManager.updateDepositedAmounts(
            callbackData.poolKey, callbackData.sender, callbackData.amount0, callbackData.amount1
        );

        return abi.encode(tokenId, calculatedLiquidity);
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
            // Get position details for removal
            (bool isActive, int24 tickLower, int24 tickUpper, uint128 totalLiquidity) =
                jitCoordinator.getJITPositionForRemoval(currentSwapId);

            if (isActive && totalLiquidity > 0) {
                // Remove the JIT liquidity
                ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(totalLiquidity)),
                    salt: bytes32(currentSwapId)
                });

                (BalanceDelta removeDelta,) = poolManager.modifyLiquidity(key, removeParams, "");

                // When removing liquidity, we RECEIVE tokens from the pool (positive amounts = credits)
                // We take these credits as claim tokens
                if (removeDelta.amount0() > 0) {
                    key.currency0.take(poolManager, address(this), uint256(int256(removeDelta.amount0())), true);
                }
                if (removeDelta.amount1() > 0) {
                    key.currency1.take(poolManager, address(this), uint256(int256(removeDelta.amount1())), true);
                }
            }

            // Process fee distribution
            jitCoordinator.removeJITLiquidity(key, currentSwapId, delta, currentAppliedFee);

            (uint256 fees0, uint256 fees1) = jitCoordinator.getJITFees(currentSwapId);
            emit ActualFeesCollected(key.toId(), currentSwapId, fees0, fees1);

            currentSwapId = 0;
            currentAppliedFee = 0;
        }

        feeManager.updateMovingAverage();

        return (this.afterSwap.selector, 0);
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

    function getCurrentJITDetails(uint256 swapId)
        external
        view
        returns (bool isActive, uint128 totalLiquidity, uint256 fees0, uint256 fees1)
    {
        bool active = jitCoordinator.isJITActive(swapId);
        if (!active) {
            (uint256 f0, uint256 f1) = jitCoordinator.getJITFees(swapId);
            return (false, 0, f0, f1);
        }
        return (true, 0, 0, 0);
    }

    /**
     * @notice Get current pool price and tick
     */
    function getCurrentPrice(PoolKey calldata key) external view returns (uint160 sqrtPriceX96, int24 tick) {
        return positionManager.getCurrentPrice(key);
    }

    /**
     * @notice Get price ratio (token1/token0)
     */
    function getPriceRatio(PoolKey calldata key) external view returns (uint256 ratio) {
        return positionManager.getPriceRatio(key);
    }

    /**
     * @notice Preview liquidity calculation
     */
    function previewLiquidityForAmounts(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        return positionManager.calculateLiquidityForAmounts(key, tickLower, tickUpper, amount0Desired, amount1Desired);
    }

    /**
     * @notice Preview amounts needed for liquidity
     */
    function previewAmountsForLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        return positionManager.calculateAmountsForLiquidity(key, tickLower, tickUpper, liquidity);
    }

    function _handleSwap(PoolKey calldata key, SwapParams calldata params) external {
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint256(int256(delta.amount0())));
                // settle with poolManager
                key.currency0.settle(poolManager, address(this), uint256(int256(delta.amount0())), false);
            }

            if (delta.amount1() < 0) {
                key.currency1.take(poolManager, msg.sender, uint256(int256(-delta.amount1())), true);
            }
        }
    }
}
