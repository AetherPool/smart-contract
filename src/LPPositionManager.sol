// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LPPositionManager
 * @notice Manages LP positions with internal ERC-6909-style token tracking
 * @dev Handles liquidity deposits, withdrawals, and position tracking without complex v4 settlement
 */
contract LPPositionManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Data Structures ============

    struct LPPosition {
        uint256 tokenId; // Unique position identifier
        int24 tickLower; // Lower tick bound
        int24 tickUpper; // Upper tick bound
        uint128 liquidity; // Liquidity amount
        uint128 token0Amount; // Token0 amount deposited
        uint128 token1Amount; // Token1 amount deposited
        uint256 lastFeeGrowth0; // Fee growth tracking
        uint256 lastFeeGrowth1;
        uint256 uncollectedFees0; // Uncollected fees
        uint256 uncollectedFees1;
        bool isActive; // Position status
    }

    // ============ Storage ============

    mapping(PoolId => mapping(address => LPPosition[])) public lpPositions;
    mapping(PoolId => mapping(uint256 => address)) public tokenIdToLP;
    mapping(PoolId => address[]) public poolLPs;
    mapping(PoolId => mapping(address => bool)) public isLPRegistered;

    uint256 public nextTokenId = 1;
    address public hook; // Main hook contract address

    // ============ Events ============

    event LPTokenMinted(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);

    event LPTokenBurned(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);

    event LiquidityAdded(
        address indexed lp, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );

    event LiquidityRemoved(address indexed lp, PoolId indexed poolId, uint128 liquidity);

    // ============ Errors ============

    error Unauthorized();
    error InvalidLiquidity();
    error NotTokenOwner();
    error InsufficientLiquidity();
    error PositionNotFound();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(address _hook) {
        hook = _hook;
    }

    // ============ External Functions ============

    /**
     * @notice Deposit liquidity and receive internal LP token
     * @param poolKey The pool to add liquidity to
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param liquidityDelta Amount of liquidity to add
     * @param amount0Max Maximum token0 to deposit
     * @param amount1Max Maximum token1 to deposit
     * @param depositor Address depositing liquidity
     * @return tokenId Unique identifier for the LP position
     */
    function depositLiquidity(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 amount0Max,
        uint128 amount1Max,
        address depositor
    ) external returns (uint256 tokenId) {
        if (liquidityDelta == 0) revert InvalidLiquidity();

        PoolId poolId = poolKey.toId();

        // Transfer tokens from depositor to this contract
        IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(depositor, address(this), amount0Max);
        IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(depositor, address(this), amount1Max);

        // Generate unique token ID
        tokenId = nextTokenId++;

        // Create and store LP position
        LPPosition memory newPosition = LPPosition({
            tokenId: tokenId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidityDelta,
            token0Amount: amount0Max,
            token1Amount: amount1Max,
            lastFeeGrowth0: 0,
            lastFeeGrowth1: 0,
            uncollectedFees0: 0,
            uncollectedFees1: 0,
            isActive: true
        });

        lpPositions[poolId][depositor].push(newPosition);
        tokenIdToLP[poolId][tokenId] = depositor;

        // Register LP if not already registered
        if (!isLPRegistered[poolId][depositor]) {
            poolLPs[poolId].push(depositor);
            isLPRegistered[poolId][depositor] = true;
        }

        emit LPTokenMinted(depositor, poolId, tokenId, liquidityDelta);
        emit LiquidityAdded(depositor, poolId, tickLower, tickUpper, liquidityDelta);

        return tokenId;
    }

    /**
     * @notice Remove liquidity by burning internal LP token
     * @param poolKey The pool to remove liquidity from
     * @param tokenId The LP token ID to burn
     * @param liquidityDelta Amount of liquidity to remove
     * @param withdrawer Address withdrawing liquidity
     * @return amount0 Token0 amount returned
     * @return amount1 Token1 amount returned
     */
    function removeLiquidity(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta, address withdrawer)
        external
        onlyHook
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toId();

        if (tokenIdToLP[poolId][tokenId] != withdrawer) revert NotTokenOwner();

        // Find and update the position
        LPPosition[] storage positions = lpPositions[poolId][withdrawer];
        bool found = false;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tokenId == tokenId) {
                if (positions[i].liquidity < liquidityDelta) revert InsufficientLiquidity();

                // Calculate proportional amounts to return
                amount0 = uint128((uint256(positions[i].token0Amount) * liquidityDelta) / positions[i].liquidity);
                amount1 = uint128((uint256(positions[i].token1Amount) * liquidityDelta) / positions[i].liquidity);

                // Update position
                positions[i].liquidity -= liquidityDelta;
                positions[i].token0Amount -= amount0;
                positions[i].token1Amount -= amount1;

                if (positions[i].liquidity == 0) {
                    positions[i].isActive = false;
                }

                // Transfer tokens back to withdrawer
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(withdrawer, amount0);
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(withdrawer, amount1);

                emit LPTokenBurned(withdrawer, poolId, tokenId, liquidityDelta);
                emit LiquidityRemoved(withdrawer, poolId, liquidityDelta);

                found = true;
                break;
            }
        }

        if (!found) revert PositionNotFound();

        return (amount0, amount1);
    }

    /**
     * @notice Update position fee tracking (called by hook after swaps)
     * @param poolId Pool identifier
     * @param lp LP address
     * @param tokenId Position token ID
     * @param fees0 Token0 fees earned
     * @param fees1 Token1 fees earned
     */
    function updatePositionFees(PoolId poolId, address lp, uint256 tokenId, uint256 fees0, uint256 fees1)
        external
        onlyHook
    {
        LPPosition[] storage positions = lpPositions[poolId][lp];

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tokenId == tokenId && positions[i].isActive) {
                positions[i].uncollectedFees0 += fees0;
                positions[i].uncollectedFees1 += fees1;
                break;
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get all positions for an LP in a pool
     * @param poolKey Pool to query
     * @param lp LP address
     * @return Array of LP positions
     */
    function getLPPositions(PoolKey calldata poolKey, address lp) external view returns (LPPosition[] memory) {
        PoolId poolId = poolKey.toId();
        return lpPositions[poolId][lp];
    }

    /**
     * @notice Get all LPs in a pool
     * @param poolKey Pool to query
     * @return Array of LP addresses
     */
    function getPoolLPs(PoolKey calldata poolKey) external view returns (address[] memory) {
        return poolLPs[poolKey.toId()];
    }

    /**
     * @notice Check if address is registered LP
     * @param poolKey Pool to query
     * @param lp LP address
     * @return Whether LP is registered
     */
    function isRegistered(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return isLPRegistered[poolKey.toId()][lp];
    }

    /**
     * @notice Get position owner
     * @param poolKey Pool to query
     * @param tokenId Token ID
     * @return Owner address
     */
    function getTokenOwner(PoolKey calldata poolKey, uint256 tokenId) external view returns (address) {
        return tokenIdToLP[poolKey.toId()][tokenId];
    }

    /**
     * @notice Check if LP has overlapping position with JIT range
     * @param poolId Pool identifier
     * @param lp LP address
     * @param currentTick Current pool tick
     * @param tickRange JIT tick range
     * @return Whether LP has overlapping positions
     */
    function hasOverlappingPosition(PoolId poolId, address lp, int24 currentTick, int24 tickRange)
        external
        view
        returns (bool)
    {
        LPPosition[] memory positions = lpPositions[poolId][lp];
        int24 jitLower = currentTick - tickRange;
        int24 jitUpper = currentTick + tickRange;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                if (positions[i].tickLower <= jitUpper && positions[i].tickUpper >= jitLower) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Get total liquidity for an LP across all positions
     * @param poolId Pool identifier
     * @param lp LP address
     * @return Total liquidity amount
     */
    function getTotalLiquidity(PoolId poolId, address lp) external view returns (uint128) {
        LPPosition[] memory positions = lpPositions[poolId][lp];
        uint128 totalLiquidity = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                totalLiquidity += positions[i].liquidity;
            }
        }

        return totalLiquidity;
    }
}
