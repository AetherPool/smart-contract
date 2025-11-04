// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

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

    function getTotalLiquidity(PoolId poolId, address lp) external view returns (uint128);
    function hasOverlappingPosition(PoolId poolId, address lp, int24 currentTick, int24 tickRange)
        external
        view
        returns (bool);
}
