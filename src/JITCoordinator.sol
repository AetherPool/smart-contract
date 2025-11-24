// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";

/**
 * @title JITCoordinator
 * @notice Coordinates multi-LP Just-In-Time liquidity operations
 * @dev Targets proportional LP contributions for swap coverage
 */
contract JITCoordinator {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Data Structures ============

    struct PendingJIT {
        uint256 swapId;
        address swapper;
        uint128 swapAmount;
        address tokenIn;
        address tokenOut;
        uint256 blockNumber;
        bool executed;
        bool zeroForOne;
        PoolKey poolKey;
        address[] eligibleLPs;
        uint128[] liquidityContributions;
    }

    struct JITLiquidityPosition {
        uint256 swapId;
        int24 tickLower;
        int24 tickUpper;
        uint128 totalLiquidity;
        address[] participatingLPs;
        uint128[] lpContributions;
        bool isActive;
        uint256 timestamp;
        uint256 totalFees0;
        uint256 totalFees1;
    }

    struct EvaluationCache {
        PoolId poolId;
        int24 currentTick;
        address[] allLPs;
        uint256 eligibleCount;
        uint128 totalAvailableLiquidity;
    }

    // ============ Storage ============

    IPoolManager public immutable poolManager;

    address public hook;
    address public positionManager;
    address public configManager;
    address public profitManager;
    address public feeCalculator;

    mapping(uint256 => PendingJIT) public pendingJITs;
    mapping(uint256 => JITLiquidityPosition) public jitPositions;

    uint256 public nextSwapId;
    int24 public constant TICK_RANGE = 60;

    // ============ Events ============

    event JITRequested(uint256 indexed swapId, PoolId indexed poolId, address indexed swapper, uint128 swapAmount);
    event JITExecuted(uint256 indexed swapId, PoolId indexed poolId, uint128 liquidityProvided);
    event JITMultiLPExecution(uint256 indexed swapId, address[] lps, uint128[] contributions);
    event JITRemoved(uint256 indexed swapId, PoolId indexed poolId, uint256 totalFees0, uint256 totalFees1);
    event JITFeesDistributed(uint256 indexed swapId, address indexed lp, uint256 fees0, uint256 fees1);
    event InsufficientLiquidity(uint256 indexed swapId, uint128 required, uint128 available);

    // ============ Errors ============

    error Unauthorized();
    error AlreadyExecuted();
    error InvalidSwapAmount();
    error NoEligibleLPs();
    error InsufficientJITLiquidity();

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _hook,
        address _positionManager,
        address _configManager,
        address _profitManager,
        address _feeCalculator
    ) {
        poolManager = _poolManager;
        hook = _hook;
        positionManager = _positionManager;
        configManager = _configManager;
        profitManager = _profitManager;
        feeCalculator = _feeCalculator;
    }

    // ============ External Functions ============

    /**
     * @notice Evaluate which LPs should participate in JIT operation
     * @dev Only considers JIT-enabled positions
     */
    function evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        external
        view
        returns (address[] memory eligibleLPs, uint128[] memory contributions)
    {
        if (swapAmount == 0) revert InvalidSwapAmount();

        EvaluationCache memory cache;
        cache.poolId = key.toId();
        cache.allLPs = ILPPositionManager(positionManager).getJITEnabledLPs(key);
        cache.eligibleCount = 0;
        cache.totalAvailableLiquidity = 0;

        (, cache.currentTick,,) = poolManager.getSlot0(cache.poolId);

        // Count eligible LPs and total available liquidity
        address[] memory tempEligibleLPs = new address[](cache.allLPs.length);
        
        for (uint256 i = 0; i < cache.allLPs.length; i++) {
            if (_isLPEligible(key, cache.allLPs[i], cache.poolId, cache.currentTick, swapAmount)) {
                tempEligibleLPs[cache.eligibleCount] = cache.allLPs[i];
                cache.totalAvailableLiquidity += 
                    ILPPositionManager(positionManager).getTotalLiquidity(cache.poolId, cache.allLPs[i]);
                cache.eligibleCount++;
            }
        }

        if (cache.eligibleCount == 0) {
            return (new address[](0), new uint128[](0));
        }

        // Calculate proportional contributions
        eligibleLPs = new address[](cache.eligibleCount);
        contributions = new uint128[](cache.eligibleCount);

        for (uint256 i = 0; i < cache.eligibleCount; i++) {
            eligibleLPs[i] = tempEligibleLPs[i];
            contributions[i] = _calculateLPContribution(
                cache.poolId, 
                tempEligibleLPs[i], 
                swapAmount, 
                cache.totalAvailableLiquidity
            );
        }

        return (eligibleLPs, contributions);
    }

    /**
     * @notice Create multi-LP JIT operation
     */
    function createMultiLPJIT(
        PoolKey calldata key,
        address swapper,
        uint128 swapAmount,
        SwapParams calldata params,
        address[] memory eligibleLPs,
        uint128[] memory contributions
    ) external returns (uint256 swapId) {
        if (eligibleLPs.length == 0) revert NoEligibleLPs();

        uint128 totalJITLiquidity = 0;
        for (uint256 i = 0; i < contributions.length; i++) {
            totalJITLiquidity += contributions[i];
        }

        // Require at least 50% coverage
        if (totalJITLiquidity < swapAmount / 2) {
            emit InsufficientLiquidity(nextSwapId + 1, swapAmount, totalJITLiquidity);
            revert InsufficientJITLiquidity();
        }

        swapId = ++nextSwapId;

        pendingJITs[swapId] = PendingJIT({
            swapId: swapId,
            swapper: swapper,
            swapAmount: swapAmount,
            tokenIn: params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1),
            tokenOut: params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0),
            blockNumber: block.number,
            executed: false,
            zeroForOne: params.zeroForOne,
            poolKey: key,
            eligibleLPs: eligibleLPs,
            liquidityContributions: contributions
        });

        emit JITRequested(swapId, key.toId(), swapper, swapAmount);

        return swapId;
    }

    /**
     * @notice Execute multi-LP JIT operation
     */
    function executeMultiLPJIT(uint256 swapId) external {
        PendingJIT storage jit = pendingJITs[swapId];

        if (jit.executed) revert AlreadyExecuted();

        _recordMultiLPJITPosition(jit.poolKey, swapId, jit.eligibleLPs, jit.liquidityContributions);

        jit.executed = true;

        emit JITMultiLPExecution(swapId, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Remove JIT liquidity after swap completion and distribute fees
     */
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId, BalanceDelta delta, uint24 appliedFee) external {
        JITLiquidityPosition storage position = jitPositions[swapId];

        if (!position.isActive) return;

        position.isActive = false;
        PoolId poolId = key.toId();

        // Calculate total fees from this swap
        (uint256 totalFees0, uint256 totalFees1) =
            IFeeCalculator(feeCalculator).calculateSwapFees(key, delta, appliedFee, position.totalLiquidity);

        position.totalFees0 = totalFees0;
        position.totalFees1 = totalFees1;

        // Distribute fees proportionally to participating LPs
        _distributeJITFees(key, position);

        emit JITRemoved(swapId, poolId, totalFees0, totalFees1);
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if LP is eligible for JIT participation
     */
    function _isLPEligible(PoolKey calldata key, address lp, PoolId poolId, int24 currentTick, uint128 swapAmount)
        private
        view
        returns (bool)
    {
        if (!IFHEConfigManager(configManager).isActive(key, lp)) {
            return false;
        }

        if (!ILPPositionManager(positionManager).hasOverlappingPosition(poolId, lp, currentTick, TICK_RANGE)) {
            return false;
        }

        return IFHEConfigManager(configManager).meetsThreshold(key, lp, swapAmount);
    }

    /**
     * @notice Record JIT liquidity position for multiple LPs
     */
    function _recordMultiLPJITPosition(
        PoolKey memory key,
        uint256 swapId,
        address[] memory lps,
        uint128[] memory contributions
    ) private {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int24 tickLower = ((currentTick - TICK_RANGE) / key.tickSpacing) * key.tickSpacing;
        int24 tickUpper = ((currentTick + TICK_RANGE) / key.tickSpacing) * key.tickSpacing;

        uint128 totalLiquidity = 0;
        for (uint256 i = 0; i < contributions.length; i++) {
            totalLiquidity += contributions[i];
        }

        if (totalLiquidity > 0) {
            jitPositions[swapId] = JITLiquidityPosition({
                swapId: swapId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                totalLiquidity: totalLiquidity,
                participatingLPs: lps,
                lpContributions: contributions,
                isActive: true,
                timestamp: block.timestamp,
                totalFees0: 0,
                totalFees1: 0
            });

            emit JITExecuted(swapId, poolId, totalLiquidity);
        }
    }

    /**
     * @notice Distribute JIT fees to participating LPs based on their liquidity contribution
     */
    function _distributeJITFees(PoolKey memory key, JITLiquidityPosition storage position) private {
        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            address lp = position.participatingLPs[i];
            uint128 contribution = position.lpContributions[i];

            // Calculate LP's proportional share of fees
            (uint256 lpFees0, uint256 lpFees1) = IFeeCalculator(feeCalculator).calculateJITFeeShare(
                position.totalFees0, position.totalFees1, contribution, position.totalLiquidity
            );

            if (lpFees0 > 0 || lpFees1 > 0) {
                // Accrue profits through profit manager
                IProfitManager(profitManager).accrueProfit(key, lp, lpFees0, lpFees1);

                emit JITFeesDistributed(position.swapId, lp, lpFees0, lpFees1);

                // Check if auto-hedge should trigger
                if (IFHEConfigManager(configManager).hasAutoHedgeEnabled(key, lp)) {
                    IProfitManager(profitManager).checkAndExecuteAutoHedge(key, lp);
                }
            }
        }
    }

    /**
     * @notice Calculate LP's contribution to JIT operation
     */
    function _calculateLPContribution(
        PoolId poolId, 
        address lp, 
        uint128 swapAmount, 
        uint128 totalAvailableLiquidity
    ) private view returns (uint128) {
        if (totalAvailableLiquidity == 0) return 0;
        
        uint128 lpLiquidity = ILPPositionManager(positionManager).getTotalLiquidity(poolId, lp);
        
        // Calculate proportional share: (swapAmount * lpLiquidity) / totalAvailableLiquidity
        uint256 lpShare = (uint256(swapAmount) * uint256(lpLiquidity)) / uint256(totalAvailableLiquidity);
        
        // Cap at what LP actually has available
        uint128 contribution = lpShare > lpLiquidity ? lpLiquidity : uint128(lpShare);
        
        return contribution;
    }

    // ============ View Functions ============

    function getPendingJIT(uint256 swapId) external view returns (PendingJIT memory) {
        return pendingJITs[swapId];
    }

    function getJITPosition(uint256 swapId) external view returns (JITLiquidityPosition memory) {
        return jitPositions[swapId];
    }

    function isJITActive(uint256 swapId) external view returns (bool) {
        return jitPositions[swapId].isActive;
    }

    function getNextSwapId() external view returns (uint256) {
        return nextSwapId + 1;
    }

    function getJITFees(uint256 swapId) external view returns (uint256 fees0, uint256 fees1) {
        JITLiquidityPosition storage position = jitPositions[swapId];
        return (position.totalFees0, position.totalFees1);
    }
}