// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IProfitManager {
    function hedgeProfits(PoolKey calldata poolKey, uint256 hedgePercentage) external;
    function compoundProfits(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper) external returns (uint256);
    function batchHedgeProfits(PoolKey[] calldata poolKeys, uint256[] calldata hedgePercentages) external;
    function accrueProfit(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external;
    function autoHedgeProfits(PoolKey calldata poolKey, address lp) external;
    function withdrawProfits(PoolKey calldata poolKey) external;
    function getLPProfits(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 profits0, uint256 profits1);
}
