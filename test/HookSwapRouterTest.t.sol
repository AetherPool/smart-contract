// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {HookSwapRouter} from "../src/HookSwapRouter.sol";
import {SlippageLib} from "../src/libraries/SlippageLib.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

/**
 * @title HookSwapRouterTest
 * @notice Comprehensive tests for swap router functionality
 * @dev Tests both directions, slippage, exact input/output, and edge cases
 */
contract HookSwapRouterTest is Test, Deployers, CoFheTest {
    using CurrencyLibrary for Currency;

    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;
    HookSwapRouter public hookSwapRouter;

    address public constant LP1 = address(0x2222);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        positionManager = new LPPositionManager(address(manager), "LP NFT");
        configManager = new FHEConfigManager();
        feeManager = new DynamicFeeManager(OWNER);
        profitManager = new ProfitManager(address(configManager));
        feeCalculator = new FeeCalculator();
        jitCoordinator = new JITCoordinator(
            manager,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
        );

        deployCodeTo(
            "ZKJITLiquidityHook.sol",
            abi.encode(
                manager,
                address(positionManager),
                address(configManager),
                address(feeManager),
                address(profitManager),
                address(jitCoordinator),
                address(feeCalculator)
            ),
            hookAddress
        );
        hook = ZKJITLiquidityHook(hookAddress);

        jitCoordinator.updateHook(address(hook));
        positionManager.updateHook(address(hook));
        feeManager.updateHook(address(hook));

        hookSwapRouter = new HookSwapRouter(manager);

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        _setupTestAccounts();
        _addBaseLiquidity();
    }

    function _setupTestAccounts() private {
        address[2] memory accounts = [LP1, TRADER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);
            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            vm.startPrank(accounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(hookSwapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hookSwapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _addBaseLiquidity() private {
        address baseLP = address(0x1111);
        vm.deal(baseLP, 100 ether);

        MockERC20(Currency.unwrap(currency0)).mint(baseLP, 200000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(baseLP, 200000 ether);

        vm.startPrank(baseLP);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.depositLiquidityWithAmounts(key, -120, 120, 50000, 50000, false);
        hook.depositLiquidityWithAmounts(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50000, 50000, false
        );
        vm.stopPrank();
    }

    // ============ Test: Exact Input Swaps ============

    function testSwapExactInput_ZeroForOne() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);

        uint256 balanceBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0), // tokenIn
            Currency.unwrap(currency1), // tokenOut
            amountIn,
            minOut,
            block.timestamp + 10 minutes
        );

        uint256 balanceAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        assertGt(amountOut, 0, "Should receive tokens");
        assertGe(amountOut, minOut, "Should meet minimum output");
        assertEq(balanceAfter - balanceBefore, amountOut, "Balance should match output");
    }

    function testSwapExactInput_OneForZero() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100; // 1%

        // For oneForZero (zeroForOne = false), we're selling token1 for token0
        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, false, slippageBps);

        uint256 balanceBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency1), // tokenIn (reversed)
            Currency.unwrap(currency0), // tokenOut (reversed)
            amountIn,
            minOut,
            block.timestamp + 10 minutes
        );

        uint256 balanceAfter = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);

        assertGt(amountOut, 0, "Should receive tokens");
        assertGe(amountOut, minOut, "Should meet minimum output");
        assertEq(balanceAfter - balanceBefore, amountOut, "Balance should match output");
    }

    function testSwapExactInput_LargeAmount() public {
        uint256 amountIn = 50000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 300; // 3% for large swap

        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);

        vm.prank(TRADER);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountIn, minOut, block.timestamp + 10 minutes
        );

        assertGt(amountOut, 0, "Should receive tokens");
        assertGe(amountOut, minOut, "Should meet minimum output");
    }

    function testSwapExactInput_SlippageProtection() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);

        // Set unrealistic minimum (higher than possible output)
        uint256 unrealisticMin = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, 0) * 2;

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.InsufficientOutputAmount.selector);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            amountIn,
            unrealisticMin,
            block.timestamp + 10 minutes
        );
    }

    function testSwapExactInput_DeadlineExpired() public {
        uint256 amountIn = 1000;
        uint256 minOut = 900;
        uint256 pastDeadline = block.timestamp - 1;

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.ExpiredDeadline.selector);
        hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountIn, minOut, pastDeadline
        );
    }

    // ============ Test: Exact Output Swaps ============

    function testSwapExactOutput_ZeroForOne() public {
        uint256 amountOut = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100; // 1%

        uint256 maxIn = SlippageLib.calculateMaxInput(amountOut, priceRatio, true, slippageBps);

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountIn = hookSwapRouter.swapExactOutputForInput(
            key,
            Currency.unwrap(currency0), // tokenIn
            Currency.unwrap(currency1), // tokenOut
            amountOut,
            maxIn,
            block.timestamp + 10 minutes
        );

        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);
        uint256 balance1After = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        assertGt(amountIn, 0, "Should spend tokens");
        assertLe(amountIn, maxIn, "Should not exceed max input");
        assertEq(balance0Before - balance0After, amountIn, "Input balance should match");
        assertEq(balance1After - balance1Before, amountOut, "Output balance should match exactly");
    }

    function testSwapExactOutput_OneForZero() public {
        uint256 amountOut = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100; // 1%

        // For oneForZero (zeroForOne = false), we're buying token0 with token1
        uint256 maxIn = SlippageLib.calculateMaxInput(amountOut, priceRatio, false, slippageBps);

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountIn = hookSwapRouter.swapExactOutputForInput(
            key,
            Currency.unwrap(currency1), // tokenIn (reversed)
            Currency.unwrap(currency0), // tokenOut (reversed)
            amountOut,
            maxIn,
            block.timestamp + 10 minutes
        );

        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(TRADER);
        uint256 balance1After = MockERC20(Currency.unwrap(currency1)).balanceOf(TRADER);

        assertGt(amountIn, 0, "Should spend tokens");
        assertLe(amountIn, maxIn, "Should not exceed max input");
        assertEq(balance1Before - balance1After, amountIn, "Input balance should match");
        assertEq(balance0After - balance0Before, amountOut, "Output balance should match exactly");
    }

    function testSwapExactOutput_SlippageProtection() public {
        uint256 amountOut = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);

        // Set unrealistic max (lower than required input)
        uint256 unrealisticMax = SlippageLib.calculateMaxInput(amountOut, priceRatio, true, 0) / 2;

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.ExcessiveInputAmount.selector);
        hookSwapRouter.swapExactOutputForInput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            amountOut,
            unrealisticMax,
            block.timestamp + 10 minutes
        );
    }

    function testSwapExactOutput_LargeAmount() public {
        uint256 amountOut = 30000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 500; // 5% for large swap

        uint256 maxIn = SlippageLib.calculateMaxInput(amountOut, priceRatio, true, slippageBps);

        vm.prank(TRADER);
        uint256 amountIn = hookSwapRouter.swapExactOutputForInput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountOut, maxIn, block.timestamp + 10 minutes
        );

        assertGt(amountIn, 0, "Should spend tokens");
        assertLe(amountIn, maxIn, "Should not exceed max input");
    }

    // ============ Test: SlippageLib Functions ============

    function testSlippageLib_CalculateMinOutput() public pure {
        uint256 amountIn = 1000;
        uint256 priceRatio = 1e18; // 1:1 price
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);

        // Expected: 1000 * (1 - 0.01) = 990
        assertEq(minOut, 990, "Should apply 1% slippage");
    }

    function testSlippageLib_CalculateMaxInput() public pure {
        uint256 amountOut = 1000;
        uint256 priceRatio = 1e18; // 1:1 price
        uint256 slippageBps = 100; // 1%

        uint256 maxIn = SlippageLib.calculateMaxInput(amountOut, priceRatio, true, slippageBps);

        // Expected: 1000 * (1 + 0.01) = 1010
        assertEq(maxIn, 1010, "Should apply 1% slippage");
    }

    function testSlippageLib_ZeroForOne_vs_OneForZero() public pure {
        uint256 amount = 1000;
        uint256 priceRatio = 2e18; // 1 token0 = 2 token1
        uint256 slippageBps = 100;

        // ZeroForOne: Selling token0 for token1
        uint256 minOut0to1 = SlippageLib.calculateMinOutput(amount, priceRatio, true, slippageBps);
        // Expected: 1000 * 2 * 0.99 = 1980

        // OneForZero: Selling token1 for token0
        uint256 minOut1to0 = SlippageLib.calculateMinOutput(amount, priceRatio, false, slippageBps);
        // Expected: 1000 / 2 * 0.99 = 495

        assertEq(minOut0to1, 1980, "Should get more token1 when selling token0");
        assertEq(minOut1to0, 495, "Should get less token0 when selling token1");
    }

    function testSlippageLib_HighSlippage() public pure {
        uint256 amountIn = 1000;
        uint256 priceRatio = 1e18;
        uint256 slippageBps = 1000; // 10%

        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);

        // Expected: 1000 * 0.9 = 900
        assertEq(minOut, 900, "Should apply 10% slippage");
    }

    function testSlippageLib_ConversionFunctions() public pure {
        assertEq(SlippageLib.percentToBps(1), 100, "1% should be 100 bps");
        assertEq(SlippageLib.percentToBps(5), 500, "5% should be 500 bps");
        assertEq(SlippageLib.bpsToPercent(100), 1, "100 bps should be 1%");
        assertEq(SlippageLib.bpsToPercent(500), 5, "500 bps should be 5%");
    }

    function testSlippageLib_ActualSlippage() public pure {
        uint256 expected = 1000;
        uint256 actual = 990;

        uint256 slippage = SlippageLib.calculateActualSlippage(expected, actual);

        // (1000 - 990) / 1000 * 10000 = 100 bps = 1%
        assertEq(slippage, 100, "Should calculate 1% slippage");
    }

    // ============ Test: Edge Cases ============

    function testSwap_InvalidTokenPath() public {
        address randomToken = address(0x9999999);

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.InvalidPath.selector);
        hookSwapRouter.swapExactInputForOutput(
            key, randomToken, Currency.unwrap(currency1), 1000, 900, block.timestamp + 10 minutes
        );
    }

    function testSwap_ZeroAmount() public {
        vm.prank(TRADER);
        vm.expectRevert(); // Should revert on zero amount
        hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), 0, 0, block.timestamp + 10 minutes
        );
    }

    function testSwap_MultipleSwapsInSequence() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100;

        vm.startPrank(TRADER);

        // First swap: token0 -> token1
        uint256 minOut1 = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);
        uint256 amountOut1 = hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountIn, minOut1, block.timestamp + 10 minutes
        );

        // Second swap: token1 -> token0 (reverse)
        uint256 minOut2 = SlippageLib.calculateMinOutput(amountOut1, priceRatio, false, slippageBps);
        uint256 amountOut2 = hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency1),
            Currency.unwrap(currency0),
            amountOut1,
            minOut2,
            block.timestamp + 10 minutes
        );

        vm.stopPrank();

        assertGt(amountOut1, 0, "First swap should succeed");
        assertGt(amountOut2, 0, "Second swap should succeed");
        assertLt(amountOut2, amountIn, "Should lose some value due to fees");
    }

    function testSwap_VeryLowSlippage() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 1; // 0.01%

        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, slippageBps);

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.InsufficientOutputAmount.selector);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountIn, minOut, block.timestamp + 10 minutes
        );

        assertEq(amountOut, 0, "Should fail with low slippage for now");
    }

    // ============ Test: Gas Optimization ============

    function testSwap_GasUsage() public {
        uint256 amountIn = 1000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(amountIn, priceRatio, true, 100);

        vm.prank(TRADER);
        uint256 gasBefore = gasleft();
        hookSwapRouter.swapExactInputForOutput(
            key, Currency.unwrap(currency0), Currency.unwrap(currency1), amountIn, minOut, block.timestamp + 10 minutes
        );
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for swap", gasUsed);
        assertLt(gasUsed, 500000, "Should use reasonable gas");
    }
}
