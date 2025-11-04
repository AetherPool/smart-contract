// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface ILPPositionManager {
    function depositLiquidity(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        uint128 amount0Max,
        uint128 amount1Max,
        address depositor
    ) external returns (uint256 tokenId);

    function removeLiquidity(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta, address withdrawer)
        external
        returns (uint128 amount0, uint128 amount1);
}
