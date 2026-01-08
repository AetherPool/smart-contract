// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IProfitManager {
    function getLPProfits(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 profits0, uint256 profits1);

    function withdrawProfits(PoolKey calldata poolKey, address lp) external returns (uint256 amount0, uint256 amount1);

    function checkAndExecuteAutoHedge(PoolKey calldata poolKey, address lp)
        external
        returns (bool shouldHedge, uint256 amount0, uint256 amount1, bool token0Triggered, bool token1Triggered);

    function accrueProfit(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external;
}
