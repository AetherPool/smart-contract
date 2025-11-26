// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

interface ILPPositionManager {
    struct LPPosition {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 token0Amount;
        uint128 token1Amount;
        bool isActive;
        bool isJITEnabled;
        uint256 depositTimestamp;
    }

    function addLiquidity(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0,
        uint128 amount1,
        address depositor,
        bool isJITEnabled
    ) external returns (uint256 tokenId, uint128 liquidity);

    function removeLiquidity(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta, address withdrawer)
        external
        returns (uint128 amount0, uint128 amount1);

    function hasOverlappingPosition(PoolId poolId, address lp, int24 currentTick, int24 tickRange)
        external
        view
        returns (bool);

    function calculateLiquidityForAmounts(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function calculateAmountsForLiquidity(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function getPosition(PoolKey calldata poolKey, address lp, uint256 tokenId)
        external
        view
        returns (LPPosition memory);

    function getTotalLiquidity(PoolId poolId, address lp) external view returns (uint128);
    function getPoolLPs(PoolKey calldata poolKey) external view returns (address[] memory);
    function getJITEnabledLPs(PoolKey calldata poolKey) external view returns (address[] memory);
    function getCurrentPrice(PoolKey calldata poolKey) external view returns (uint160 sqrtPriceX96, int24 tick);
    function getPriceRatio(PoolKey calldata poolKey) external view returns (uint256 ratio);
}
