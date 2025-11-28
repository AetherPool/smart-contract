// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
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

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract HookSwapRouterTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
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

    uint256 public constant SWAP_AMOUNT = 100000;

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        positionManager = new LPPositionManager(hookAddress, address(manager), "LP NFT");
        configManager = new FHEConfigManager();
        feeCalculator = new FeeCalculator();

        vm.prank(hookAddress);
        feeManager = new DynamicFeeManager(hookAddress, OWNER);

        profitManager = new ProfitManager(address(configManager));
        jitCoordinator = new JITCoordinator(
            manager,
            hookAddress,
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

        hook.depositLiquidityWithAmounts(key, -60, 60, 50000, 50000, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 50000, 50000, false);
        hook.depositLiquidityWithAmounts(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50000, 50000, false
        );
        vm.stopPrank();
    }

    function testswapExactInputForOutput() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        uint256 balance0Before = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance1Before = MockERC20(tokenOut).balanceOf(TRADER);

        vm.prank(TRADER);
        vm.expectEmit(true, true, true, false);
        emit Swap(TRADER, tokenIn, tokenOut, SWAP_AMOUNT, 0);
        uint256 amountOut =
            hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);

        uint256 balance0After = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance1After = MockERC20(tokenOut).balanceOf(TRADER);

        assertEq(balance0Before - balance0After, SWAP_AMOUNT);
        assertGt(amountOut, 0);
        assertEq(balance1After - balance1Before, amountOut);
    }

    function testswapInputForExactOutput() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);
        uint256 exactAmountOut = 50000;
        uint256 maxAmountIn = 200000;

        uint256 balance0Before = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance1Before = MockERC20(tokenOut).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountIn =
            hookSwapRouter.swapInputForExactOutput(key, tokenIn, tokenOut, exactAmountOut, maxAmountIn, block.timestamp + 100);

        uint256 balance0After = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance1After = MockERC20(tokenOut).balanceOf(TRADER);

        assertEq(balance0Before - balance0After, amountIn);
        assertLt(amountIn, maxAmountIn);
        assertEq(balance1After - balance1Before, exactAmountOut);
    }

    function testSwapWithSlippageProtection() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);
        uint256 minAmountOut = 200000;

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.InsufficientOutputAmount.selector);
        hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, minAmountOut, block.timestamp + 100);
    }

    function testSwapReverseDirection() public {
        address tokenIn = Currency.unwrap(currency1);
        address tokenOut = Currency.unwrap(currency0);

        uint256 balance1Before = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance0Before = MockERC20(tokenOut).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 amountOut =
            hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);

        uint256 balance1After = MockERC20(tokenIn).balanceOf(TRADER);
        uint256 balance0After = MockERC20(tokenOut).balanceOf(TRADER);

        assertEq(balance1Before - balance1After, SWAP_AMOUNT);
        assertGt(amountOut, 0);
        assertEq(balance0After - balance0Before, amountOut);
    }

    function testSwapWithExpiredDeadline() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        vm.warp(block.timestamp + 200);

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.ExpiredDeadline.selector);
        hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp - 100);
    }

    function testSwapWithInvalidPath() public {
        address invalidToken = address(0x9999);
        address tokenOut = Currency.unwrap(currency1);

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.InvalidPath.selector);
        hookSwapRouter.swapExactInputForOutput(key, invalidToken, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);
    }

    function testSwapWithJITLiquidity() public {
        InEuint128 memory encMinSwap = createInEuint128(50000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 10000, 10000, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        vm.prank(TRADER);
        uint256 amountOut =
            hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);

        assertGt(amountOut, 0);

        (uint256 profits0, uint256 profits1) = profitManager.getLPProfits(key, LP1);
        assertTrue(profits0 > 0 || profits1 > 0);
    }

    function testMultipleSwaps() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        vm.startPrank(TRADER);

        uint256 amountOut1 = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);
        uint256 amountOut2 = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);
        uint256 amountOut3 = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);

        vm.stopPrank();

        assertGt(amountOut1, 0);
        assertGt(amountOut2, 0);
        assertGt(amountOut3, 0);
    }

    function testSwapWithDifferentAmounts() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        vm.startPrank(TRADER);

        uint256 smallOut = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, 10000, 0, block.timestamp + 100);
        uint256 mediumOut = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, 50000, 0, block.timestamp + 100);
        uint256 largeOut = hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, 100000, 0, block.timestamp + 100);

        vm.stopPrank();

        assertGt(mediumOut, smallOut);
        assertGt(largeOut, mediumOut);
    }

    function testSwapExactOutputWithRefund() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);
        uint256 exactAmountOut = 30000;
        uint256 maxAmountIn = 100000;

        uint256 balanceBefore = MockERC20(tokenIn).balanceOf(TRADER);

        vm.prank(TRADER);
        uint256 actualAmountIn =
            hookSwapRouter.swapInputForExactOutput(key, tokenIn, tokenOut, exactAmountOut, maxAmountIn, block.timestamp + 100);

        uint256 balanceAfter = MockERC20(tokenIn).balanceOf(TRADER);

        assertLt(actualAmountIn, maxAmountIn);
        assertEq(balanceBefore - balanceAfter, actualAmountIn);
    }

    function testSwapExactOutputExceedsMax() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);
        uint256 exactAmountOut = 80000;
        uint256 maxAmountIn = 50000;

        vm.prank(TRADER);
        vm.expectRevert(HookSwapRouter.ExcessiveInputAmount.selector);
        hookSwapRouter.swapInputForExactOutput(key, tokenIn, tokenOut, exactAmountOut, maxAmountIn, block.timestamp + 100);
    }

    function testLargeSwap() public {
        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);
        uint256 largeAmount = 500000;

        MockERC20(tokenIn).mint(TRADER, largeAmount);

        vm.prank(TRADER);
        uint256 amountOut =
            hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, largeAmount, 0, block.timestamp + 100);

        assertGt(amountOut, 0);
    }

    function testSwapWithHighGasFee() public {
        vm.txGasPrice(50 gwei);

        address tokenIn = Currency.unwrap(currency0);
        address tokenOut = Currency.unwrap(currency1);

        vm.prank(TRADER);
        uint256 amountOut =
            hookSwapRouter.swapExactInputForOutput(key, tokenIn, tokenOut, SWAP_AMOUNT, 0, block.timestamp + 100);

        assertGt(amountOut, 0);
    }

    function testSwapBothDirections() public {
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);

        vm.startPrank(TRADER);

        uint256 amountOut1 = hookSwapRouter.swapExactInputForOutput(key, token0, token1, SWAP_AMOUNT, 0, block.timestamp + 100);
        assertGt(amountOut1, 0);

        uint256 amountOut2 = hookSwapRouter.swapExactInputForOutput(key, token1, token0, SWAP_AMOUNT, 0, block.timestamp + 100);
        assertGt(amountOut2, 0);

        vm.stopPrank();
    }
}