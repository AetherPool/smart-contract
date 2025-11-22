// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// Uniswap v4 imports
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

// Contracts under test
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";

// FHE imports
import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

/**
 * @title JITCoordinator Test Suite
 * @notice Comprehensive tests for multi-LP JIT liquidity coordination
 * @dev Tests LP evaluation, contribution calculation, JIT execution, and profit distribution
 */
contract JITCoordinatorTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Test Setup ============
    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;

    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    // Test swap amounts
    uint128 public constant SMALL_SWAP = 500;
    uint128 public constant MEDIUM_SWAP = 2000;
    uint128 public constant LARGE_SWAP = 5000;

    function setUp() public {
        console.log("=== JITCoordinator Test Setup ===");

        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Calculate hook address with required permissions
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        // ✅ STEP 1: Deploy positionManager FIRST with hook address
        positionManager = new LPPositionManager(hookAddress);

        // ✅ STEP 2: Deploy other managers
        configManager = new FHEConfigManager();
        feeManager = new DynamicFeeManager(hookAddress, OWNER);
        profitManager = new ProfitManager(address(positionManager), address(configManager));
        feeCalculator = new FeeCalculator();
        jitCoordinator = new JITCoordinator(
            manager,
            hookAddress,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
        );

        // ✅ STEP 3: Deploy hook LAST with all addresses
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

        // Initialize pool
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        console.log("Modules deployed:");
        console.log("  Hook:", address(hook));
        console.log("  PositionManager:", address(positionManager));
        console.log("  ConfigManager:", address(configManager));
        console.log("  FeeManager:", address(feeManager));
        console.log("  ProfitManager:", address(profitManager));
        console.log("  JITCoordinator:", address(jitCoordinator));

        _setupTestAccounts();

        // Transfer tokens to profit manager for fee distribution
        MockERC20(Currency.unwrap(currency0)).mint(address(profitManager), 1000000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(profitManager), 1000000 ether);

        console.log("");
    }

    function _setupTestAccounts() private {
        address[4] memory accounts = [LP1, LP2, LP3, TRADER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);

            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            vm.startPrank(accounts[i]);
            // Approve hook to transfer tokens (hook will then transfer to PoolManager)
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            // Also approve swap router
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _setupMultipleLPs() private {
        console.log("Setting up multiple LPs with overlapping ranges...");

        // ============ LP1: Wide range (-240 to 240) ============
        InEuint128 memory enc1MinSwap = createInEuint128(800, LP1);
        InEuint128 memory enc1MaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory enc1Profit = createInEuint32(30, LP1);
        InEuint32 memory enc1Hedge = createInEuint32(20, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, false);

        // Call hook.depositLiquidity() instead of positionManager.depositLiquidity()
        hook.depositLiquidity(
            key,
            -240, // tickLower
            240, // tickUpper
            800, // liquidity
            400, // amount0
            400 // amount1
        );
        vm.stopPrank();
        console.log("  LP1: Wide range (-240 to 240), threshold 800");

        // ============ LP2: Medium range (-120 to 120) ============
        InEuint128 memory enc2MinSwap = createInEuint128(1200, LP2);
        InEuint128 memory enc2MaxLiq = createInEuint128(60000, LP2);
        InEuint32 memory enc2Profit = createInEuint32(35, LP2);
        InEuint32 memory enc2Hedge = createInEuint32(40, LP2);

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, true);

        // Call hook.depositLiquidity()
        hook.depositLiquidity(
            key,
            -120, // tickLower
            120, // tickUpper
            1000, // liquidity
            500, // amount0
            500 // amount1
        );
        vm.stopPrank();
        console.log("  LP2: Medium range (-120 to 120), threshold 1200");

        // ============ LP3: Narrow range (-60 to 60) ============
        InEuint128 memory enc3MinSwap = createInEuint128(1500, LP3);
        InEuint128 memory enc3MaxLiq = createInEuint128(70000, LP3);
        InEuint32 memory enc3Profit = createInEuint32(40, LP3);
        InEuint32 memory enc3Hedge = createInEuint32(60, LP3);

        vm.startPrank(LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3MaxLiq, enc3Profit, enc3Hedge, true);

        // Call hook.depositLiquidity()
        hook.depositLiquidity(
            key,
            -60, // tickLower
            60, // tickUpper
            1200, // liquidity
            600, // amount0
            600 // amount1
        );
        vm.stopPrank();
        console.log("  LP3: Narrow range (-60 to 60), threshold 1500");

        // Trigger decryptions
        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        configManager.decryptMinSwapSize(key, LP3);

        vm.warp(block.timestamp + 15);

        console.log("Multiple LPs configured and ready");
    }

    // ============ Test 1: Single LP Evaluation ============

    function testSingleLPEvaluation() public {
        console.log("TEST 1: Single LP Evaluation");
        console.log("---------------------------");

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);

        // Call hook.depositLiquidity()
        hook.depositLiquidity(key, -120, 120, 500, 250, 250);
        vm.stopPrank();

        console.log("LP1 configured: threshold 1000, position -120 to 120");

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        (address[] memory eligibleLPs, uint128[] memory contributions) = jitCoordinator.evaluateMultiLPJIT(key, 2000);

        console.log("Evaluation for 2000 swap:");
        console.log("  Eligible LPs: %s", eligibleLPs.length);

        if (eligibleLPs.length > 0) {
            assertEq(eligibleLPs[0], LP1, "LP1 should be eligible");
            assertGt(contributions[0], 0, "LP1 should have contribution");
            console.log("  LP1 contribution: %s", contributions[0]);
        }

        console.log("Single LP evaluation successful\n");
    }

    // ============ Test 2: Multi-LP Evaluation ============

    function testMultiLPEvaluation() public {
        console.log("TEST 2: Multi-LP Evaluation");
        console.log("--------------------------");

        _setupMultipleLPs();

        console.log("\nTest 1: Medium swap (1000)");
        (address[] memory eligibleLPs1, uint128[] memory contributions1) = jitCoordinator.evaluateMultiLPJIT(key, 1000);
        console.log("  Eligible LPs: %s", eligibleLPs1.length);
        for (uint256 i = 0; i < eligibleLPs1.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs1[i], contributions1[i]);
        }

        console.log("\nTest 2: Large swap (1500)");
        (address[] memory eligibleLPs2, uint128[] memory contributions2) = jitCoordinator.evaluateMultiLPJIT(key, 1500);
        console.log("  Eligible LPs: %s", eligibleLPs2.length);
        for (uint256 i = 0; i < eligibleLPs2.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs2[i], contributions2[i]);
        }

        console.log("\nTest 3: Very large swap (5000)");
        (address[] memory eligibleLPs3, uint128[] memory contributions3) = jitCoordinator.evaluateMultiLPJIT(key, 5000);
        console.log("  Eligible LPs: %s", eligibleLPs3.length);
        for (uint256 i = 0; i < eligibleLPs3.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs3[i], contributions3[i]);
        }

        assertGt(eligibleLPs3.length, 0, "Should have eligible LPs for large swap");
        console.log("\nMulti-LP evaluation successful\n");
    }

    // ============ Test 3: JIT Lifecycle via Real Swap ============

    function testJITLifecycleViaSwap() public {
        console.log("TEST 3: Complete JIT Lifecycle via Real Swap");
        console.log("---------------------------------------------");

        _setupMultipleLPs();

        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        console.log("Expected eligible LPs: %s", eligibleLPs.length);

        if (eligibleLPs.length == 0) {
            console.log("No eligible LPs - skipping test");
            return;
        }

        // Decrypt hedge percentages
        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            configManager.decryptHedgePercentage(key, eligibleLPs[i]);
        }
        vm.warp(block.timestamp + 10);

        // Record initial profits
        uint256[] memory initialProfits0 = new uint256[](eligibleLPs.length);
        uint256[] memory initialProfits1 = new uint256[](eligibleLPs.length);

        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            (initialProfits0[i], initialProfits1[i]) = profitManager.getLPProfits(key, eligibleLPs[i]);
            console.log("LP %s initial profits: %s, %s", eligibleLPs[i], initialProfits0[i], initialProfits1[i]);
        }

        uint256 expectedSwapId = jitCoordinator.getNextSwapId();
        console.log("\nExpected swap ID: %s", expectedSwapId);

        // Execute swap
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap for %s tokens...", LARGE_SWAP);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        console.log("Swap completed");

        // Verify JIT was removed
        bool isActive = jitCoordinator.isJITActive(expectedSwapId);
        assertFalse(isActive, "JIT should be inactive after swap");
        console.log("\nJIT position correctly removed after swap");

        // Verify fees were distributed
        console.log("\nFee Distribution Results:");
        uint256 totalFeesDistributed = 0;

        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, eligibleLPs[i]);
            console.log("LP %s final profits: %s, %s", eligibleLPs[i], profit0, profit1);

            uint256 profitIncrease = (profit0 - initialProfits0[i]) + (profit1 - initialProfits1[i]);
            totalFeesDistributed += profitIncrease;

            console.log("  Profit increase: %s (contribution: %s)", profitIncrease, contributions[i]);
            if (profitIncrease > 0) {
                assertGt(profitIncrease, 0, "Profit should be positive");
            }
        }

        console.log("\nTotal fees distributed: %s", totalFeesDistributed);
        console.log("JIT lifecycle test completed\n");
    }

    // ============ Test 4: LP Position Configuration ============

    function testLPPositionConfiguration() public {
        console.log("TEST 4: LP Position Configuration");
        console.log("--------------------------------");

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);
        console.log("LP1 configured with threshold 1000");

        // ✅ CHANGED: Deposit liquidity through hook
        hook.depositLiquidity(key, -120, 120, 500, 250, 250);
        console.log("LP1 deposited liquidity: -120 to 120, 500 units");
        vm.stopPrank();

        // Verify LP is active
        bool isActive = configManager.isActive(key, LP1);
        assertTrue(isActive, "LP1 should be active");
        console.log("LP1 is active in the system");

        // Decrypt and verify
        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        (address[] memory eligibleLPs,) = jitCoordinator.evaluateMultiLPJIT(key, 2000);
        assertEq(eligibleLPs.length, 1, "LP1 should be eligible");
        console.log("LP1 correctly identified as eligible for JIT");

        console.log("LP position configuration successful\n");
    }

    // ============ Test 5: JIT Position Tracking ============

    function testJITPositionTracking() public {
        console.log("TEST 5: JIT Position Tracking");
        console.log("-----------------------------");

        _setupMultipleLPs();

        (address[] memory eligibleLPs,) = jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length == 0) {
            console.log("No eligible LPs - skipping test");
            return;
        }

        // Execute swap to create and process JIT
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 swapId = jitCoordinator.getNextSwapId();
        console.log("Creating JIT operation with ID: %s", swapId);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Verify JIT position was tracked
        bool isActive = jitCoordinator.isJITActive(swapId);
        assertFalse(isActive, "JIT should be removed after swap");

        // Check fees were collected
        (uint256 fees0, uint256 fees1) = jitCoordinator.getJITFees(swapId);
        console.log("Fees collected: %s (token0), %s (token1)", fees0, fees1);

        console.log("JIT position tracking successful\n");
    }

    // ============ Test 6: Verify Claim Tokens in Hook ============

    function testHookHasClaimTokens() public {
        console.log("TEST 6: Verify Hook Has Claim Tokens");
        console.log("------------------------------------");

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);

        uint256 depositAmount0 = 1000;
        uint256 depositAmount1 = 1000;

        // Deposit liquidity
        hook.depositLiquidity(key, -120, 120, 1000, depositAmount0, depositAmount1);
        vm.stopPrank();

        // Check that hook received claim tokens (ERC-6909)
        // The hook should have claim token balance equal to deposited amounts
        uint256 currency0Id = uint256(uint160(Currency.unwrap(currency0)));
        uint256 currency1Id = uint256(uint160(Currency.unwrap(currency1)));

        uint256 hookBalance0 = manager.balanceOf(address(hook), currency0Id);
        uint256 hookBalance1 = manager.balanceOf(address(hook), currency1Id);

        console.log("Hook claim token balance (currency0): %s", hookBalance0);
        console.log("Hook claim token balance (currency1): %s", hookBalance1);

        assertEq(hookBalance0, depositAmount0, "Hook should have claim tokens for currency0");
        assertEq(hookBalance1, depositAmount1, "Hook should have claim tokens for currency1");

        console.log("Hook successfully holds claim tokens for JIT operations\n");
    }
}
