// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title FeeCalculator
 * @notice Calculates and tracks swap fees earned by liquidity providers
 * @dev Uses fee growth tracking similar to Uniswap V3 for accurate fee distribution
 */
contract FeeCalculator {
    using PoolIdLibrary for PoolKey;

    // ============ Storage ============

    address public hook;

    mapping(PoolId => uint256) public feeGrowthGlobal0X128;
    mapping(PoolId => uint256) public feeGrowthGlobal1X128;
    mapping(bytes32 => uint256) public positionFeeGrowthInside0LastX128;
    mapping(bytes32 => uint256) public positionFeeGrowthInside1LastX128;

    // ============ Events ============

    event FeesCalculated(PoolId indexed poolId, uint256 fees0, uint256 fees1, uint256 feeGrowth0, uint256 feeGrowth1);
    event PositionFeesUpdated(bytes32 indexed positionKey, uint256 tokensOwed0, uint256 tokensOwed1);

    // ============ Errors ============

    error Unauthorized();
    error InvalidLiquidity();

    // ============ Constructor ============

    constructor() {}

    // ============ External Functions ============

    /**
     * @notice Calculate fees from swap delta and update global fee growth
     * @param key Pool key
     * @param delta Balance delta from swap
     * @param feeTier Fee tier in basis points
     * @param totalLiquidity Total liquidity in the pool
     * @return fees0 Fees collected in token0
     * @return fees1 Fees collected in token1
     */
    function calculateSwapFees(PoolKey calldata key, BalanceDelta delta, uint24 feeTier, uint128 totalLiquidity)
        external
        returns (uint256 fees0, uint256 fees1)
    {
        if (totalLiquidity == 0) return (0, 0);

        PoolId poolId = key.toId();
        int128 amount0Delta = delta.amount0();
        int128 amount1Delta = delta.amount1();

        if (amount0Delta != 0) {
            uint256 amount0Abs = amount0Delta > 0 ? uint256(int256(amount0Delta)) : uint256(int256(-amount0Delta));
            fees0 = (amount0Abs * feeTier) / 1_000_000;

            if (fees0 > 0) {
                feeGrowthGlobal0X128[poolId] += FullMath.mulDiv(fees0, FixedPoint128.Q128, totalLiquidity);
            }
        }

        if (amount1Delta != 0) {
            uint256 amount1Abs = amount1Delta > 0 ? uint256(int256(amount1Delta)) : uint256(int256(-amount1Delta));
            fees1 = (amount1Abs * feeTier) / 1_000_000;

            if (fees1 > 0) {
                feeGrowthGlobal1X128[poolId] += FullMath.mulDiv(fees1, FixedPoint128.Q128, totalLiquidity);
            }
        }

        emit FeesCalculated(poolId, fees0, fees1, feeGrowthGlobal0X128[poolId], feeGrowthGlobal1X128[poolId]);
        return (fees0, fees1);
    }

    /**
     * @notice Calculate fees owed to a specific position
     * @param key Pool key
     * @param lp LP address
     * @param tokenId Position token ID
     * @param liquidity Position liquidity
     * @return tokensOwed0 Tokens owed in token0
     * @return tokensOwed1 Tokens owed in token1
     */
    function calculatePositionFees(PoolKey calldata key, address lp, uint256 tokenId, uint128 liquidity)
        external
        view
        returns (uint256 tokensOwed0, uint256 tokensOwed1)
    {
        if (liquidity == 0) return (0, 0);

        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encodePacked(poolId, lp, tokenId));

        uint256 feeGrowthInside0X128 = feeGrowthGlobal0X128[poolId];
        uint256 feeGrowthInside1X128 = feeGrowthGlobal1X128[poolId];

        uint256 feeGrowthInside0DeltaX128 = feeGrowthInside0X128 - positionFeeGrowthInside0LastX128[positionKey];
        uint256 feeGrowthInside1DeltaX128 = feeGrowthInside1X128 - positionFeeGrowthInside1LastX128[positionKey];

        tokensOwed0 = FullMath.mulDiv(feeGrowthInside0DeltaX128, liquidity, FixedPoint128.Q128);
        tokensOwed1 = FullMath.mulDiv(feeGrowthInside1DeltaX128, liquidity, FixedPoint128.Q128);

        return (tokensOwed0, tokensOwed1);
    }

    /**
     * @notice Update position fee checkpoint after collection
     * @param key Pool key
     * @param lp LP address
     * @param tokenId Position token ID
     */
    function updatePositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId) external {
        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encodePacked(poolId, lp, tokenId));

        positionFeeGrowthInside0LastX128[positionKey] = feeGrowthGlobal0X128[poolId];
        positionFeeGrowthInside1LastX128[positionKey] = feeGrowthGlobal1X128[poolId];

        emit PositionFeesUpdated(positionKey, 0, 0);
    }

    /**
     * @notice Calculate proportional JIT fee share for an LP
     * @param totalFees0 Total fees in token0
     * @param totalFees1 Total fees in token1
     * @param lpLiquidity LP's liquidity contribution
     * @param totalLiquidity Total liquidity in JIT position
     * @return lpFees0 LP's share of fees in token0
     * @return lpFees1 LP's share of fees in token1
     */
    function calculateJITFeeShare(uint256 totalFees0, uint256 totalFees1, uint128 lpLiquidity, uint128 totalLiquidity)
        external
        pure
        returns (uint256 lpFees0, uint256 lpFees1)
    {
        if (totalLiquidity == 0 || lpLiquidity == 0) return (0, 0);

        lpFees0 = FullMath.mulDiv(totalFees0, lpLiquidity, totalLiquidity);
        lpFees1 = FullMath.mulDiv(totalFees1, lpLiquidity, totalLiquidity);

        return (lpFees0, lpFees1);
    }

    // ============ View Functions ============

    function getGlobalFeeGrowth(PoolId poolId) external view returns (uint256 feeGrowth0, uint256 feeGrowth1) {
        return (feeGrowthGlobal0X128[poolId], feeGrowthGlobal1X128[poolId]);
    }

    function getPositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId)
        external
        view
        returns (uint256 feeGrowth0, uint256 feeGrowth1)
    {
        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encodePacked(poolId, lp, tokenId));

        return (positionFeeGrowthInside0LastX128[positionKey], positionFeeGrowthInside1LastX128[positionKey]);
    }
}
