// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";

/**
 * @title JITCoordinator
 * @notice Coordinates multi-LP Just-In-Time liquidity operations
 * @dev Targets proportional LP contributions for swap coverage
 * @dev REFACTORED: Extracted functions to avoid stack too deep
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

    // ✅ NEW: Struct to reduce stack depth in distribution
    struct AutoHedgeResult {
        address lp;
        uint256 amount0;
        uint256 amount1;
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
    event JITRecorded(uint256 indexed swapId, PoolId indexed poolId, uint128 liquidityProvided);
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
            contributions[i] =
                _calculateLPContribution(cache.poolId, tempEligibleLPs[i], swapAmount, cache.totalAvailableLiquidity);
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
     * @notice Get JIT execution parameters (called by hook before execution)
     * @dev Hook will use these to execute the actual modifyLiquidity
     */
    function getJITExecutionParams(uint256 swapId)
        external
        view
        returns (
            int24 tickLower,
            int24 tickUpper,
            uint128 totalLiquidity,
            address[] memory lps,
            uint128[] memory contributions
        )
    {
        PendingJIT storage jit = pendingJITs[swapId];

        PoolId poolId = jit.poolKey.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        int24 tickSpacing = jit.poolKey.tickSpacing;
        tickLower = ((currentTick - TICK_RANGE) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + TICK_RANGE) / tickSpacing) * tickSpacing;

        totalLiquidity = 0;
        for (uint256 i = 0; i < jit.liquidityContributions.length; i++) {
            totalLiquidity += jit.liquidityContributions[i];
        }

        return (tickLower, tickUpper, totalLiquidity, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Record JIT execution (called by hook after modifyLiquidity)
     */
    function recordJITExecution(uint256 swapId, int24 tickLower, int24 tickUpper, uint128 totalLiquidity) external {
        require(msg.sender == hook, "Only hook");

        PendingJIT storage jit = pendingJITs[swapId];
        require(!jit.executed, "Already executed");

        jitPositions[swapId] = JITLiquidityPosition({
            swapId: swapId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            totalLiquidity: totalLiquidity,
            participatingLPs: jit.eligibleLPs,
            lpContributions: jit.liquidityContributions,
            isActive: true,
            timestamp: block.timestamp,
            totalFees0: 0,
            totalFees1: 0
        });

        jit.executed = true;

        emit JITRecorded(swapId, jit.poolKey.toId(), totalLiquidity);
        emit JITMultiLPExecution(swapId, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Get JIT position for removal (called by hook in afterSwap)
     */
    function getJITPositionForRemoval(uint256 swapId)
        external
        view
        returns (bool isActive, int24 tickLower, int24 tickUpper, uint128 totalLiquidity)
    {
        JITLiquidityPosition storage position = jitPositions[swapId];
        return (position.isActive, position.tickLower, position.tickUpper, position.totalLiquidity);
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
    function _calculateLPContribution(PoolId poolId, address lp, uint128 swapAmount, uint128 totalAvailableLiquidity)
        private
        view
        returns (uint128)
    {
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

    /**
     * @notice Remove JIT liquidity after swap completion and distribute fees
     * ✅ REFACTORED: Broken into smaller functions to avoid stack too deep
     */
    function removeJITLiquidityWithAutoHedge(
        PoolKey calldata key,
        uint256 swapId,
        BalanceDelta delta,
        uint24 appliedFee
    ) external returns (address[] memory autoHedgeLPs, uint256[] memory amounts0, uint256[] memory amounts1) {
        JITLiquidityPosition storage position = jitPositions[swapId];

        if (!position.isActive || position.totalLiquidity == 0) {
            return (new address[](0), new uint256[](0), new uint256[](0));
        }

        position.isActive = false;

        // Calculate and store fees
        _calculateAndStoreFees(key, position, delta, appliedFee);

        // Distribute fees and collect auto-hedge info
        (autoHedgeLPs, amounts0, amounts1) = _distributeJITFeesWithAutoHedge(key, position);

        emit JITRemoved(swapId, key.toId(), position.totalFees0, position.totalFees1);

        return (autoHedgeLPs, amounts0, amounts1);
    }

    /**
     * ✅ NEW: Extracted to reduce stack depth
     */
    function _calculateAndStoreFees(
        PoolKey calldata key,
        JITLiquidityPosition storage position,
        BalanceDelta delta,
        uint24 appliedFee
    ) private {
        (uint256 totalFees0, uint256 totalFees1) =
            IFeeCalculator(feeCalculator).calculateSwapFees(key, delta, appliedFee, position.totalLiquidity);

        position.totalFees0 = totalFees0;
        position.totalFees1 = totalFees1;
    }

    /**
     * ✅ REFACTORED: Distribute fees and collect auto-hedge information
     * Broken into smaller pieces to reduce stack depth
     */
    function _distributeJITFeesWithAutoHedge(PoolKey memory key, JITLiquidityPosition storage position)
        private
        returns (address[] memory autoHedgeLPs, uint256[] memory amounts0, uint256[] memory amounts1)
    {
        // Temporary storage for auto-hedge results
        AutoHedgeResult[] memory tempResults = new AutoHedgeResult[](position.participatingLPs.length);
        uint256 autoHedgeCount = 0;

        // Process each LP
        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            AutoHedgeResult memory result = _processLPFeeDistribution(key, position, i);

            if (result.amount0 > 0 || result.amount1 > 0) {
                tempResults[autoHedgeCount] = result;
                autoHedgeCount++;
            }
        }

        // Convert to return arrays
        return _convertAutoHedgeResults(tempResults, autoHedgeCount);
    }

    /**
     * ✅ NEW: Process single LP fee distribution
     */
    function _processLPFeeDistribution(PoolKey memory key, JITLiquidityPosition storage position, uint256 lpIndex)
        private
        returns (AutoHedgeResult memory result)
    {
        address lp = position.participatingLPs[lpIndex];
        uint128 contribution = position.lpContributions[lpIndex];

        // Calculate fees
        (uint256 lpFees0, uint256 lpFees1) = _calculateLPFees(position, contribution);

        if (lpFees0 == 0 && lpFees1 == 0) {
            return AutoHedgeResult(address(0), 0, 0);
        }

        // Accrue profits
        IProfitManager(profitManager).accrueProfit(key, lp, lpFees0, lpFees1);
        emit JITFeesDistributed(position.swapId, lp, lpFees0, lpFees1);

        // Check auto-hedge
        return _checkAutoHedgeForLP(key, lp);
    }

    /**
     * ✅ NEW: Calculate LP fees
     */
    function _calculateLPFees(JITLiquidityPosition storage position, uint128 contribution)
        private
        view
        returns (uint256 lpFees0, uint256 lpFees1)
    {
        return IFeeCalculator(feeCalculator).calculateJITFeeShare(
            position.totalFees0, position.totalFees1, contribution, position.totalLiquidity
        );
    }

    /**
     * ✅ NEW: Check if LP should auto-hedge
     */
    function _checkAutoHedgeForLP(PoolKey memory key, address lp) private returns (AutoHedgeResult memory result) {
        if (!IFHEConfigManager(configManager).hasAutoHedgeEnabled(key, lp)) {
            return AutoHedgeResult(address(0), 0, 0);
        }

        (bool shouldHedge, uint256 amount0, uint256 amount1,,) =
            IProfitManager(profitManager).checkAndExecuteAutoHedge(key, lp);

        if (shouldHedge && (amount0 > 0 || amount1 > 0)) {
            return AutoHedgeResult(lp, amount0, amount1);
        }

        return AutoHedgeResult(address(0), 0, 0);
    }

    /**
     * ✅ NEW: Convert AutoHedgeResult array to return format
     */
    function _convertAutoHedgeResults(AutoHedgeResult[] memory results, uint256 count)
        private
        pure
        returns (address[] memory lps, uint256[] memory amounts0, uint256[] memory amounts1)
    {
        lps = new address[](count);
        amounts0 = new uint256[](count);
        amounts1 = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            lps[i] = results[i].lp;
            amounts0[i] = results[i].amount0;
            amounts1[i] = results[i].amount1;
        }

        return (lps, amounts0, amounts1);
    }
}
