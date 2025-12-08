// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
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
import {SlippageLib} from "../src/libraries/SlippageLib.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract ZKJITLiquidityHookTest is Test, Deployers, CoFheTest {
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
    address public constant LP2 = address(0x3333);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    uint128 public constant SWAP_AMOUNT = 100000;

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
        feeCalculator = new FeeCalculator();

        address hookAddr = hookAddress;
        vm.prank(hookAddr);
        feeManager = new DynamicFeeManager(OWNER);

        profitManager = new ProfitManager(address(configManager));
        jitCoordinator = new JITCoordinator(
            manager, address(positionManager), address(configManager), address(profitManager), address(feeCalculator)
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
    }

    function _setupTestAccounts() private {
        address[3] memory accounts = [LP1, LP2, TRADER];

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

    function testHookInitialization() public view {
        (
            address _positionManager,
            address _configManager,
            address _feeManager,
            address _profitManager,
            address _jitCoordinator,
            address _feeCalculator
        ) = hook.getModuleAddresses();

        assertEq(_positionManager, address(positionManager));
        assertEq(_configManager, address(configManager));
        assertEq(_feeManager, address(feeManager));
        assertEq(_profitManager, address(profitManager));
        assertEq(_jitCoordinator, address(jitCoordinator));
        assertEq(_feeCalculator, address(feeCalculator));
    }

    function testDepositPassiveLiquidity() public {
        vm.prank(LP1);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            hook.depositLiquidityWithAmounts(key, -120, 120, 5000, 5000, false);

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions.length, 1);
        assertFalse(positions[0].isJITEnabled);
    }

    function testDepositJITLiquidity() public {
        vm.prank(LP1);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            hook.depositLiquidityWithAmounts(key, -120, 120, 5000, 5000, true);

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions.length, 1);
        assertTrue(positions[0].isJITEnabled);
    }

    function testWithdrawLiquidity() public {
        vm.startPrank(LP1);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 5000, 5000, false);

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity);
        vm.stopPrank();

        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1After = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(balance0After - balance0Before, amount0);
        assertEq(balance1After - balance1Before, amount1);
    }

    function testSwapWithoutJIT() public {
        _addBaseLiquidity();

        // SwapParams memory params = SwapParams({
        //     zeroForOne: true,
        //     amountSpecified: -int256(uint256(SWAP_AMOUNT)),
        //     sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        // });

        // PoolSwapTest.TestSettings memory testSettings =
        //     PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // vm.prank(TRADER);
        // swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(SWAP_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_AMOUNT,
            minOut,
            block.timestamp + 10 minutes
        );

        assertGt(amountOut, 0);
        assertGe(amountOut, minOut);
    }

    function testSwapWithJIT() public {
        _addBaseLiquidity();

        InEuint128 memory encMinSwap = createInEuint128(50000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 10000, 10000, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(SWAP_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_AMOUNT,
            minOut,
            block.timestamp + 10 minutes
        );

        (uint256 profits0, uint256 profits1) = profitManager.getLPProfits(key, LP1);
        assertTrue(profits0 > 0 || profits1 > 0);
    }

    function testMultipleLPsJIT() public {
        _addBaseLiquidity();

        InEuint128 memory enc1MinSwap = createInEuint128(40000, LP1);
        InEuint32 memory enc1Hedge0 = createInEuint32(25, LP1);
        InEuint32 memory enc1Hedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 8000, 8000, true);
        vm.stopPrank();

        InEuint128 memory enc2MinSwap = createInEuint128(40000, LP2);
        InEuint32 memory enc2Hedge0 = createInEuint32(40, LP2);
        InEuint32 memory enc2Hedge1 = createInEuint32(35, LP2);

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 12000, 12000, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        vm.warp(block.timestamp + 10);

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(SWAP_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_AMOUNT,
            minOut,
            block.timestamp + 10 minutes
        );

        (uint256 lp1Profits0, uint256 lp1Profits1) = profitManager.getLPProfits(key, LP1);
        (uint256 lp2Profits0, uint256 lp2Profits1) = profitManager.getLPProfits(key, LP2);

        assertTrue(lp1Profits0 > 0 || lp1Profits1 > 0);
        assertTrue(lp2Profits0 > 0 || lp2Profits1 > 0);
    }

    function testGetCurrentPrice() public view {
        (uint160 sqrtPriceX96,) = hook.getCurrentPrice(key);
        assertGt(sqrtPriceX96, 0);
    }

    function testGetPriceRatio() public view {
        uint256 ratio = hook.getPriceRatio(key);
        assertGt(ratio, 0);
    }

    function testPreviewLiquidityForAmounts() public view {
        (uint128 liquidity, uint256 amount0, uint256 amount1) =
            hook.previewLiquidityForAmounts(key, -60, 60, 1000, 1000);

        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function testPreviewAmountsForLiquidity() public view {
        (uint256 amount0, uint256 amount1) = hook.previewAmountsForLiquidity(key, -60, 60, 10000);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function testDynamicFeeApplication() public {
        _addBaseLiquidity();

        vm.txGasPrice(25 gwei);

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(SWAP_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_AMOUNT,
            minOut,
            block.timestamp + 10 minutes
        );
    }

    function testPartialWithdrawal() public {
        vm.startPrank(LP1);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 10000, 10000, false);

        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity / 2);
        vm.stopPrank();

        assertGt(amount0, 0);
        assertGt(amount1, 0);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertTrue(positions[0].isActive);
        assertGt(positions[0].liquidity, 0);
    }

    function testJITWithInsufficientLiquidity() public {
        _addBaseLiquidity();

        InEuint128 memory encMinSwap = createInEuint128(500000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 1000, 1000, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(SWAP_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_AMOUNT,
            minOut,
            block.timestamp + 10 minutes
        );
    }

    function testMultipleSwaps() public {
        _addBaseLiquidity();

        InEuint128 memory encMinSwap = createInEuint128(50000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 10000, 10000, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        uint128 SWAP_A_AMOUNT = 50000;
        uint128 SWAP_B_AMOUNT = 30000;

        uint256 priceRatio = hook.getPriceRatio(key);
        bool zeroForOne = true;
        uint256 slippageBps = 100; // 1%

        uint256 minOutA = SlippageLib.calculateMinOutput(SWAP_A_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_A_AMOUNT,
            minOutA,
            block.timestamp + 10 minutes
        );

        (uint256 profitsAfterFirst0, uint256 profitsAfterFirst1) = profitManager.getLPProfits(key, LP1);

        uint256 minOutB = SlippageLib.calculateMinOutput(SWAP_B_AMOUNT, priceRatio, zeroForOne, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            SWAP_B_AMOUNT,
            minOutB,
            block.timestamp + 10 minutes
        );

        (uint256 profitsAfterSecond0, uint256 profitsAfterSecond1) = profitManager.getLPProfits(key, LP1);

        assertTrue(profitsAfterSecond0 >= profitsAfterFirst0);
        assertTrue(profitsAfterSecond1 >= profitsAfterFirst1);
    }
}
