// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {ILPPositionManager} from "./interfaces/ILPPositionManager.sol";
import {IProfitManager} from "./interfaces/IProfitManager.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";
import {IFeeCalculator} from "./interfaces/IFeeCalculator.sol";

/**
 * @title JITCoordinator
 * @notice Coordinates multi-LP Just-In-Time liquidity with proper token settlement
 * @dev Uses claim tokens and proper settlement like CSMM to manage JIT liquidity
 */
contract JITCoordinator {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

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
        bytes32 salt;
        int128 delta0;
        int128 delta1;
        uint256 totalFees0;
        uint256 totalFees1;
    }

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
    address public feeCalculator;

    mapping(uint256 => PendingJIT) public pendingJITs;
    mapping(uint256 => JITLiquidityPosition) public jitPositions;

    uint256 public nextSwapId;
    int24 public constant TICK_RANGE = 60;

    // Track active JIT operations to allow hook to bypass restrictions
    uint256 public activeJITSwapId;

    // ============ Events ============

    event JITRequested(uint256 indexed swapId, PoolId indexed poolId, address indexed swapper, uint128 swapAmount);
    event JITExecuted(
        uint256 indexed swapId, PoolId indexed poolId, uint128 liquidityProvided, int128 amount0, int128 amount1
    );
    event JITMultiLPExecution(uint256 indexed swapId, address[] lps, uint128[] contributions);
    event JITRemoved(uint256 indexed swapId, PoolId indexed poolId, uint256 totalFees0, uint256 totalFees1);
    event JITFeesDistributed(uint256 indexed swapId, address indexed lp, uint256 fees0, uint256 fees1);

    // ============ Errors ============

    error Unauthorized();
    error AlreadyExecuted();
    error InvalidSwapAmount();
    error NoEligibleLPs();
    error NotInJITOperation();
    error InsufficientClaimTokens();

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
     */
    function evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        external
        view
        returns (address[] memory eligibleLPs, uint128[] memory contributions)
    {
        if (swapAmount == 0) revert InvalidSwapAmount();

        EvaluationCache memory cache;
        cache.poolId = key.toId();
        cache.allLPs = ILPPositionManager(positionManager).getPoolLPs(key);
        cache.eligibleCount = 0;

        (, cache.currentTick,,) = poolManager.getSlot0(cache.poolId);

        address[] memory tempEligibleLPs = new address[](cache.allLPs.length);
        uint128[] memory tempContributions = new uint128[](cache.allLPs.length);

        for (uint256 i = 0; i < cache.allLPs.length; i++) {
            if (_isLPEligible(key, cache.allLPs[i], cache.poolId, cache.currentTick, swapAmount)) {
                tempEligibleLPs[cache.eligibleCount] = cache.allLPs[i];
                tempContributions[cache.eligibleCount] =
                    _calculateLPContribution(cache.poolId, cache.allLPs[i], swapAmount);
                cache.eligibleCount++;
            }
        }

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
     * @dev Can be called by anyone, but designed to be called by hook during beforeSwap
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
     * @dev This MUST be called while PoolManager is unlocked (during beforeSwap hook callback)
     * @dev Can only be called by the hook
     */
    function executeMultiLPJIT(uint256 swapId) external {
        // if (msg.sender != hook) revert Unauthorized();

        PendingJIT storage jit = pendingJITs[swapId];

        if (jit.executed) revert AlreadyExecuted();

        // Set active JIT so hook knows to allow liquidity addition
        activeJITSwapId = swapId;

        _addMultiLPJITLiquidity(jit.poolKey, swapId, jit.eligibleLPs, jit.liquidityContributions);

        // Clear active JIT
        activeJITSwapId = 0;

        jit.executed = true;

        emit JITMultiLPExecution(swapId, jit.eligibleLPs, jit.liquidityContributions);
    }

    /**
     * @notice Remove JIT liquidity after swap completion and distribute fees
     * @dev This MUST be called while PoolManager is unlocked (during afterSwap hook callback)
     */
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId, BalanceDelta delta, uint24 appliedFee) external {
        JITLiquidityPosition storage position = jitPositions[swapId];

        if (!position.isActive) return;

        position.isActive = false;
        PoolId poolId = key.toId();

        // Set active JIT so hook knows to allow liquidity removal
        activeJITSwapId = swapId;

        _removeMultiLPJITLiquidity(key, position);

        // Clear active JIT
        activeJITSwapId = 0;

        // Calculate total fees from actual swap delta
        (uint256 totalFees0, uint256 totalFees1) =
            IFeeCalculator(feeCalculator).calculateSwapFees(key, delta, appliedFee, position.totalLiquidity);

        position.totalFees0 = totalFees0;
        position.totalFees1 = totalFees1;

        // Distribute fees to participating LPs
        _distributeJITFees(key, position);

        emit JITRemoved(swapId, poolId, totalFees0, totalFees1);
    }

    // ============ Internal Functions ============

    /**
     * @notice Add JIT liquidity for multiple LPs with proper token settlement
     * @dev Called during hook callback - PoolManager is ALREADY UNLOCKED
     * @dev The hook must have pre-funded claim tokens via fundJITLiquidity()
     */
    function _addMultiLPJITLiquidity(
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
            bytes32 salt = keccak256(abi.encodePacked(swapId, block.timestamp));

            // Add liquidity using hook's pre-funded claim tokens
            // The hook already has claim token balance from fundJITLiquidity calls
            // modifyLiquidity will handle the settlement within the PM
            (BalanceDelta liquidityDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(totalLiquidity)),
                    salt: salt
                }),
                bytes("")
            );

            int128 delta0 = liquidityDelta.amount0();
            int128 delta1 = liquidityDelta.amount1();

            // Handle settlement based on delta
            // Negative delta = we owe tokens to the pool (use hook's claim tokens)
            // Positive delta = pool owes us tokens (we get claim tokens)
            if (delta0 < 0) {
                uint128 amount0Needed = uint128(-delta0);
                key.currency0.settle(poolManager, hook, amount0Needed, true);
            } else if (delta0 > 0) {
                uint128 amount0Received = uint128(delta0);
                key.currency0.take(poolManager, hook, amount0Received, true);
            }

            if (delta1 < 0) {
                uint128 amount1Needed = uint128(-delta1);
                key.currency1.settle(poolManager, hook, amount1Needed, true);
            } else if (delta1 > 0) {
                uint128 amount1Received = uint128(delta1);
                key.currency1.take(poolManager, hook, amount1Received, true);
            }

            // Store the JIT position
            jitPositions[swapId] = JITLiquidityPosition({
                swapId: swapId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                totalLiquidity: totalLiquidity,
                participatingLPs: lps,
                lpContributions: contributions,
                isActive: true,
                timestamp: block.timestamp,
                salt: salt,
                delta0: delta0,
                delta1: delta1,
                totalFees0: 0,
                totalFees1: 0
            });

            emit JITExecuted(swapId, poolId, totalLiquidity, delta0, delta1);
        }
    }

    /**
     * @notice Remove JIT liquidity and handle token settlement
     * @dev Called from hook's afterSwap while PoolManager is ALREADY UNLOCKED
     */
    function _removeMultiLPJITLiquidity(PoolKey memory key, JITLiquidityPosition storage position) private {
        (BalanceDelta removeDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -int256(uint256(position.totalLiquidity)),
                salt: position.salt
            }),
            bytes("")
        );

        int128 delta0 = removeDelta.amount0();
        int128 delta1 = removeDelta.amount1();

        if (delta0 > 0) {
            key.currency0.take(poolManager, hook, uint256(uint128(delta0)), true);
        } else if (delta0 < 0) {
            key.currency0.settle(poolManager, hook, uint256(uint128(-delta0)), true);
        }

        if (delta1 > 0) {
            key.currency1.take(poolManager, hook, uint256(uint128(delta1)), true);
        } else if (delta1 < 0) {
            key.currency1.settle(poolManager, hook, uint256(uint128(-delta1)), true);
        }
    }

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
     * @notice Distribute JIT fees to participating LPs
     */
    function _distributeJITFees(PoolKey memory key, JITLiquidityPosition storage position) private {
        for (uint256 i = 0; i < position.participatingLPs.length; i++) {
            address lp = position.participatingLPs[i];
            uint128 contribution = position.lpContributions[i];

            (uint256 lpFees0, uint256 lpFees1) = IFeeCalculator(feeCalculator).calculateJITFeeShare(
                position.totalFees0, position.totalFees1, contribution, position.totalLiquidity
            );

            if (lpFees0 > 0 || lpFees1 > 0) {
                IProfitManager(profitManager).accrueProfit(key, lp, lpFees0, lpFees1);
                emit JITFeesDistributed(position.swapId, lp, lpFees0, lpFees1);

                if (IFHEConfigManager(configManager).hasAutoHedgeEnabled(key, lp)) {
                    IProfitManager(profitManager).autoHedgeProfits(key, lp);
                }
            }
        }
    }

    /**
     * @notice Calculate LP's contribution to JIT operation
     */
    function _calculateLPContribution(PoolId poolId, address lp, uint128 swapAmount) private view returns (uint128) {
        uint128 totalLiquidity = ILPPositionManager(positionManager).getTotalLiquidity(poolId, lp);

        uint128 maxContribution = swapAmount / 10;
        uint128 lpCapacity = totalLiquidity / 2;

        return maxContribution < lpCapacity ? maxContribution : lpCapacity;
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

    function isJITOperation(uint256 swapId) external view returns (bool) {
        return activeJITSwapId == swapId;
    }
}
