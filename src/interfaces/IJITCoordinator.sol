// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface IJITCoordinator {
    function evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        external
        view
        returns (address[] memory eligibleLPs, uint128[] memory contributions);

    function createMultiLPJIT(
        PoolKey calldata key,
        address swapper,
        uint128 swapAmount,
        SwapParams calldata params,
        address[] memory eligibleLPs,
        uint128[] memory contributions
    ) external returns (uint256 swapId);

    function getJITExecutionParams(uint256 swapId)
        external
        view
        returns (
            int24 tickLower,
            int24 tickUpper,
            uint128 totalLiquidity,
            address[] memory lps,
            uint128[] memory contributions
        );

    function getJITPositionForRemoval(uint256 swapId)
        external
        view
        returns (bool isActive, int24 tickLower, int24 tickUpper, uint128 totalLiquidity);

    function removeJITLiquidityWithAutoHedge(
        PoolKey calldata key,
        uint256 swapId,
        BalanceDelta delta,
        uint24 appliedFee
    ) external returns (address[] memory autoHedgeLPs, uint256[] memory amounts0, uint256[] memory amounts1);

    function executeMultiLPJIT(uint256 swapId) external;
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId, BalanceDelta delta, uint24 appliedFee) external;
    function isJITActive(uint256 swapId) external view returns (bool);
    function getJITFees(uint256 swapId) external view returns (uint256 fees0, uint256 fees1);
    function recordJITExecution(uint256 swapId, int24 tickLower, int24 tickUpper, uint128 totalLiquidity) external;
}
