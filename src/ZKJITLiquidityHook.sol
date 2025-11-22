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
 * @notice Main hook orchestrator with JIT liquidity coordination
 * @dev Simplified version using unlock pattern for JIT execution
 */
contract ZKJITLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
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

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
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
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
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
            beforeAddLiquidity: true,
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

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    // ============ Custom Add Liquidity Function ============

    /**
     * @notice LPs deposit liquidity through this function
     * @dev Stores liquidity as claim tokens in the hook to be used for JIT operations
     * @param key Pool key
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param liquidity Amount of liquidity
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @return tokenId The position token ID from LPPositionManager
     */
    function depositLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) external returns (uint256 tokenId) {
        bytes memory callbackData = abi.encode(
            AddLiquidityCallbackData({
                poolKey: key,
                sender: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                amount0: amount0,
                amount1: amount1
            })
        );

        bytes memory result = poolManager.unlock(callbackData);
        tokenId = abi.decode(result, (uint256));

        return tokenId;
    }

    // ============ Hook Implementation ============

    /**
     * @notice Hook called before swap execution
     * @dev Evaluates JIT opportunities and creates JIT operation
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint128 swapAmount =
            uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified));

        // Evaluate eligible LPs for JIT
        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, swapAmount);

        // Don't return a delta - let the swap happen normally
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(0, 0);

        if (eligibleLPs.length > 0) {
            // Create JIT operation
            uint256 swapId =
                jitCoordinator.createMultiLPJIT(key, sender, swapAmount, params, eligibleLPs, contributions);

            currentSwapId = swapId;

            // Execute JIT liquidity addition
            jitCoordinator.executeMultiLPJIT(swapId);
        }

        // Get dynamic fee
        (uint24 dynamicFee,) = feeManager.getFee();
        uint24 feeWithFlag = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        currentAppliedFee = dynamicFee;

        emit SwapProcessed(key.toId(), currentSwapId, dynamicFee, eligibleLPs.length);

        return (this.beforeSwap.selector, beforeSwapDelta, feeWithFlag);
    }

    /**
     * @notice Callback for handling liquidity deposits and other unlock operations
     * @dev Receives tokens from LP and mints claim tokens to the hook
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        AddLiquidityCallbackData memory callbackData = abi.decode(data, (AddLiquidityCallbackData));

        // Transfer tokens from sender to this contract first
        IERC20(Currency.unwrap(callbackData.poolKey.currency0)).transferFrom(
            callbackData.sender, address(this), callbackData.amount0
        );
        IERC20(Currency.unwrap(callbackData.poolKey.currency1)).transferFrom(
            callbackData.sender, address(this), callbackData.amount1
        );

        // Approve PoolManager to spend tokens
        IERC20(Currency.unwrap(callbackData.poolKey.currency0)).approve(address(poolManager), callbackData.amount0);
        IERC20(Currency.unwrap(callbackData.poolKey.currency1)).approve(address(poolManager), callbackData.amount1);

        // Settle tokens from hook to PoolManager (creates debit in PM)
        callbackData.poolKey.currency0.settle(
            poolManager,
            address(this),
            callbackData.amount0,
            false // false = actually transfer tokens from hook to PM
        );
        callbackData.poolKey.currency1.settle(poolManager, address(this), callbackData.amount1, false);

        // Take claim tokens for the hook (creates credit in PM)
        // This mints claim tokens to the hook
        callbackData.poolKey.currency0.take(
            poolManager,
            address(this),
            callbackData.amount0,
            true // true = mint claim tokens to hook
        );
        callbackData.poolKey.currency1.take(poolManager, address(this), callbackData.amount1, true);

        // Register position with LPPositionManager
        uint256 tokenId = positionManager.depositLiquidity(
            callbackData.poolKey,
            callbackData.tickLower,
            callbackData.tickUpper,
            callbackData.liquidity,
            uint128(callbackData.amount0),
            uint128(callbackData.amount1),
            callbackData.sender
        );

        return abi.encode(tokenId);
    }

    /**
     * @notice Hook called after swap execution
     * @dev Removes JIT liquidity, calculates and distributes fees
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (currentSwapId > 0) {
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
}
