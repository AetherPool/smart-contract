// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/**
 * @title SlippageLib
 * @notice Pure library for slippage calculations in AMM swaps
 * @dev Can be used in contracts, tests, and off-chain via eth_call. All calculations use basis points (1 bp = 0.01%)
 */
library SlippageLib {
    // ============ Constants ============

    uint256 private constant BPS_DIVISOR = 10000;
    uint256 private constant PRICE_SCALE = 1e18;

    // ============ Output Calculations ============

    /**
     * @notice Calculate expected output for exact input swap
     * @param amountIn Input amount
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap (true = token0->token1)
     * @return expectedOut Expected output amount before slippage
     */
    function calculateExpectedOutput(uint256 amountIn, uint256 priceRatio, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedOut)
    {
        if (zeroForOne) {
            expectedOut = FullMath.mulDiv(amountIn, priceRatio, PRICE_SCALE);
        } else {
            expectedOut = FullMath.mulDiv(amountIn, PRICE_SCALE, priceRatio);
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
        minOut = FullMath.mulDiv(expectedOut, BPS_DIVISOR - slippageBps, BPS_DIVISOR);
        return minOut;
    }

    /**
     * @notice Calculate minimum output in one step (convenience function)
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

    // ============ Input Calculations ============

    /**
     * @notice Calculate expected input for exact output swap
     * @param amountOut Output amount desired
     * @param priceRatio Current price ratio (scaled by 1e18)
     * @param zeroForOne Direction of swap (true = token0->token1)
     * @return expectedIn Expected input amount before slippage
     */
    function calculateExpectedInput(uint256 amountOut, uint256 priceRatio, bool zeroForOne)
        internal
        pure
        returns (uint256 expectedIn)
    {
        if (zeroForOne) {
            expectedIn = FullMath.mulDiv(amountOut, PRICE_SCALE, priceRatio);
        } else {
            expectedIn = FullMath.mulDiv(amountOut, priceRatio, PRICE_SCALE);
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
        maxIn = FullMath.mulDiv(expectedIn, BPS_DIVISOR + slippageBps, BPS_DIVISOR);
        return maxIn;
    }

    /**
     * @notice Calculate maximum input in one step (convenience function)
     * @param amountOut Output amount desired
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

    // ============ Utility Functions ============

    /**
     * @notice Calculate actual slippage that occurred in a swap
     * @param expected Expected amount
     * @param actual Actual amount received
     * @return slippageBps Actual slippage in basis points
     */
    function calculateActualSlippage(uint256 expected, uint256 actual) internal pure returns (uint256 slippageBps) {
        if (actual >= expected) return 0;

        uint256 slippageAmount = expected - actual;
        slippageBps = FullMath.mulDiv(slippageAmount, BPS_DIVISOR, expected);

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
