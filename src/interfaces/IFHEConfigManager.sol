// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IFHEConfigManager {
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint32 calldata hedgePercentage0,
        InEuint32 calldata hedgePercentage1,
        bool autoHedgeEnabled
    ) external;

    function getDepositedAmounts(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function shouldAutoHedge(PoolKey calldata poolKey, address lp, uint256 currentProfits0, uint256 currentProfits1)
        external
        view
        returns (bool);

    function getHedgeTriggers(PoolKey calldata poolKey, address lp, uint256 currentProfits0, uint256 currentProfits1)
        external
        view
        returns (bool token0Triggered, bool token1Triggered);

    function updateDepositedAmounts(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external;
    function updateAutoHedge(PoolKey calldata poolKey, bool autoHedgeEnabled) external;
    function deactivateLP(PoolKey calldata poolKey) external;
    function reactivateLP(PoolKey calldata poolKey) external;
    function isActive(PoolKey calldata poolKey, address lp) external view returns (bool);
    function hasAutoHedgeEnabled(PoolKey calldata poolKey, address lp) external view returns (bool);
    function meetsThreshold(PoolKey calldata poolKey, address lp, uint128 swapAmount) external view returns (bool);
    function getHedgePercentage(PoolKey calldata poolKey, address lp) external view returns (uint256);
}
