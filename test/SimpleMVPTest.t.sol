// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
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
import {Token} from "../src/Token.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

/**
 * @title SimpleMVPTest
 * @notice Clean, realistic test with 50/50 pool that evolves naturally
 * @dev No complex price calculations - just deploy tokens and let the pool work
 */
contract SimpleMVPTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Test Infrastructure ============
    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;
    HookSwapRouter public hookSwapRouter;

    // ============ Tokens ============
    Token public fyntera; // FYN
    Token public quarita; // QRT
    Token public token0; // Lower address
    Token public token1; // Higher address

    // ============ Test Actors ============
    address public constant BASE_LP = address(0x1111);
    address public constant JIT_LP_1 = address(0x2222);
    address public constant JIT_LP_2 = address(0x3333);
    address public constant TRADER_1 = address(0x4444);
    address public constant TRADER_2 = address(0x5555);
    address public constant OWNER = address(0x9999);

    // ============ Constants ============
    uint8 public constant DECIMALS = 6;
    uint256 public constant ONE_TOKEN = 1_000_000; // 1 token (6 decimals)

    // Test amounts
    uint256 public constant AMOUNT_100 = 100 * ONE_TOKEN;
    uint256 public constant AMOUNT_500 = 500 * ONE_TOKEN;
    uint256 public constant AMOUNT_1000 = 1000 * ONE_TOKEN;
    uint256 public constant AMOUNT_5000 = 5000 * ONE_TOKEN;
    uint256 public constant AMOUNT_10000 = 10000 * ONE_TOKEN;
    uint256 public constant AMOUNT_50000 = 50000 * ONE_TOKEN;

    // ============ Events ============
    event PoolInitialized(address token0, address token1, uint160 startPrice);
    event LiquidityAdded(address indexed lp, string lpType, uint256 amount0, uint256 amount1, uint128 liquidity);
    event SwapExecuted(address indexed trader, uint256 amountIn, uint256 amountOut, bool zeroForOne);
    event PriceChanged(uint160 oldPrice, uint160 newPrice, int256 percentChange);

    // ============ Setup ============

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy two tokens - addresses are deterministic based on deploy order
        fyntera = new Token("Fyntera", "FYN");
        quarita = new Token("Quarita", "QRT");

        // Assign based on address ordering (lower address = token0)
        if (address(fyntera) < address(quarita)) {
            token0 = fyntera;
            token1 = quarita;
        } else {
            token0 = quarita;
            token1 = fyntera;
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        emit log_named_address("Token0 (lower address)", address(token0));
        emit log_named_address("Token1 (higher address)", address(token1));

        // Setup hook
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        positionManager = new LPPositionManager(address(manager), "LP NFT");
        configManager = new FHEConfigManager();
        feeCalculator = new FeeCalculator();

        vm.prank(hookAddress);
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

        // Initialize pool at 1:1 (50/50) - SQRT_PRICE_1_1
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        emit PoolInitialized(address(token0), address(token1), SQRT_PRICE_1_1);

        _setupTestAccounts();
    }

    function _setupTestAccounts() private {
        address[5] memory accounts = [BASE_LP, JIT_LP_1, JIT_LP_2, TRADER_1, TRADER_2];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);

            // Mint tokens to all participants
            token0.mint(accounts[i], 1_000_000 * ONE_TOKEN); // 1M tokens each
            token1.mint(accounts[i], 1_000_000 * ONE_TOKEN);

            vm.startPrank(accounts[i]);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            token0.approve(address(hookSwapRouter), type(uint256).max);
            token1.approve(address(hookSwapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ============ Helper Functions ============

    /**
     * @notice Calculate balanced liquidity amounts for a given tick range
     * @dev Uses the hook's built-in preview function with current pool state
     */
    function _getBalancedAmounts(int24 tickLower, int24 tickUpper, uint256 desiredAmount0, uint256 desiredAmount1)
        internal
        view
        returns (uint256 actualAmount0, uint256 actualAmount1, uint128 liquidity)
    {
        (liquidity, actualAmount0, actualAmount1) =
            hook.previewLiquidityForAmounts(key, tickLower, tickUpper, desiredAmount0, desiredAmount1);

        return (actualAmount0, actualAmount1, liquidity);
    }

    /**
     * @notice Get current pool price and tick
     */
    function _getCurrentPoolState() internal view returns (uint160 sqrtPrice, int24 tick) {
        return hook.getCurrentPrice(key);
    }

    /**
     * @notice Log pool state for visibility
     */
    function _logPoolState(string memory label) internal {
        (uint160 sqrtPrice, int24 tick) = _getCurrentPoolState();
        emit log_string(string.concat("=== ", label, " ==="));
        emit log_named_uint("SqrtPrice", uint256(sqrtPrice));
        emit log_named_int("Tick", tick);
        emit log_named_uint("Price Ratio", hook.getPriceRatio(key));
    }

    // ============ Test Scenarios ============

    /**
     * @notice Test 1: Add base passive liquidity (50/50 balanced)
     */
    function test_AddBaseLiquidity() public {
        vm.startPrank(BASE_LP);

        // Want to add 50k of each token (simple 50/50 split)
        uint256 desiredAmount0 = AMOUNT_50000;
        uint256 desiredAmount1 = AMOUNT_50000;

        // Get balanced amounts for full range based on current pool
        (uint256 amount0, uint256 amount1, uint128 liquidity) =
            _getBalancedAmounts(-887220, 887220, desiredAmount0, desiredAmount1);

        // Add liquidity
        (uint256 tokenId,, uint256 actual0, uint256 actual1) =
            hook.depositLiquidityWithAmounts(
                key,
                -887220, // Full range
                887220,
                amount0,
                amount1,
                false // Passive LP
            );

        vm.stopPrank();

        emit LiquidityAdded(BASE_LP, "Base Passive LP", actual0, actual1, liquidity);

        assertGt(tokenId, 0, "Token ID created");
        assertGt(liquidity, 0, "Liquidity calculated");
        _logPoolState("After Base Liquidity");
    }

    /**
     * @notice Test 2: Setup JIT LPs with different strategies
     */
    function test_SetupJITLPs() public {
        test_AddBaseLiquidity();

        // JIT LP 1: Conservative (triggers on 1000+ token swaps, 20% hedge)
        vm.startPrank(JIT_LP_1);

        InEuint128 memory enc1MinSwap = createInEuint128(1000e6, JIT_LP_1);
        InEuint32 memory enc1Hedge0 = createInEuint32(20, JIT_LP_1);
        InEuint32 memory enc1Hedge1 = createInEuint32(20, JIT_LP_1);

        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, true);

        // Add 10k balanced
        (uint256 amt0_1, uint256 amt1_1, uint128 liq1) = _getBalancedAmounts(-60, 60, AMOUNT_10000, AMOUNT_10000);

        hook.depositLiquidityWithAmounts(key, -60, 60, amt0_1, amt1_1, true);
        vm.stopPrank();

        emit LiquidityAdded(JIT_LP_1, "JIT LP 1 (Conservative)", amt0_1, amt1_1, liq1);

        // JIT LP 2: Aggressive (triggers on 500+ token swaps, 30% hedge)
        vm.startPrank(JIT_LP_2);

        InEuint128 memory enc2MinSwap = createInEuint128(500e6, JIT_LP_2);
        InEuint32 memory enc2Hedge0 = createInEuint32(30, JIT_LP_2);
        InEuint32 memory enc2Hedge1 = createInEuint32(30, JIT_LP_2);

        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, true);

        // Add 20k balanced
        (uint256 amt0_2, uint256 amt1_2, uint128 liq2) = _getBalancedAmounts(-60, 60, AMOUNT_10000, AMOUNT_10000);

        hook.depositLiquidityWithAmounts(key, -60, 60, amt0_2, amt1_2, true);
        vm.stopPrank();

        emit LiquidityAdded(JIT_LP_2, "JIT LP 2 (Aggressive)", amt0_2, amt1_2, liq2);

        // Decrypt for testing
        configManager.decryptMinSwapSize(key, JIT_LP_1);
        configManager.decryptMinSwapSize(key, JIT_LP_2);
        configManager.decryptHedgePercentage(key, JIT_LP_1);
        configManager.decryptHedgePercentage(key, JIT_LP_2);
        vm.warp(block.timestamp + 10);

        assertTrue(configManager.isActive(key, JIT_LP_1));
        assertTrue(configManager.isActive(key, JIT_LP_2));

        _logPoolState("After JIT LPs Setup");
    }

    /**
     * @notice Test 3: Small swap (no JIT trigger)
     */
    function test_SmallSwap() public {
        test_SetupJITLPs();

        (uint160 priceBefore,) = _getCurrentPoolState();

        uint256 swapAmount = AMOUNT_100; // 100 tokens
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, 300); // 3% slippage

        vm.prank(TRADER_1);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, address(token0), address(token1), swapAmount, minOut, block.timestamp + 10 minutes
        );

        (uint160 priceAfter,) = _getCurrentPoolState();

        emit SwapExecuted(TRADER_1, swapAmount, amountOut, true);
        emit PriceChanged(priceBefore, priceAfter, 0);

        assertGt(amountOut, 0, "Received output");
        _logPoolState("After Small Swap");

        // Should have no JIT profits (below threshold)
        (uint256 lp1p0, uint256 lp1p1) = profitManager.getLPProfits(key, JIT_LP_1);
        (uint256 lp2p0, uint256 lp2p1) = profitManager.getLPProfits(key, JIT_LP_2);

        assertEq(lp1p0 + lp1p1, 0, "JIT LP 1 no profit (threshold not met)");
        assertEq(lp2p0 + lp2p1, 0, "JIT LP 2 no profit (threshold not met)");
    }

    /**
     * @notice Test 4: Medium swap (triggers aggressive LP only)
     */
    function test_MediumSwap() public {
        test_SetupJITLPs();

        uint256 swapAmount = AMOUNT_500 + AMOUNT_100; // 600 tokens (above LP2's 500, below LP1's 1000)
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, 200);

        vm.prank(TRADER_1);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, address(token0), address(token1), swapAmount, minOut, block.timestamp + 10 minutes
        );

        emit SwapExecuted(TRADER_1, swapAmount, amountOut, true);

        (uint256 lp1p0, uint256 lp1p1) = profitManager.getLPProfits(key, JIT_LP_1);
        (uint256 lp2p0, uint256 lp2p1) = profitManager.getLPProfits(key, JIT_LP_2);

        emit log_named_uint("JIT LP 1 Profit", lp1p0 + lp1p1);
        emit log_named_uint("JIT LP 2 Profit", lp2p0 + lp2p1);

        assertEq(lp1p0 + lp1p1, 0, "LP1 threshold not met (1000)");
        assertTrue(lp2p0 > 0 || lp2p1 > 0, "LP2 earned (threshold 500)");

        _logPoolState("After Medium Swap");
    }

    /**
     * @notice Test 5: Large swap (triggers both LPs)
     */
    function test_LargeSwap() public {
        test_SetupJITLPs();

        uint256 swapAmount = AMOUNT_5000; // 5000 tokens
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, 1500);

        vm.prank(TRADER_2);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, address(token0), address(token1), swapAmount, minOut, block.timestamp + 10 minutes
        );

        emit SwapExecuted(TRADER_2, swapAmount, amountOut, true);

        (uint256 lp1p0, uint256 lp1p1) = profitManager.getLPProfits(key, JIT_LP_1);
        (uint256 lp2p0, uint256 lp2p1) = profitManager.getLPProfits(key, JIT_LP_2);

        emit log_named_uint("JIT LP 1 Total Profit", lp1p0 + lp1p1);
        emit log_named_uint("JIT LP 2 Total Profit", lp2p0 + lp2p1);

        assertTrue(lp1p0 + lp1p1 > 0, "LP1 earned");
        assertTrue(lp2p0 + lp2p1 > 0, "LP2 earned");

        _logPoolState("After Large Swap");
    }

    /**
     * @notice Test 6: Reverse swap (token1 → token0)
     */
    function test_ReverseSwap() public {
        test_SetupJITLPs();

        uint256 swapAmount = AMOUNT_1000; // 1000 token1
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, false, 500);

        vm.prank(TRADER_1);
        uint256 amountOut = hookSwapRouter.swapExactInputForOutput(
            key, address(token1), address(token0), swapAmount, minOut, block.timestamp + 10 minutes
        );

        emit SwapExecuted(TRADER_1, swapAmount, amountOut, false);

        assertGt(amountOut, 0, "Received token0");
        _logPoolState("After Reverse Swap");
    }

    /**
     * @notice Test 7: Multiple swaps show price evolution
     */
    function test_MultipleSwapsShowPriceEvolution() public {
        test_SetupJITLPs();

        uint256[5] memory swapSizes = [AMOUNT_100, AMOUNT_500, AMOUNT_1000, AMOUNT_500, AMOUNT_1000];

        (uint160 initialPrice,) = _getCurrentPoolState();

        for (uint256 i = 0; i < swapSizes.length; i++) {
            (uint160 priceBefore,) = _getCurrentPoolState();

            uint256 swapAmount = swapSizes[i];
            uint256 priceRatio = hook.getPriceRatio(key);
            uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, 250);

            address trader = i % 2 == 0 ? TRADER_1 : TRADER_2;

            vm.prank(trader);
            hookSwapRouter.swapExactInputForOutput(
                key, address(token0), address(token1), swapAmount, minOut, block.timestamp + 10 minutes
            );

            (uint160 priceAfter,) = _getCurrentPoolState();

            emit log_string(string.concat("Swap ", vm.toString(i + 1)));
            emit log_named_uint("Amount In", swapAmount / ONE_TOKEN);
            emit log_named_uint("Price Before", uint256(priceBefore));
            emit log_named_uint("Price After", uint256(priceAfter));

            vm.warp(block.timestamp + 1 hours);
        }

        (uint160 finalPrice,) = _getCurrentPoolState();

        emit log_string("=== Price Evolution Summary ===");
        emit log_named_uint("Initial Price", uint256(initialPrice));
        emit log_named_uint("Final Price", uint256(finalPrice));

        uint256 priceDifference;
        if (finalPrice > initialPrice) {
            priceDifference = uint256(finalPrice) - uint256(initialPrice);
        } else {
            priceDifference = uint256(initialPrice) - uint256(finalPrice);
        }
        emit log_named_uint("Price Change %", (priceDifference * 100) / uint256(initialPrice));

        (uint256 lp1Total0, uint256 lp1Total1) = profitManager.getLPProfits(key, JIT_LP_1);
        (uint256 lp2Total0, uint256 lp2Total1) = profitManager.getLPProfits(key, JIT_LP_2);

        emit log_named_uint("LP1 Total Profits", lp1Total0 + lp1Total1);
        emit log_named_uint("LP2 Total Profits", lp2Total0 + lp2Total1);

        assertTrue(lp1Total0 + lp1Total1 == 0, "LP1 accumulated NO profits (Tick out of range)");
        assertTrue(lp2Total0 + lp2Total1 > 0, "LP2 accumulated profits");
    }

    /**
     * @notice Test 8: Withdraw profits
     */
    function test_WithdrawProfits() public {
        test_LargeSwap();

        (uint256 profitBefore0, uint256 profitBefore1) = profitManager.getLPProfits(key, JIT_LP_1);

        vm.prank(JIT_LP_1);
        (uint256 withdrawn0, uint256 withdrawn1) = profitManager.withdrawProfits(key, JIT_LP_1);

        assertEq(withdrawn0, profitBefore0, "Withdrew all token0 profit");
        assertEq(withdrawn1, profitBefore1, "Withdrew all token1 profit");

        emit log_named_uint("Withdrawn Token0", withdrawn0 / ONE_TOKEN);
        emit log_named_uint("Withdrawn Token1", withdrawn1 / ONE_TOKEN);
    }

    /**
     * @notice Test 9: Remove liquidity
     */
    function test_RemoveLiquidity() public {
        test_SetupJITLPs();

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, JIT_LP_1);
        uint256 tokenId = positions[0].tokenId;
        uint128 liquidity = positions[0].liquidity;

        uint256 token0Before = token0.balanceOf(JIT_LP_1);
        uint256 token1Before = token1.balanceOf(JIT_LP_1);

        vm.prank(JIT_LP_1);
        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity);

        uint256 token0After = token0.balanceOf(JIT_LP_1);
        uint256 token1After = token1.balanceOf(JIT_LP_1);

        assertGt(amount0, 0, "Withdrew token0");
        assertGt(amount1, 0, "Withdrew token1");
        assertEq(token0After - token0Before, amount0, "Token0 balance updated");
        assertEq(token1After - token1Before, amount1, "Token1 balance updated");

        emit log_named_uint("Removed Token0", amount0 / ONE_TOKEN);
        emit log_named_uint("Removed Token1", amount1 / ONE_TOKEN);
    }
}
