// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title SlippageLib
 * @notice Pure library for slippage calculations
 * @dev Can be used in tests, contracts, and even off-chain (via eth_call)
 */
library SlippageLib {
    /**
     * @notice Calculate expected output for exact input
     * @param amountIn Input amount
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap
     * @return expectedOut Expected output amount
     */
    function calculateExpectedOutput(uint256 amountIn, uint256 priceRatio, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedOut)
    {
        if (zeroForOne) {
            // Selling token0 for token1: output = input * price
            expectedOut = FullMath.mulDiv(amountIn, priceRatio, 1e18);
        } else {
            // Selling token1 for token0: output = input / price
            expectedOut = FullMath.mulDiv(amountIn, 1e18, priceRatio);
        }

        return expectedOut;
    }

    /**
     * @notice Calculate minimum output with slippage protection
     * @param expectedOut Expected output without slippage
     * @param slippageBps Slippage tolerance in basis points (100 = 1%)
     * @return minOut Minimum acceptable output
     */
    function applySlippageToOutput(uint256 expectedOut, uint256 slippageBps) internal pure returns (uint256 minOut) {
        // minOut = expectedOut * (10000 - slippageBps) / 10000
        minOut = FullMath.mulDiv(expectedOut, 10000 - slippageBps, 10000);
        return minOut;
    }

    /**
     * @notice Calculate minimum output (convenience function)
     * @param amountIn Input amount
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap
     * @param slippageBps Slippage tolerance in basis points
     * @return minOut Minimum acceptable output
     */
    function calculateMinOutput(uint256 amountIn, uint256 priceRatio, bool zeroForOne, uint256 slippageBps)
        internal
        pure
        returns (uint256 minOut)
    {
        uint256 expectedOut = calculateExpectedOutput(amountIn, priceRatio, zeroForOne);
        minOut = applySlippageToOutput(expectedOut, slippageBps);
        return minOut;
    }

    /**
     * @notice Calculate expected input for exact output
     * @param amountOut Output amount
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap
     * @return expectedIn Expected input amount
     */
    function calculateExpectedInput(uint256 amountOut, uint256 priceRatio, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedIn)
    {
        if (zeroForOne) {
            // Buying token1 with token0: input = output / price
            expectedIn = FullMath.mulDiv(amountOut, 1e18, priceRatio);
        } else {
            // Buying token0 with token1: input = output * price
            expectedIn = FullMath.mulDiv(amountOut, priceRatio, 1e18);
        }

        return expectedIn;
    }

    /**
     * @notice Calculate maximum input with slippage protection
     * @param expectedIn Expected input without slippage
     * @param slippageBps Slippage tolerance in basis points (100 = 1%)
     * @return maxIn Maximum acceptable input
     */
    function applySlippageToInput(uint256 expectedIn, uint256 slippageBps) internal pure returns (uint256 maxIn) {
        // maxIn = expectedIn * (10000 + slippageBps) / 10000
        maxIn = FullMath.mulDiv(expectedIn, 10000 + slippageBps, 10000);
        return maxIn;
    }

    /**
     * @notice Calculate maximum input (convenience function)
     * @param amountOut Output amount
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap
     * @param slippageBps Slippage tolerance in basis points
     * @return maxIn Maximum acceptable input
     */
    function calculateMaxInput(uint256 amountOut, uint256 priceRatio, bool zeroForOne, uint256 slippageBps)
        internal
        pure
        returns (uint256 maxIn)
    {
        uint256 expectedIn = calculateExpectedInput(amountOut, priceRatio, zeroForOne);
        maxIn = applySlippageToInput(expectedIn, slippageBps);
        return maxIn;
    }

    /**
     * @notice Calculate actual slippage that occurred
     * @param expected Expected amount
     * @param actual Actual amount received
     * @return slippageBps Actual slippage in basis points
     */
    function calculateActualSlippage(uint256 expected, uint256 actual) internal pure returns (uint256 slippageBps) {
        if (actual >= expected) return 0;

        uint256 slippageAmount = expected - actual;
        slippageBps = FullMath.mulDiv(slippageAmount, 10000, expected);

        return slippageBps;
    }

    /**
     * @notice Convert slippage percentage to basis points
     * @param slippagePercent Slippage as percentage (e.g., 1 for 1%)
     * @return slippageBps Slippage in basis points (e.g., 100 for 1%)
     */
    function percentToBps(uint256 slippagePercent) internal pure returns (uint256 slippageBps) {
        return slippagePercent * 100;
    }

    /**
     * @notice Convert basis points to percentage
     * @param slippageBps Slippage in basis points (e.g., 100 for 1%)
     * @return slippagePercent Slippage as percentage (e.g., 1 for 1%)
     */
    function bpsToPercent(uint256 slippageBps) internal pure returns (uint256 slippagePercent) {
        return slippageBps / 100;
    }
}
