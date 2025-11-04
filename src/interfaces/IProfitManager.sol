// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IProfitManager {
    function hedgeProfits(PoolKey calldata poolKey, uint256 hedgePercentage) external;
    function compoundProfits(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper) external returns (uint256);
    function batchHedgeProfits(PoolKey[] calldata poolKeys, uint256[] calldata hedgePercentages) external;
}
