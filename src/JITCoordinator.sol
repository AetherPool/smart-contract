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
 * @notice Coordinates multi-LP Just-In-Time liquidity operations with proportional LP contributions
 * @dev Evaluates eligible LPs, creates JIT positions, and distributes fees proportionally
 */
contract JITCoordinator {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Structs ============

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
    event HookUpdated(address indexed newHook);

    // ============ Errors ============

    error Unauthorized();
    error AlreadyExecuted();
    error InvalidSwapAmount();
    error NoEligibleLPs();
    error InsufficientJITLiquidity();

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _positionManager,
        address _configManager,
        address _profitManager,
        address _feeCalculator
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        configManager = _configManager;
        profitManager = _profitManager;
        feeCalculator = _feeCalculator;
    }

    // ============ External Functions ============

    /**
     * @notice Update hook address (only callable once, during deployment)
     * @param _hook New hook address
     */
    function updateHook(address _hook) external {
        require(hook == address(0), "Hook already set");
        require(_hook != address(0), "Invalid hook address");
        hook = _hook;
        emit HookUpdated(_hook);
    }

    /**
     * @notice Evaluate which LPs should participate in JIT operation based on their configurations and liquidity
     * @param key Pool key
     * @param swapAmount Size of the incoming swap
     * @return eligibleLPs Array of eligible LP addresses
     * @return contributions Array of liquidity contributions per LP
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

        address[] memory tempEligibleLPs = new address[](cache.allLPs.length);

        for (uint256 i = 0; i < cache.allLPs.length; i++) {
            if (_isLPEligible(key, cache.allLPs[i], cache.poolId, cache.currentTick, swapAmount)) {
                tempEligibleLPs[cache.eligibleCount] = cache.allLPs[i];
                cache.totalAvailableLiquidity += ILPPositionManager(positionManager)
                    .getTotalLiquidity(cache.poolId, cache.allLPs[i]);
                cache.eligibleCount++;
            }
        }

        if (cache.eligibleCount == 0) {
            return (new address[](0), new uint128[](0));
        }

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
     * @notice Create multi-LP JIT operation with at least 50% swap coverage
     * @param key Pool key
     * @param swapper Address initiating the swap
     * @param swapAmount Swap amount
     * @param params Swap parameters
     * @param eligibleLPs Array of eligible LP addresses
     * @param contributions Array of liquidity contributions
     * @return swapId Unique identifier for this JIT operation
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
     * @param swapId Swap identifier
     * @return tickLower Lower tick for JIT position
     * @return tickUpper Upper tick for JIT position
     * @return totalLiquidity Total liquidity to inject
     * @return lps Array of participating LPs
     * @return contributions Array of LP contributions
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
     * @param swapId Swap identifier
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param totalLiquidity Total liquidity injected
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
     * @param swapId Swap identifier
     * @return isActive Whether position is active
     * @return tickLower Lower tick
     * @return tickUpper Upper tick
     * @return totalLiquidity Total liquidity
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
     * @param key Pool key
     * @param swapId Swap identifier
     * @param delta Swap balance delta
     * @param appliedFee Fee tier applied to swap
     */
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId, BalanceDelta delta, uint24 appliedFee) external {
        JITLiquidityPosition storage position = jitPositions[swapId];
        if (!position.isActive) return;

        position.isActive = false;
        PoolId poolId = key.toId();

        (uint256 totalFees0, uint256 totalFees1) =
            IFeeCalculator(feeCalculator).calculateSwapFees(key, delta, appliedFee, position.totalLiquidity);

        position.totalFees0 = totalFees0;
        position.totalFees1 = totalFees1;

        _distributeJITFees(key, position);
        emit JITRemoved(swapId, poolId, totalFees0, totalFees1);
    }

    /**
     * @notice Remove JIT liquidity and distribute fees with auto-hedge support
     * @param key Pool key
     * @param swapId Swap identifier
     * @param delta Swap balance delta
     * @param appliedFee Fee tier applied
     * @return autoHedgeLPs Array of LPs that triggered auto-hedge
     * @return amounts0 Array of token0 amounts to transfer
     * @return amounts1 Array of token1 amounts to transfer
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

        _calculateAndStoreFees(key, position, delta, appliedFee);
        (autoHedgeLPs, amounts0, amounts1) = _distributeJITFeesWithAutoHedge(key, position);

        emit JITRemoved(swapId, key.toId(), position.totalFees0, position.totalFees1);
        return (autoHedgeLPs, amounts0, amounts1);
    }

    // ============ Internal Functions ============

    function _isLPEligible(PoolKey calldata key, address lp, PoolId poolId, int24 currentTick, uint128 swapAmount)
        private
        view
        returns (bool)
    {
        if (!IFHEConfigManager(configManager).isActive(key, lp)) return false;
        if (!ILPPositionManager(positionManager).hasOverlappingPosition(poolId, lp, currentTick, TICK_RANGE)) {
            return false;
        }
        return IFHEConfigManager(configManager).meetsThreshold(key, lp, swapAmount);
    }

    function _distributeJITFees(PoolKey memory key, JITLiquidityPosition storage position) private {
        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            address lp = position.participatingLPs[i];
            uint128 contribution = position.lpContributions[i];

            (uint256 lpFees0, uint256 lpFees1) = IFeeCalculator(feeCalculator)
                .calculateJITFeeShare(position.totalFees0, position.totalFees1, contribution, position.totalLiquidity);

            if (lpFees0 > 0 || lpFees1 > 0) {
                IProfitManager(profitManager).accrueProfit(key, lp, lpFees0, lpFees1);
                emit JITFeesDistributed(position.swapId, lp, lpFees0, lpFees1);

                if (IFHEConfigManager(configManager).hasAutoHedgeEnabled(key, lp)) {
                    IProfitManager(profitManager).checkAndExecuteAutoHedge(key, lp);
                }
            }
        }
    }

    function _calculateLPContribution(PoolId poolId, address lp, uint128 swapAmount, uint128 totalAvailableLiquidity)
        private
        view
        returns (uint128)
    {
        if (totalAvailableLiquidity == 0) return 0;

        uint128 lpLiquidity = ILPPositionManager(positionManager).getTotalLiquidity(poolId, lp);
        uint256 lpShare = (uint256(swapAmount) * uint256(lpLiquidity)) / uint256(totalAvailableLiquidity);
        uint128 contribution = lpShare > lpLiquidity ? lpLiquidity : uint128(lpShare);

        return contribution;
    }

    function _calculateAndStoreFees(
        PoolKey calldata key,
        JITLiquidityPosition storage position,
        BalanceDelta delta,
        uint24 appliedFee
    ) private {
        (uint256 totalFees0, uint256 totalFees1) = IFeeCalculator(feeCalculator)
            .calculateSwapFees(key, delta, appliedFee, position.totalLiquidity);

        position.totalFees0 = totalFees0;
        position.totalFees1 = totalFees1;
    }

    function _distributeJITFeesWithAutoHedge(PoolKey memory key, JITLiquidityPosition storage position)
        private
        returns (address[] memory autoHedgeLPs, uint256[] memory amounts0, uint256[] memory amounts1)
    {
        AutoHedgeResult[] memory tempResults = new AutoHedgeResult[](position.participatingLPs.length);
        uint256 autoHedgeCount = 0;

        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            AutoHedgeResult memory result = _processLPFeeDistribution(key, position, i);

            if (result.amount0 > 0 || result.amount1 > 0) {
                tempResults[autoHedgeCount] = result;
                autoHedgeCount++;
            }
        }

        return _convertAutoHedgeResults(tempResults, autoHedgeCount);
    }

    function _processLPFeeDistribution(PoolKey memory key, JITLiquidityPosition storage position, uint256 lpIndex)
        private
        returns (AutoHedgeResult memory result)
    {
        address lp = position.participatingLPs[lpIndex];
        uint128 contribution = position.lpContributions[lpIndex];

        (uint256 lpFees0, uint256 lpFees1) = _calculateLPFees(position, contribution);

        if (lpFees0 == 0 && lpFees1 == 0) {
            return AutoHedgeResult(address(0), 0, 0);
        }

        IProfitManager(profitManager).accrueProfit(key, lp, lpFees0, lpFees1);
        emit JITFeesDistributed(position.swapId, lp, lpFees0, lpFees1);

        return _checkAutoHedgeForLP(key, lp);
    }

    function _calculateLPFees(JITLiquidityPosition storage position, uint128 contribution)
        private
        view
        returns (uint256 lpFees0, uint256 lpFees1)
    {
        return IFeeCalculator(feeCalculator)
            .calculateJITFeeShare(position.totalFees0, position.totalFees1, contribution, position.totalLiquidity);
    }

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
