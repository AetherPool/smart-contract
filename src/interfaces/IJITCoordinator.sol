// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface IJITCoordinator {
    /**
     * @notice Evaluate which LPs should participate in JIT operation
     * @param key Pool key
     * @param swapAmount Size of the incoming swap
     * @return eligibleLPs Array of LP addresses
     * @return contributions Array of LP contribution amounts
     */
    function evaluateMultiLPJIT(PoolKey calldata key, uint128 swapAmount)
        external
        view
        returns (address[] memory eligibleLPs, uint128[] memory contributions);

    /**
     * @notice Create multi-LP JIT operation
     * @param key Pool key
     * @param swapper Address initiating the swap
     * @param swapAmount Size of the swap
     * @param params Swap parameters
     * @param eligibleLPs Array of eligible LP addresses
     * @param contributions Array of LP contributions
     * @return swapId Unique identifier for this JIT operation
     */
    function createMultiLPJIT(
        PoolKey calldata key,
        address swapper,
        uint128 swapAmount,
        SwapParams calldata params,
        address[] memory eligibleLPs,
        uint128[] memory contributions
    ) external returns (uint256 swapId);

    /**
     * @notice Execute multi-LP JIT operation
     * @param swapId The JIT operation ID to execute
     */
    function executeMultiLPJIT(uint256 swapId) external;

    /**
     * @notice Remove JIT liquidity after swap completion and distribute fees
     * @param key Pool key
     * @param swapId The JIT operation ID
     * @param delta Balance delta from the swap
     * @param appliedFee The fee tier that was applied
     */
    function removeJITLiquidity(PoolKey calldata key, uint256 swapId, BalanceDelta delta, uint24 appliedFee) external;

    /**
     * @notice Check if JIT position is active
     * @param swapId Swap identifier
     * @return Whether position is active
     */
    function isJITActive(uint256 swapId) external view returns (bool);

    /**
     * @notice Get total fees collected by a JIT position
     * @param swapId Swap identifier
     * @return fees0 Total fees in token0
     * @return fees1 Total fees in token1
     */
    function getJITFees(uint256 swapId) external view returns (uint256 fees0, uint256 fees1);
}
