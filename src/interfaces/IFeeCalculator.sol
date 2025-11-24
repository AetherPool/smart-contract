// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface IFeeCalculator {
    function calculateSwapFees(PoolKey calldata key, BalanceDelta delta, uint24 feeTier, uint128 totalLiquidity)
        external
        returns (uint256 fees0, uint256 fees1);

    function calculatePositionFees(PoolKey calldata key, address lp, uint256 tokenId, uint128 liquidity)
        external
        view
        returns (uint256 tokensOwed0, uint256 tokensOwed1);

    function calculateJITFeeShare(uint256 totalFees0, uint256 totalFees1, uint128 lpLiquidity, uint128 totalLiquidity)
        external
        pure
        returns (uint256 lpFees0, uint256 lpFees1);

    function getPositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId)
        external
        view
        returns (uint256 feeGrowth0, uint256 feeGrowth1);

    function getGlobalFeeGrowth(PoolId poolId) external view returns (uint256 feeGrowth0, uint256 feeGrowth1);
    function updatePositionFeeCheckpoint(PoolKey calldata key, address lp, uint256 tokenId) external;
}
