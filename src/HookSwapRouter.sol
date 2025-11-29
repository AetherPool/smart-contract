// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title HookSwapRouter
 * @notice User-friendly swap router for JIT liquidity pools
 * @dev Wraps Uniswap V4 swap functionality with simple interface for exact input/output swaps
 */
contract HookSwapRouter {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ============ Storage ============

    IPoolManager public immutable poolManager;

    // ============ Errors ============

    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error ExpiredDeadline();
    error InvalidPath();

    // ============ Events ============

    event Swap(
        address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    // ============ Constructor ============

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ============ External Functions ============

    /**
     * @notice Swap exact input tokens for output tokens with slippage protection
     * @param key Pool key
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Exact amount of input tokens
     * @param amountOutMinimum Minimum amount of output tokens (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return amountOut Amount of output tokens received
     */
    function swapExactInputForOutput(
        PoolKey calldata key,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert ExpiredDeadline();

        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);
        if (!zeroForOne && tokenIn != Currency.unwrap(key.currency1)) revert InvalidPath();
        if (tokenOut != (zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0))) {
            revert InvalidPath();
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(poolManager), amountIn);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory result = poolManager.unlock(abi.encode(key, params, msg.sender));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        amountOut = zeroForOne ? uint256(uint128(delta.amount1())) : uint256(uint128(delta.amount0()));
        if (amountOut < amountOutMinimum) revert InsufficientOutputAmount();

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
        return amountOut;
    }

    /**
     * @notice Swap input tokens for exact output tokens with slippage protection
     * @param key Pool key
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountOut Exact amount of output tokens desired
     * @param amountInMaximum Maximum amount of input tokens (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return amountIn Amount of input tokens used
     */
    function swapExactOutputForInput(
        PoolKey calldata key,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    ) external returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert ExpiredDeadline();

        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);
        if (!zeroForOne && tokenIn != Currency.unwrap(key.currency1)) revert InvalidPath();
        if (tokenOut != (zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0))) {
            revert InvalidPath();
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory result = poolManager.unlock(abi.encode(key, params, msg.sender, amountInMaximum, tokenIn));
        (, uint256 actualAmountIn) = abi.decode(result, (BalanceDelta, uint256));

        amountIn = actualAmountIn;
        if (amountIn > amountInMaximum) revert ExcessiveInputAmount();

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
        return amountIn;
    }

    /**
     * @notice Unlock callback for executing swaps
     * @param data Encoded swap data
     * @return bytes Encoded swap result
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");

        (PoolKey memory key, SwapParams memory params, address trader) =
            abi.decode(data, (PoolKey, SwapParams, address));

        if (params.amountSpecified > 0) {
            (,,, uint256 amountInMaximum, address tokenIn) =
                abi.decode(data, (PoolKey, SwapParams, address, uint256, address));

            BalanceDelta delta = poolManager.swap(key, params, ZERO_BYTES);

            bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);
            uint256 amountIn = zeroForOne ? uint256(uint128(-delta.amount0())) : uint256(uint128(-delta.amount1()));
            if (amountIn > amountInMaximum) revert ExcessiveInputAmount();

            IERC20(tokenIn).transferFrom(trader, address(this), amountIn);
            IERC20(tokenIn).approve(address(poolManager), amountIn);

            _settleSwap(key, delta, zeroForOne, trader);
            return abi.encode(delta, amountIn);
        } else {
            BalanceDelta delta = poolManager.swap(key, params, ZERO_BYTES);
            _settleSwap(key, delta, params.zeroForOne, trader);
            return abi.encode(delta);
        }
    }

    // ============ Internal Functions ============

    function _settleSwap(PoolKey memory key, BalanceDelta delta, bool zeroForOne, address trader) private {
        if (zeroForOne) {
            if (delta.amount0() < 0) {
                key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
            }
            if (delta.amount1() > 0) {
                key.currency1.take(poolManager, trader, uint256(uint128(delta.amount1())), false);
            }
        } else {
            if (delta.amount1() < 0) {
                key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
            }
            if (delta.amount0() > 0) {
                key.currency0.take(poolManager, trader, uint256(uint128(delta.amount0())), false);
            }
        }
    }

    // ============ Constants ============

    bytes internal constant ZERO_BYTES = "";
}
