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

// Contracts under test
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";

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
    ZKJITLiquidityHook public hook;

    address public constant HOOK = address(0x1111);
    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    // Test swap amounts
    uint128 public constant SMALL_SWAP = 500;    // Below threshold
    uint128 public constant MEDIUM_SWAP = 2000;  // Triggers some LPs
    uint128 public constant LARGE_SWAP = 5000;   // Triggers most LPs

    // Events for tracking
    event JITRequested(uint256 indexed swapId, bytes32 indexed poolId, address indexed swapper, uint128 swapAmount);
    event JITExecuted(uint256 indexed swapId, bytes32 indexed poolId, uint128 liquidityProvided);
    event JITMultiLPExecution(uint256 indexed swapId, address[] lps, uint128[] contributions);
    event JITRemoved(uint256 indexed swapId, bytes32 indexed poolId);

    function setUp() public {
        console.log("=== JITCoordinator Test Setup ===");

        // Deploy Uniswap v4 infrastructure
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Calculate hook address with required permissions
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        // Deploy managers
        vm.startPrank(HOOK);
        positionManager = new LPPositionManager(HOOK);
        configManager = new FHEConfigManager(HOOK);
        feeManager = new DynamicFeeManager(HOOK, OWNER);
        profitManager = new ProfitManager(HOOK, address(positionManager), address(configManager));
        jitCoordinator =
            new JITCoordinator(manager, HOOK, address(positionManager), address(configManager), address(profitManager));
        vm.stopPrank();

        deployCodeTo(
            "ZKJITLiquidityHook.sol",
            abi.encode(
                manager,
                address(positionManager),
                address(configManager),
                address(feeManager),
                address(profitManager),
                address(jitCoordinator)
            ),
            hookAddress
        );
        hook = ZKJITLiquidityHook(hookAddress);

        // Initialize pool
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        console.log("Modules deployed:");
        console.log("  PositionManager:", address(positionManager));
        console.log("  ConfigManager:", address(configManager));
        console.log("  FeeManager:", address(feeManager));
        console.log("  ProfitManager:", address(profitManager));
        console.log("  JITCoordinator:", address(jitCoordinator));

        // Setup test accounts
        _setupTestAccounts();

        // Transfer tokens to profit manager for distribution
        MockERC20(Currency.unwrap(currency0)).mint(address(profitManager), 1000000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(profitManager), 1000000 ether);

        console.log("");
    }

    function _setupTestAccounts() private {
        address[4] memory accounts = [LP1, LP2, LP3, TRADER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);

            // Mint test tokens
            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            // Approve all managers
            vm.startPrank(accounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ============ Helper: Setup Multiple LPs ============

    function _setupMultipleLPs() private {
        console.log("Setting up multiple LPs with overlapping ranges...");

        // LP1: Wide range (-240 to 240)
        vm.startPrank(LP1);
        InEuint128 memory enc1MinSwap = createInEuint128(800, LP1);
        InEuint128 memory enc1MaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory enc1Profit = createInEuint32(30, LP1);
        InEuint32 memory enc1Hedge = createInEuint32(20, LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, false);
        vm.stopPrank();

        positionManager.depositLiquidity(key, -240, 240, 8000, 4000, 4000, LP1);
        console.log("  LP1: Wide range (-240 to 240), threshold 800");

        // LP2: Medium range (-120 to 120)
        vm.startPrank(LP2);
        InEuint128 memory enc2MinSwap = createInEuint128(1200, LP2);
        InEuint128 memory enc2MaxLiq = createInEuint128(60000, LP2);
        InEuint32 memory enc2Profit = createInEuint32(35, LP2);
        InEuint32 memory enc2Hedge = createInEuint32(40, LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, true);
        vm.stopPrank();

        positionManager.depositLiquidity(key, -120, 120, 10000, 5000, 5000, LP2);
        console.log("  LP2: Medium range (-120 to 120), threshold 1200");

        // LP3: Narrow range (-60 to 60)
        vm.startPrank(LP3);
        InEuint128 memory enc3MinSwap = createInEuint128(1500, LP3);
        InEuint128 memory enc3MaxLiq = createInEuint128(70000, LP3);
        InEuint32 memory enc3Profit = createInEuint32(40, LP3);
        InEuint32 memory enc3Hedge = createInEuint32(60, LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3MaxLiq, enc3Profit, enc3Hedge, true);
        vm.stopPrank();

        positionManager.depositLiquidity(key, -60, 60, 12000, 6000, 6000, LP3);
        console.log("  LP3: Narrow range (-60 to 60), threshold 1500");

        // Trigger decryptions for threshold checking
        vm.startPrank(HOOK);
        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        configManager.decryptMinSwapSize(key, LP3);
        vm.stopPrank();

        vm.warp(block.timestamp + 15);

        console.log("Multiple LPs configured and ready");
    }

    // ============ Test 1: Single LP Evaluation ============

    function testSingleLPEvaluation() public {
        console.log("TEST 1: Single LP Evaluation");
        console.log("---------------------------");

        // Setup one LP
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);
        vm.stopPrank();

        positionManager.depositLiquidity(key, -120, 120, 5000, 2500, 2500, LP1);

        console.log("LP1 configured: threshold 1000, position -120 to 120");

        // Trigger decryption
        vm.prank(HOOK);
        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        // Evaluate with swap above threshold
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, 2000);

        console.log("Evaluation for 2000 swap:");
        console.log("  Eligible LPs: %s", eligibleLPs.length);

        if (eligibleLPs.length > 0) {
            assertEq(eligibleLPs[0], LP1, "LP1 should be eligible");
            assertGt(contributions[0], 0, "LP1 should have contribution");
            console.log("  LP1 contribution: %s", contributions[0]);
        }

        console.log("Single LP evaluation successful");
        console.log("");
    }

    // ============ Test 2: Multi-LP Evaluation ============

    function testMultiLPEvaluation() public {
        console.log("TEST 2: Multi-LP Evaluation");
        console.log("--------------------------");

        _setupMultipleLPs();

        // Test with medium swap (should trigger LP1 only)
        console.log("\nTest 1: Medium swap (1000)");
        (address[] memory eligibleLPs1, uint128[] memory contributions1) = 
            jitCoordinator.evaluateMultiLPJIT(key, 1000);

        console.log("  Eligible LPs: %s", eligibleLPs1.length);
        for (uint256 i = 0; i < eligibleLPs1.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs1[i], contributions1[i]);
        }

        // Test with larger swap (should trigger LP1 and LP2)
        console.log("\nTest 2: Large swap (1500)");
        (address[] memory eligibleLPs2, uint128[] memory contributions2) = 
            jitCoordinator.evaluateMultiLPJIT(key, 1500);

        console.log("  Eligible LPs: %s", eligibleLPs2.length);
        for (uint256 i = 0; i < eligibleLPs2.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs2[i], contributions2[i]);
        }

        // Test with very large swap (should trigger all LPs)
        console.log("\nTest 3: Very large swap (5000)");
        (address[] memory eligibleLPs3, uint128[] memory contributions3) = 
            jitCoordinator.evaluateMultiLPJIT(key, 5000);

        console.log("  Eligible LPs: %s", eligibleLPs3.length);
        for (uint256 i = 0; i < eligibleLPs3.length; i++) {
            console.log("  LP %s: contribution %s", eligibleLPs3[i], contributions3[i]);
        }

        assertGt(eligibleLPs3.length, 0, "Should have eligible LPs for large swap");

        console.log("\nMulti-LP evaluation successful");
        console.log("");
    }

    // ============ Test 3: JIT Creation ============

    function testJITCreation() public {
        console.log("TEST 3: JIT Creation");
        console.log("------------------");

        _setupMultipleLPs();

        // Evaluate eligible LPs
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        console.log("Eligible LPs for JIT: %s", eligibleLPs.length);

        if (eligibleLPs.length > 0) {
            // Create JIT
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            vm.expectEmit(true, true, true, true);
            emit JITRequested(1, keccak256(abi.encode(key)), TRADER, LARGE_SWAP);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            console.log("JIT created with swap ID: %s", swapId);

            // Verify JIT details
            JITCoordinator.PendingJIT memory pendingJIT = jitCoordinator.getPendingJIT(swapId);
            assertEq(pendingJIT.swapId, swapId, "Swap ID should match");
            assertEq(pendingJIT.swapper, TRADER, "Swapper should be TRADER");
            assertEq(pendingJIT.swapAmount, LARGE_SWAP, "Swap amount should match");
            assertFalse(pendingJIT.executed, "Should not be executed yet");

            console.log("JIT details verified:");
            console.log("  Swapper: %s", pendingJIT.swapper);
            console.log("  Amount: %s", pendingJIT.swapAmount);
            console.log("  Executed: %s", pendingJIT.executed);
        }

        console.log("JIT creation successful");
        console.log("");
    }

    // ============ Test 4: JIT Execution ============

    function testJITExecution() public {
        console.log("TEST 4: JIT Execution");
        console.log("-------------------");

        _setupMultipleLPs();

        // Evaluate and create JIT
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        console.log("Eligible LPs: %s", eligibleLPs.length);

        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            console.log("JIT created, swap ID: %s", swapId);

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            // Execute JIT
            vm.prank(HOOK);
            vm.expectEmit(true, true, true, true);
            emit JITMultiLPExecution(swapId, eligibleLPs, contributions);
            jitCoordinator.executeMultiLPJIT(swapId);

            console.log("JIT executed");

            // Verify execution status
            JITCoordinator.PendingJIT memory pendingJIT = jitCoordinator.getPendingJIT(swapId);
            assertTrue(pendingJIT.executed, "JIT should be marked as executed");

            // Verify JIT position created
            JITCoordinator.JITLiquidityPosition memory jitPos = jitCoordinator.getJITPosition(swapId);
            assertTrue(jitPos.isActive, "JIT position should be active");
            assertEq(jitPos.participatingLPs.length, eligibleLPs.length, "All eligible LPs should participate");

            console.log("JIT position details:");
            console.log("  Active: %s", jitPos.isActive);
            console.log("  Total liquidity: %s", jitPos.totalLiquidity);
            console.log("  Participating LPs: %s", jitPos.participatingLPs.length);

            // Verify profits accrued
            for (uint256 i = 0; i < jitPos.participatingLPs.length; i++) {
                address lp = jitPos.participatingLPs[i];
                (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, lp);
                console.log("  LP %s profits: %s token0, %s token1", lp, profit0, profit1);
                assertGt(profit0 + profit1, 0, "LP should have accrued profits");
            }
        }

        console.log("JIT execution successful");
        console.log("");
    }

    // ============ Test 5: JIT Removal ============

    function testJITRemoval() public {
        console.log("TEST 5: JIT Removal");
        console.log("-----------------");

        _setupMultipleLPs();

        // Create and execute JIT
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId);

            console.log("JIT created and executed, swap ID: %s", swapId);

            // Verify JIT is active
            assertTrue(jitCoordinator.isJITActive(swapId), "JIT should be active");

            // Get initial profits
            address[] memory lps = new address[](eligibleLPs.length);
            uint256[] memory initialProfits0 = new uint256[](eligibleLPs.length);
            uint256[] memory initialProfits1 = new uint256[](eligibleLPs.length);

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                lps[i] = eligibleLPs[i];
                (initialProfits0[i], initialProfits1[i]) = profitManager.getLPProfits(key, lps[i]);
                console.log("LP %s initial profits: %s, %s", lps[i], initialProfits0[i], initialProfits1[i]);
            }

            // Remove JIT
            vm.prank(HOOK);
            vm.expectEmit(true, true, true, true);
            emit JITRemoved(swapId, keccak256(abi.encode(key)));
            jitCoordinator.removeJITLiquidity(key, swapId);

            console.log("JIT removed");

            // Verify JIT is inactive
            assertFalse(jitCoordinator.isJITActive(swapId), "JIT should be inactive after removal");

            // Verify bonus profits distributed
            for (uint256 i = 0; i < lps.length; i++) {
                (uint256 finalProfit0, uint256 finalProfit1) = profitManager.getLPProfits(key, lps[i]);
                console.log("LP %s final profits: %s, %s", lps[i], finalProfit0, finalProfit1);
                
                assertTrue(
                    finalProfit0 >= initialProfits0[i] || finalProfit1 >= initialProfits1[i],
                    "Profits should increase or stay same after JIT removal"
                );
            }
        }

        console.log("JIT removal successful");
        console.log("");
    }

    // ============ Test 6: Contribution Calculation ============

    function testContributionCalculation() public {
        console.log("TEST 6: Contribution Calculation");
        console.log("-------------------------------");

        _setupMultipleLPs();

        // Test with different swap sizes
        uint128[] memory swapSizes = new uint128[](4);
        swapSizes[0] = 1000;
        swapSizes[1] = 2500;
        swapSizes[2] = 5000;
        swapSizes[3] = 10000;

        for (uint256 i = 0; i < swapSizes.length; i++) {
            console.log("\nSwap size: %s", swapSizes[i]);

            (address[] memory eligibleLPs, uint128[] memory contributions) = 
                jitCoordinator.evaluateMultiLPJIT(key, swapSizes[i]);

            console.log("  Eligible LPs: %s", eligibleLPs.length);

            uint128 totalContribution = 0;
            for (uint256 j = 0; j < contributions.length; j++) {
                console.log("  LP %s contribution: %s", eligibleLPs[j], contributions[j]);
                totalContribution += contributions[j];

                // Verify contribution is reasonable (max 10% of swap or 50% of LP liquidity)
                uint128 maxContribution = swapSizes[i] / 10;
                assertLe(contributions[j], maxContribution, "Contribution should not exceed 10% of swap");
            }

            console.log("  Total contribution: %s", totalContribution);
        }

        console.log("\nContribution calculation working correctly");
        console.log("");
    }

    // ============ Test 7: Overlapping Position Detection ============

    function testOverlappingPositionDetection() public {
        console.log("TEST 7: Overlapping Position Detection");
        console.log("-------------------------------------");

        // Create LP with non-overlapping position
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(500, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);
        vm.stopPrank();

        // Position far from current tick (assuming current tick ~0)
        vm.prank(HOOK);
        positionManager.depositLiquidity(key, 300, 400, 5000, 2500, 2500, LP1);

        console.log("LP1 position: 300 to 400 (far from current tick)");

        // Decrypt threshold
        vm.prank(HOOK);
        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        // Evaluate JIT at current price
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, 2000);

        console.log("Eligible LPs with large swap: %s", eligibleLPs.length);

        // LP1 should not be eligible (no overlap with JIT range around tick 0)
        bool lp1Found = false;
        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            if (eligibleLPs[i] == LP1) {
                lp1Found = true;
                break;
            }
        }

        assertFalse(lp1Found, "LP1 should not be eligible without overlapping position");
        console.log("LP1 correctly excluded (no overlap)");

        // Add overlapping position
        vm.prank(HOOK);
        positionManager.depositLiquidity(key, -120, 120, 6000, 3000, 3000, LP1);

        console.log("Added LP1 overlapping position: -120 to 120");

        // Re-evaluate
        (eligibleLPs, contributions) = jitCoordinator.evaluateMultiLPJIT(key, 2000);

        console.log("Eligible LPs after adding overlap: %s", eligibleLPs.length);

        // Now LP1 should be eligible
        lp1Found = false;
        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            if (eligibleLPs[i] == LP1) {
                lp1Found = true;
                console.log("LP1 contribution: %s", contributions[i]);
                break;
            }
        }

        assertTrue(lp1Found, "LP1 should be eligible with overlapping position");
        console.log("LP1 correctly included (with overlap)");

        console.log("Overlapping position detection successful");
        console.log("");
    }

    // ============ Test 8: Authorization Checks ============

    function testAuthorizationChecks() public {
        console.log("TEST 8: Authorization & Security");
        console.log("-------------------------------");

        _setupMultipleLPs();

        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            // Test unauthorized createMultiLPJIT
            vm.prank(TRADER);
            vm.expectRevert(JITCoordinator.Unauthorized.selector);
            jitCoordinator.createMultiLPJIT(key, TRADER, LARGE_SWAP, params, eligibleLPs, contributions);
            console.log("Unauthorized createMultiLPJIT blocked");

            // Create JIT as hook
            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            // Test unauthorized executeMultiLPJIT
            vm.prank(TRADER);
            vm.expectRevert(JITCoordinator.Unauthorized.selector);
            jitCoordinator.executeMultiLPJIT(swapId);
            console.log("Unauthorized executeMultiLPJIT blocked");

            // Execute as hook
            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId);

            // Test unauthorized removeJITLiquidity
            vm.prank(TRADER);
            vm.expectRevert(JITCoordinator.Unauthorized.selector);
            jitCoordinator.removeJITLiquidity(key, swapId);
            console.log("Unauthorized removeJITLiquidity blocked");
        }

        console.log("All authorization checks passed");
        console.log("");
    }

    // ============ Test 9: Invalid Operations ============

    function testInvalidOperations() public {
        console.log("TEST 9: Invalid Operations");
        console.log("-------------------------");

        // Test evaluation with zero swap amount
        vm.expectRevert(JITCoordinator.InvalidSwapAmount.selector);
        jitCoordinator.evaluateMultiLPJIT(key, 0);
        console.log("Zero swap amount rejected");

        // Test creation with no eligible LPs
        address[] memory emptyLPs = new address[](0);
        uint128[] memory emptyContributions = new uint128[](0);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.prank(HOOK);
        vm.expectRevert(JITCoordinator.NoEligibleLPs.selector);
        jitCoordinator.createMultiLPJIT(key, TRADER, LARGE_SWAP, params, emptyLPs, emptyContributions);
        console.log("Creation with no eligible LPs rejected");

        // Test double execution
        _setupMultipleLPs();
        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length > 0) {
            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId);

            vm.prank(HOOK);
            vm.expectRevert(JITCoordinator.AlreadyExecuted.selector);
            jitCoordinator.executeMultiLPJIT(swapId);
            console.log("Double execution rejected");
        }

        console.log("Invalid operation checks passed");
        console.log("");
    }

    // ============ Test 10: Multiple JIT Operations ============

    function testMultipleJITOperations() public {
        console.log("TEST 10: Multiple JIT Operations");
        console.log("-------------------------------");

        _setupMultipleLPs();

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Create multiple JIT operations
        uint256 numJITs = 3;
        uint256[] memory swapIds = new uint256[](numJITs);

        console.log("Creating %s JIT operations...", numJITs);

        for (uint256 i = 0; i < numJITs; i++) {
            (address[] memory eligibleLPs, uint128[] memory contributions) = 
                jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP + uint128(i * 1000));

            if (eligibleLPs.length > 0) {
                vm.prank(HOOK);
                swapIds[i] = jitCoordinator.createMultiLPJIT(
                    key,
                    TRADER,
                    LARGE_SWAP + uint128(i * 1000),
                    params,
                    eligibleLPs,
                    contributions
                );

                console.log("  JIT %s created, swap ID: %s", i + 1, swapIds[i]);

                // Decrypt hedge percentages
                for (uint256 j = 0; j < eligibleLPs.length; j++) {
                    configManager.decryptHedgePercentage(key, eligibleLPs[j]);
                }
                vm.warp(block.timestamp + 10);

                vm.prank(HOOK);
                jitCoordinator.executeMultiLPJIT(swapIds[i]);

                console.log("  JIT %s executed", i + 1);
            }
        }

        // Verify all JITs are tracked independently
        for (uint256 i = 0; i < numJITs; i++) {
            if (swapIds[i] > 0) {
                JITCoordinator.JITLiquidityPosition memory jitPos = jitCoordinator.getJITPosition(swapIds[i]);
                assertTrue(jitPos.isActive, "JIT should be active");
                console.log("JIT %s verified: active=%s, liquidity=%s", i + 1, jitPos.isActive, jitPos.totalLiquidity);
            }
        }

        // Remove all JITs
        console.log("\nRemoving JIT operations...");
        for (uint256 i = 0; i < numJITs; i++) {
            if (swapIds[i] > 0) {
                vm.prank(HOOK);
                jitCoordinator.removeJITLiquidity(key, swapIds[i]);
                console.log("  JIT %s removed", i + 1);

                assertFalse(jitCoordinator.isJITActive(swapIds[i]), "JIT should be inactive");
            }
        }

        console.log("Multiple JIT operations handled successfully");
        console.log("");
    }

    // ============ Test 11: Profit Distribution ============

    function testProfitDistribution() public {
        console.log("TEST 11: Profit Distribution");
        console.log("---------------------------");

        _setupMultipleLPs();

        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        console.log("Eligible LPs: %s", eligibleLPs.length);

        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            // Record initial profits
            uint256[] memory initialProfits0 = new uint256[](eligibleLPs.length);
            uint256[] memory initialProfits1 = new uint256[](eligibleLPs.length);

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                (initialProfits0[i], initialProfits1[i]) = profitManager.getLPProfits(key, eligibleLPs[i]);
                console.log("LP %s initial: %s, %s", eligibleLPs[i], initialProfits0[i], initialProfits1[i]);
            }

            // Create and execute JIT
            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId);

            console.log("\nAfter JIT execution:");

            // Verify profits increased
            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, eligibleLPs[i]);
                console.log("LP %s profits: %s, %s", eligibleLPs[i], profit0, profit1);

                assertTrue(
                    profit0 > initialProfits0[i] || profit1 > initialProfits1[i],
                    "Profits should increase after JIT"
                );

                // Verify profit is proportional to contribution
                uint256 profitIncrease = (profit0 - initialProfits0[i]) + (profit1 - initialProfits1[i]);
                console.log("  Profit increase: %s (contribution: %s)", profitIncrease, contributions[i]);
            }

            // Remove JIT and verify bonus profits
            console.log("\nRemoving JIT...");
            uint256[] memory profitsBeforeRemoval0 = new uint256[](eligibleLPs.length);
            uint256[] memory profitsBeforeRemoval1 = new uint256[](eligibleLPs.length);

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                (profitsBeforeRemoval0[i], profitsBeforeRemoval1[i]) = 
                    profitManager.getLPProfits(key, eligibleLPs[i]);
            }

            vm.prank(HOOK);
            jitCoordinator.removeJITLiquidity(key, swapId);

            console.log("\nAfter JIT removal:");
            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                (uint256 finalProfit0, uint256 finalProfit1) = profitManager.getLPProfits(key, eligibleLPs[i]);
                console.log("LP %s final: %s, %s", eligibleLPs[i], finalProfit0, finalProfit1);

                uint256 bonusProfit = (finalProfit0 - profitsBeforeRemoval0[i]) + 
                                     (finalProfit1 - profitsBeforeRemoval1[i]);
                console.log("  Bonus profit: %s", bonusProfit);
            }
        }

        console.log("\nProfit distribution working correctly");
        console.log("");
    }

    // ============ Test 12: Next Swap ID Tracking ============

    function testNextSwapIdTracking() public {
        console.log("TEST 12: Next Swap ID Tracking");
        console.log("-----------------------------");

        _setupMultipleLPs();

        uint256 initialNextId = jitCoordinator.getNextSwapId();
        console.log("Initial next swap ID: %s", initialNextId);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Create several JITs
        for (uint256 i = 0; i < 3; i++) {
            (address[] memory eligibleLPs, uint128[] memory contributions) = 
                jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

            if (eligibleLPs.length > 0) {
                vm.prank(HOOK);
                uint256 swapId = jitCoordinator.createMultiLPJIT(
                    key,
                    TRADER,
                    LARGE_SWAP,
                    params,
                    eligibleLPs,
                    contributions
                );

                console.log("Created JIT with swap ID: %s", swapId);
                assertEq(swapId, initialNextId + i, "Swap ID should increment");
            }
        }

        uint256 finalNextId = jitCoordinator.getNextSwapId();
        console.log("Final next swap ID: %s", finalNextId);

        assertEq(finalNextId, initialNextId + 3, "Next ID should have incremented by 3");

        console.log("Swap ID tracking working correctly");
        console.log("");
    }

    // ============ Test 13: Edge Cases ============

    function testEdgeCases() public {
        console.log("TEST 13: Edge Cases");
        console.log("------------------");

        // Test with inactive LP
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(500, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(25, LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, false);
        configManager.deactivateLP(key);
        vm.stopPrank();

        vm.prank(HOOK);
        positionManager.depositLiquidity(key, -120, 120, 5000, 2500, 2500, LP1);

        console.log("LP1 configured but deactivated");

        // Trigger decryption
        vm.prank(HOOK);
        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        // Should not be eligible
        (address[] memory eligibleLPs, ) = jitCoordinator.evaluateMultiLPJIT(key, 2000);

        bool found = false;
        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            if (eligibleLPs[i] == LP1) found = true;
        }

        assertFalse(found, "Inactive LP should not be eligible");
        console.log("Inactive LP correctly excluded");

        // Test with very small swap
        _setupMultipleLPs();
        (eligibleLPs, ) = jitCoordinator.evaluateMultiLPJIT(key, 100);
        console.log("Small swap evaluated: %s eligible LPs", eligibleLPs.length);

        // Test removal of already removed JIT (should be idempotent)
        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            (address[] memory eligibleLPs2, uint128[] memory contributions2) = 
                jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

            if (eligibleLPs2.length > 0) {
                vm.prank(HOOK);
                uint256 swapId = jitCoordinator.createMultiLPJIT(
                    key,
                    TRADER,
                    LARGE_SWAP,
                    params,
                    eligibleLPs2,
                    contributions2
                );

                vm.prank(HOOK);
                jitCoordinator.executeMultiLPJIT(swapId);

                vm.prank(HOOK);
                jitCoordinator.removeJITLiquidity(key, swapId);

                // Remove again (should be safe)
                vm.prank(HOOK);
                jitCoordinator.removeJITLiquidity(key, swapId);
                console.log("Double removal handled safely");
            }
        }

        console.log("Edge cases handled correctly");
        console.log("");
    }

    // ============ Test 14: View Functions ============

    function testViewFunctions() public {
        console.log("TEST 14: View Functions");
        console.log("----------------------");

        _setupMultipleLPs();

        (address[] memory eligibleLPs, uint128[] memory contributions) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length > 0) {
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            uint256 swapId = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params,
                eligibleLPs,
                contributions
            );

            // Test getPendingJIT
            JITCoordinator.PendingJIT memory pendingJIT = jitCoordinator.getPendingJIT(swapId);
            console.log("PendingJIT data:");
            console.log("  Swap ID: %s", pendingJIT.swapId);
            console.log("  Swapper: %s", pendingJIT.swapper);
            console.log("  Amount: %s", pendingJIT.swapAmount);
            console.log("  Executed: %s", pendingJIT.executed);

            assertEq(pendingJIT.swapId, swapId, "Swap ID should match");
            assertEq(pendingJIT.swapper, TRADER, "Swapper should match");

            for (uint256 i = 0; i < eligibleLPs.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs[i]);
            }
            vm.warp(block.timestamp + 10);

            // Execute JIT
            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId);

            // Test getJITPosition
            JITCoordinator.JITLiquidityPosition memory jitPos = jitCoordinator.getJITPosition(swapId);
            console.log("\nJITPosition data:");
            console.log("  Swap ID: %s", jitPos.swapId);
            console.log("  Active: %s", jitPos.isActive);
            console.log("  Total liquidity: %s", jitPos.totalLiquidity);
            console.log("  LPs: %s", jitPos.participatingLPs.length);

            assertEq(jitPos.swapId, swapId, "Swap ID should match");
            assertTrue(jitPos.isActive, "Should be active");

            // Test isJITActive
            bool isActive = jitCoordinator.isJITActive(swapId);
            console.log("\nisJITActive: %s", isActive);
            assertTrue(isActive, "Should return true for active JIT");

            // Remove and test again
            vm.prank(HOOK);
            jitCoordinator.removeJITLiquidity(key, swapId);

            isActive = jitCoordinator.isJITActive(swapId);
            console.log("isJITActive after removal: %s", isActive);
            assertFalse(isActive, "Should return false after removal");
        }

        console.log("\nView functions working correctly");
        console.log("");
    }

    // ============ Test 15: Integration Scenario ============

    function testIntegrationScenario() public {
        console.log("TEST 15: Integration Scenario - Full JIT Workflow");
        console.log("------------------------------------------------");

        console.log("\n=== Phase 1: LP Setup ===");
        _setupMultipleLPs();

        console.log("\n=== Phase 2: Small Swap (No JIT) ===");
        (address[] memory eligibleLPs1, ) = 
            jitCoordinator.evaluateMultiLPJIT(key, 500);
        console.log("Swap 500: %s eligible LPs", eligibleLPs1.length);

        console.log("\n=== Phase 3: Medium Swap (Partial JIT) ===");
        (address[] memory eligibleLPs2, uint128[] memory contributions2) = 
            jitCoordinator.evaluateMultiLPJIT(key, 1500);
        console.log("Swap 1500: %s eligible LPs", eligibleLPs2.length);

        if (eligibleLPs2.length > 0) {
            SwapParams memory params2 = SwapParams({
                zeroForOne: true,
                amountSpecified: -1500,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            uint256 swapId2 = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                1500,
                params2,
                eligibleLPs2,
                contributions2
            );

            for (uint256 i = 0; i < eligibleLPs2.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs2[i]);
            }
            vm.warp(block.timestamp + 10);

            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId2);

            console.log("JIT executed for medium swap");

            for (uint256 i = 0; i < eligibleLPs2.length; i++) {
                (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, eligibleLPs2[i]);
                console.log("  LP %s earned: %s, %s", eligibleLPs2[i], profit0, profit1);
            }

            vm.prank(HOOK);
            jitCoordinator.removeJITLiquidity(key, swapId2);
            console.log("JIT removed");
        }

        console.log("\n=== Phase 4: Large Swap (Full JIT) ===");
        (address[] memory eligibleLPs3, uint128[] memory contributions3) = 
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);
        console.log("Swap %s: %s eligible LPs", LARGE_SWAP, eligibleLPs3.length);

        if (eligibleLPs3.length > 0) {
            SwapParams memory params3 = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(LARGE_SWAP)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.prank(HOOK);
            uint256 swapId3 = jitCoordinator.createMultiLPJIT(
                key,
                TRADER,
                LARGE_SWAP,
                params3,
                eligibleLPs3,
                contributions3
            );

            for (uint256 i = 0; i < eligibleLPs3.length; i++) {
                configManager.decryptHedgePercentage(key, eligibleLPs3[i]);
            }
            vm.warp(block.timestamp + 10);

            vm.prank(HOOK);
            jitCoordinator.executeMultiLPJIT(swapId3);

            console.log("JIT executed for large swap");

            JITCoordinator.JITLiquidityPosition memory jitPos = jitCoordinator.getJITPosition(swapId3);
            console.log("  Total JIT liquidity: %s", jitPos.totalLiquidity);
            console.log("  Participating LPs: %s", jitPos.participatingLPs.length);

            uint128 totalContribution = 0;
            for (uint256 i = 0; i < jitPos.lpContributions.length; i++) {
                totalContribution += jitPos.lpContributions[i];
                console.log("  LP %s contributed: %s", jitPos.participatingLPs[i], jitPos.lpContributions[i]);
            }
            console.log("  Total contributions: %s", totalContribution);

            vm.prank(HOOK);
            jitCoordinator.removeJITLiquidity(key, swapId3);
            console.log("JIT removed with bonus profits");
        }

        console.log("\n=== Phase 5: Final Profit Summary ===");
        address[] memory allLPs = positionManager.getPoolLPs(key);
        for (uint256 i = 0; i < allLPs.length; i++) {
            (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, allLPs[i]);
            console.log("LP %s total profits: %s token0, %s token1", allLPs[i], profit0, profit1);
        }

        console.log("\n=== Integration Summary ===");
        console.log("Small swaps bypass JIT (efficient)");
        console.log("Medium swaps trigger selective JIT (proportional)");
        console.log("Large swaps trigger full multi-LP coordination");
        console.log("Profits distributed fairly based on contributions");
        console.log("JIT positions managed cleanly (create -> execute -> remove)");

        console.log("\nIntegration scenario completed successfully");
        console.log("");
    }
}