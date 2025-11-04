// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IFHEConfigManager {
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint128 calldata maxLiquidity,
        InEuint32 calldata profitThreshold,
        InEuint32 calldata hedgePercentage,
        bool autoHedgeEnabled
    ) external;

    function deactivateLP(PoolKey calldata poolKey) external;
    function isActive(PoolKey calldata poolKey, address lp) external view returns (bool);
    function hasAutoHedgeEnabled(PoolKey calldata poolKey, address lp) external view returns (bool);
    function meetsThreshold(PoolKey calldata poolKey, address lp, uint128 swapAmount) external view returns (bool);
}
