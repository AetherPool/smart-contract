// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title FeeCalculator
 * @notice Calculates actual fees earned by LPs from swaps
 * @dev Uses liquidity proportions and swap deltas to determine fee distribution
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
     * @notice Calculate fees from swap delta
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
     * @notice Update position fee tracking after collection
     */
    function updatePositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId) external {
        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encodePacked(poolId, lp, tokenId));

        positionFeeGrowthInside0LastX128[positionKey] = feeGrowthGlobal0X128[poolId];
        positionFeeGrowthInside1LastX128[positionKey] = feeGrowthGlobal1X128[poolId];

        emit PositionFeesUpdated(positionKey, 0, 0);
    }

    /**
     * @notice Calculate JIT liquidity fees based on participation
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
