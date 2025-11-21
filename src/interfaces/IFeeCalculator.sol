// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface IFeeCalculator {
    /**
     * @notice Calculate fees from swap delta
     * @param key Pool key
     * @param delta Balance delta from swap
     * @param feeTier Fee tier in basis points
     * @param totalLiquidity Total liquidity at current tick
     * @return fees0 Fees in token0
     * @return fees1 Fees in token1
     */
    function calculateSwapFees(PoolKey calldata key, BalanceDelta delta, uint24 feeTier, uint128 totalLiquidity)
        external
        returns (uint256 fees0, uint256 fees1);

    /**
     * @notice Calculate fees owed to a specific position
     * @param key Pool key
     * @param lp LP address
     * @param tokenId Position token ID
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param liquidity Position liquidity
     * @return tokensOwed0 Fees owed in token0
     * @return tokensOwed1 Fees owed in token1
     */
    function calculatePositionFees(
        PoolKey calldata key,
        address lp,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view returns (uint256 tokensOwed0, uint256 tokensOwed1);

    /**
     * @notice Update position fee tracking after collection
     * @param key Pool key
     * @param lp LP address
     * @param tokenId Position token ID
     */
    function updatePositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId) external;

    /**
     * @notice Calculate JIT liquidity fees based on participation
     * @param totalFees0 Total fees in token0
     * @param totalFees1 Total fees in token1
     * @param lpLiquidity LP's contributed liquidity
     * @param totalLiquidity Total JIT liquidity
     * @return lpFees0 LP's share of fees in token0
     * @return lpFees1 LP's share of fees in token1
     */
    function calculateJITFeeShare(uint256 totalFees0, uint256 totalFees1, uint128 lpLiquidity, uint128 totalLiquidity)
        external
        pure
        returns (uint256 lpFees0, uint256 lpFees1);

    /**
     * @notice Get global fee growth for a pool
     * @param poolId Pool identifier
     * @return feeGrowth0 Global fee growth for token0
     * @return feeGrowth1 Global fee growth for token1
     */
    function getGlobalFeeGrowth(PoolId poolId) external view returns (uint256 feeGrowth0, uint256 feeGrowth1);

    /**
     * @notice Get position's last fee growth checkpoint
     * @param key Pool key
     * @param lp LP address
     * @param tokenId Position token ID
     * @return feeGrowth0 Last checkpoint for token0
     * @return feeGrowth1 Last checkpoint for token1
     */
    function getPositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId)
        external
        view
        returns (uint256 feeGrowth0, uint256 feeGrowth1);
}
