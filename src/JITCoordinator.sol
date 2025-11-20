// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";

/**
 * @title JITCoordinator
 * @notice Coordinates multi-LP Just-In-Time liquidity operations
 * @dev Evaluates eligible LPs, calculates contributions, and manages JIT positions
 */
contract JITCoordinator {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Data Structures ============

    struct PendingJIT {
        uint256 swapId; // Unique swap identifier
        address swapper; // Swap initiator
        uint128 swapAmount; // Swap size
        address tokenIn; // Input token
        address tokenOut; // Output token
        uint256 blockNumber; // Block when created
        bool executed; // Execution status
        bool zeroForOne; // Swap direction
        PoolKey poolKey; // Pool information
        address[] eligibleLPs; // Participating LPs
        uint128[] liquidityContributions; // LP contribution amounts
    }

    struct JITLiquidityPosition {
        uint256 swapId; // Associated swap ID
        int24 tickLower; // JIT position lower tick
        int24 tickUpper; // JIT position upper tick
        uint128 totalLiquidity; // Total JIT liquidity
        address[] participatingLPs; // LPs in this JIT
        uint128[] lpContributions; // Individual LP contributions
        bool isActive; // Position status
        uint256 timestamp; // Creation timestamp
    }

    // Temporary struct to reduce stack depth
    struct EvaluationCache {
        PoolId poolId;
        int24 currentTick;
        address[] allLPs;
        uint256 eligibleCount;
    }

    // ============ Storage ============

    IPoolManager public immutable poolManager;

    address public hook;
    address public positionManager;
    address public configManager;
    address public profitManager;

    mapping(uint256 => PendingJIT) public pendingJITs;
    mapping(uint256 => JITLiquidityPosition) public jitPositions;

    uint256 public nextSwapId;
    int24 public constant TICK_RANGE = 60; // JIT liquidity range

    // ============ Events ============

    event JITRequested(uint256 indexed swapId, PoolId indexed poolId, address indexed swapper, uint128 swapAmount);
    event JITExecuted(uint256 indexed swapId, PoolId indexed poolId, uint128 liquidityProvided);
    event JITMultiLPExecution(uint256 indexed swapId, address[] lps, uint128[] contributions);
    event JITRemoved(uint256 indexed swapId, PoolId indexed poolId);

    // ============ Errors ============

    error Unauthorized();
    error AlreadyExecuted();
    error InvalidSwapAmount();
    error NoEligibleLPs();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _hook,
        address _positionManager,
        address _configManager,
        address _profitManager
    ) {
        poolManager = _poolManager;
        hook = _hook;
        positionManager = _positionManager;
        configManager = _configManager;
        profitManager = _profitManager;
    }

    // ============ External Functions ============

    /**
     * @notice Evaluate which LPs should participate in JIT operation
     * @param key Pool key
     * @param swapAmount Size of the incoming swap
     * @return eligibleLPs Array of LP addresses
     * @return contributions Array of LP contribution amounts
     */
    function evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        external
        view
        returns (address[] memory eligibleLPs, uint128[] memory contributions)
    {
        if (swapAmount == 0) revert InvalidSwapAmount();

        // Initialize cache to reduce stack depth
        EvaluationCache memory cache;
        cache.poolId = key.toId();
        cache.allLPs = ILPPositionManager(positionManager).getPoolLPs(key);
        cache.eligibleCount = 0;

        // Get current tick
        (, cache.currentTick,,) = poolManager.getSlot0(cache.poolId);

        // Temporary arrays for eligible LPs
        address[] memory tempEligibleLPs = new address[](cache.allLPs.length);
        uint128[] memory tempContributions = new uint128[](cache.allLPs.length);

        // Evaluate each LP
        for (uint256 i = 0; i < cache.allLPs.length; i++) {
            if (_isLPEligible(key, cache.allLPs[i], cache.poolId, cache.currentTick, swapAmount)) {
                tempEligibleLPs[cache.eligibleCount] = cache.allLPs[i];
                tempContributions[cache.eligibleCount] =
                    _calculateLPContribution(cache.poolId, cache.allLPs[i], swapAmount);
                cache.eligibleCount++;
            }
        }

        // Resize arrays to actual count
        eligibleLPs = new address[](cache.eligibleCount);
        contributions = new uint128[](cache.eligibleCount);

        for (uint256 i = 0; i < cache.eligibleCount; i++) {
            eligibleLPs[i] = tempEligibleLPs[i];
            contributions[i] = tempContributions[i];
        }

        return (eligibleLPs, contributions);
    }

    /**
     * @notice Create multi-LP JIT operation
     * @param key Pool key
     * @param swapper Address initiating the swap
     * @param swapAmount Size of the swap
     * @param params Swap parameters
     * @param eligibleLPs Array of eligible LP addresses
     * @param contributions Array of LP contributions
     * @return swapId Unique identifier for this JIT operation
     */
    function createMultiLPJIT(
        PoolKey calldata key,
        address swapper,
        uint128 swapAmount,
        SwapParams calldata params,
        address[] memory eligibleLPs,
        uint128[] memory contributions
    ) external onlyHook returns (uint256 swapId) {
        if (eligibleLPs.length == 0) revert NoEligibleLPs();

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
     * @param swapId The JIT operation ID to execute
     */
    function executeMultiLPJIT(uint256 swapId) external onlyHook {
        PendingJIT storage jit = pendingJITs[swapId];

        if (jit.executed) revert AlreadyExecuted();

        _addMultiLPJITLiquidity(jit.poolKey, swapId, jit.eligibleLPs, jit.liquidityContributions);

        jit.executed = true;

        emit JITMultiLPExecution(swapId, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Remove JIT liquidity after swap completion
     * @param key Pool key
     * @param swapId The JIT operation ID
     */
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId) external onlyHook {
        JITLiquidityPosition storage position = jitPositions[swapId];

        if (!position.isActive) return;

        position.isActive = false;
        PoolId poolId = key.toId();

        // Distribute final bonus profits to participating LPs
        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            address lp = position.participatingLPs[i];
            uint128 contribution = position.lpContributions[i];

            // Additional profit distribution
            uint256 bonusProfit0 = contribution / 30;
            uint256 bonusProfit1 = contribution / 30;

            // Accrue profits through profit manager
            IProfitManager(profitManager).accrueProfit(key, lp, bonusProfit0, bonusProfit1);

            // Auto-hedge if enabled
            IProfitManager(profitManager).autoHedgeProfits(key, lp);
        }

        emit JITRemoved(swapId, poolId);
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if LP is eligible for JIT participation
     * @param key Pool key
     * @param lp LP address
     * @param poolId Pool identifier
     * @param currentTick Current pool tick
     * @param swapAmount Swap size
     * @return Whether LP is eligible
     */
    function _isLPEligible(PoolKey calldata key, address lp, PoolId poolId, int24 currentTick, uint128 swapAmount)
        private
        view
        returns (bool)
    {
        // Check if LP is active
        if (!IFHEConfigManager(configManager).isActive(key, lp)) {
            return false;
        }

        // Check for overlapping positions
        if (!ILPPositionManager(positionManager).hasOverlappingPosition(poolId, lp, currentTick, TICK_RANGE)) {
            return false;
        }

        // Check if swap meets threshold
        return IFHEConfigManager(configManager).meetsThreshold(key, lp, swapAmount);
    }

    /**
     * @notice Add JIT liquidity for multiple LPs
     * @param key Pool key
     * @param swapId Swap identifier
     * @param lps Array of LP addresses
     * @param contributions Array of LP contributions
     */
    function _addMultiLPJITLiquidity(
        PoolKey memory key,
        uint256 swapId,
        address[] memory lps,
        uint128[] memory contributions
    ) private {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Calculate JIT position ticks
        int24 tickLower = ((currentTick - TICK_RANGE) / key.tickSpacing) * key.tickSpacing;
        int24 tickUpper = ((currentTick + TICK_RANGE) / key.tickSpacing) * key.tickSpacing;

        // Calculate total liquidity
        uint128 totalLiquidity = 0;
        for (uint256 i = 0; i < contributions.length; i++) {
            totalLiquidity += contributions[i];
        }

        if (totalLiquidity > 0) {
            // Store JIT position
            jitPositions[swapId] = JITLiquidityPosition({
                swapId: swapId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                totalLiquidity: totalLiquidity,
                participatingLPs: lps,
                lpContributions: contributions,
                isActive: true,
                timestamp: block.timestamp
            });

            // Distribute initial profits
            _distributeInitialProfits(key, lps, contributions);

            emit JITExecuted(swapId, poolId, totalLiquidity);
        }
    }

    /**
     * @notice Distribute initial profits to participating LPs
     * @param key Pool key
     * @param lps Array of LP addresses
     * @param contributions Array of LP contributions
     */
    function _distributeInitialProfits(PoolKey memory key, address[] memory lps, uint128[] memory contributions)
        private
    {
        for (uint256 i = 0; i < lps.length; i++) {
            uint256 initialProfit0 = contributions[i] / 20; // 5% simulated profit
            uint256 initialProfit1 = contributions[i] / 20;

            // Accrue profits through profit manager
            IProfitManager(profitManager).accrueProfit(key, lps[i], initialProfit0, initialProfit1);

            // Auto-hedge if enabled
            if (IFHEConfigManager(configManager).hasAutoHedgeEnabled(key, lps[i])) {
                IProfitManager(profitManager).autoHedgeProfits(key, lps[i]);
            }
        }
    }

    /**
     * @notice Calculate LP's contribution to JIT operation
     * @param poolId Pool identifier
     * @param lp LP address
     * @param swapAmount Size of incoming swap
     * @return LP's calculated contribution
     */
    function _calculateLPContribution(PoolId poolId, address lp, uint128 swapAmount) private view returns (uint128) {
        // Get LP's total liquidity from position manager
        uint128 totalLiquidity = ILPPositionManager(positionManager).getTotalLiquidity(poolId, lp);

        // Calculate contribution based on swap size and LP capacity
        uint128 maxContribution = swapAmount / 10; // Max 10% of swap
        uint128 lpCapacity = totalLiquidity / 2; // LP can contribute up to 50% of their liquidity

        return maxContribution < lpCapacity ? maxContribution : lpCapacity;
    }

    // ============ View Functions ============

    /**
     * @notice Get pending JIT details
     * @param swapId Swap identifier
     * @return PendingJIT struct
     */
    function getPendingJIT(uint256 swapId) external view returns (PendingJIT memory) {
        return pendingJITs[swapId];
    }

    /**
     * @notice Get JIT position details
     * @param swapId Swap identifier
     * @return JITLiquidityPosition struct
     */
    function getJITPosition(uint256 swapId) external view returns (JITLiquidityPosition memory) {
        return jitPositions[swapId];
    }

    /**
     * @notice Check if JIT position is active
     * @param swapId Swap identifier
     * @return Whether position is active
     */
    function isJITActive(uint256 swapId) external view returns (bool) {
        return jitPositions[swapId].isActive;
    }

    /**
     * @notice Get next swap ID
     * @return Next available swap ID
     */
    function getNextSwapId() external view returns (uint256) {
        return nextSwapId + 1;
    }
}
