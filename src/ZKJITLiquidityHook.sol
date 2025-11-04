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
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IJITCoordinator} from "./interfaces/IJITCoordinator.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title ZKJITLiquidityHook
 * @notice Main hook orchestrator for privacy-preserving JIT liquidity
 * @dev Coordinates between all module contracts to provide multi-LP JIT with FHE encryption
 *
 * Key Features:
 * - Multi-LP JIT coordination with overlapping ranges
 * - FHE-encrypted LP parameters for strategy privacy
 * - Dynamic fee pricing based on gas conditions
 * - Automated profit hedging and compounding
 * - Internal ERC-6909-style LP token management
 */
contract ZKJITLiquidityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ============ Module Contracts ============

    ILPPositionManager public immutable positionManager;
    IFHEConfigManager public immutable configManager;
    IDynamicFeeManager public immutable feeManager;
    IProfitManager public immutable profitManager;
    IJITCoordinator public immutable jitCoordinator;

    // ============ Storage ============

    uint256 public currentSwapId;

    // ============ Events ============

    event HookInitialized(
        address positionManager,
        address configManager,
        address feeManager,
        address profitManager,
        address jitCoordinator
    );

    event SwapProcessed(PoolId indexed poolId, uint256 swapId, uint24 dynamicFee, uint256 eligibleLPs);

    // ============ Errors ============

    error MustUseDynamicFee();

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        address _configManager,
        address _feeManager,
        address _profitManager,
        address _jitCoordinator
    ) BaseHook(_poolManager) {
        positionManager = ILPPositionManager(_positionManager);
        configManager = IFHEConfigManager(_configManager);
        feeManager = IDynamicFeeManager(_feeManager);
        profitManager = IProfitManager(_profitManager);
        jitCoordinator = IJITCoordinator(_jitCoordinator);

        emit HookInitialized(_positionManager, _configManager, _feeManager, _profitManager, _jitCoordinator);
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Use dynamic fee on initialization
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Dynamic fee and JIT logic before swap
            afterSwap: true, // Cleanup and moving average update after swap
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

    // ============ Hook Implementation ============

    /**
     * @notice Hook called before swap execution
     * @dev Evaluates JIT opportunities and applies dynamic fees
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Calculate swap amount
        uint128 swapAmount =
            uint128(params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified));

        // Evaluate multi-LP JIT participation
        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, swapAmount);

        // If eligible LPs found, create and execute JIT
        if (eligibleLPs.length > 0) {
            uint256 swapId =
                jitCoordinator.createMultiLPJIT(key, sender, swapAmount, params, eligibleLPs, contributions);

            jitCoordinator.executeMultiLPJIT(swapId);
            currentSwapId = swapId;
        }

        // Get dynamic fee from fee manager
        (uint24 dynamicFee,) = feeManager.getFee();
        uint24 feeWithFlag = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        emit SwapProcessed(key.toId(), currentSwapId, dynamicFee, eligibleLPs.length);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    /**
     * @notice Hook called after swap execution
     * @dev Removes JIT liquidity and updates fee calculations
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Remove JIT liquidity if it was active
        if (currentSwapId > 0) {
            jitCoordinator.removeJITLiquidity(key, currentSwapId);
            currentSwapId = 0;
        }

        // Update moving average gas price
        feeManager.updateMovingAverage();

        return (this.afterSwap.selector, 0);
    }

    // ============ User-Facing Functions ============

    /**
     * @notice Deposit liquidity and receive internal LP token
     */
    function depositLiquidityToHook(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 amount0Max,
        uint128 amount1Max
    ) external returns (uint256 tokenId) {
        return positionManager.depositLiquidity(
            poolKey, tickLower, tickUpper, liquidityDelta, amount0Max, amount1Max, msg.sender
        );
    }

    /**
     * @notice Remove liquidity by burning internal LP token
     */
    function removeLiquidityFromHook(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        return positionManager.removeLiquidity(poolKey, tokenId, liquidityDelta, msg.sender);
    }

    /**
     * @notice Configure LP's private JIT parameters using FHE encryption
     */
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint128 calldata maxLiquidity,
        InEuint32 calldata profitThreshold,
        InEuint32 calldata hedgePercentage,
        bool autoHedgeEnabled
    ) external {
        configManager.configureLPSettings(
            poolKey, minSwapSize, maxLiquidity, profitThreshold, hedgePercentage, autoHedgeEnabled
        );
    }

    /**
     * @notice Manually hedge LP profits
     */
    function hedgeProfits(PoolKey calldata poolKey, uint256 hedgePercentage) external {
        profitManager.hedgeProfits(poolKey, hedgePercentage);
    }

    /**
     * @notice Compound profits into new liquidity position
     */
    function compoundProfits(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 tokenId)
    {
        return profitManager.compoundProfits(poolKey, tickLower, tickUpper);
    }

    /**
     * @notice Batch hedge profits across multiple pools
     */
    function batchHedgeProfits(PoolKey[] calldata poolKeys, uint256[] calldata hedgePercentages) external {
        profitManager.batchHedgeProfits(poolKeys, hedgePercentages);
    }

    /**
     * @notice Deactivate LP participation
     */
    function deactivateLP(PoolKey calldata poolKey) external {
        configManager.deactivateLP(poolKey);
    }

    // ============ View Functions ============

    /**
     * @notice Check if LP is active
     */
    function getLPConfig(PoolKey calldata poolKey, address lp) external view returns (bool isActive) {
        return configManager.isActive(poolKey, lp);
    }

    /**
     * @notice Get module contract addresses
     */
    function getModuleAddresses()
        external
        view
        returns (
            address _positionManager,
            address _configManager,
            address _feeManager,
            address _profitManager,
            address _jitCoordinator
        )
    {
        return (
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator)
        );
    }
}
