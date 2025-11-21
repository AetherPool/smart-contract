// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

// Uniswap v4 imports
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
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
 * @title ProfitManager Test Suite
 * @notice Comprehensive tests for LP profit tracking, hedging, and compounding
 * @dev Tests manual/auto hedging, profit accrual, withdrawal, and batch operations
 */
contract ProfitManagerTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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
    address public constant USER = address(0x5555);
    address public constant OWNER = address(0x9999);

    PoolKey public key2;
    Currency public currency0_2;
    Currency public currency1_2;

    // Events for tracking
    event ProfitHedged(
        address indexed lp, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 hedgePercentage
    );
    event ProfitCompounded(
        address indexed lp, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 newTokenId
    );
    event ProfitAccrued(address indexed lp, bytes32 indexed poolId, uint256 amount0, uint256 amount1);
    event ProfitWithdrawn(address indexed lp, bytes32 indexed poolId, uint256 amount0, uint256 amount1);

    function setUp() public {
        console.log("=== ProfitManager Test Setup ===");

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

        // Initialize pools
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        console.log("Modules deployed:");
        console.log("  PositionManager:", address(positionManager));
        console.log("  ConfigManager:", address(configManager));
        console.log("  FeeManager:", address(feeManager));
        console.log("  ProfitManager:", address(profitManager));
        console.log("  JITCoordinator:", address(jitCoordinator));

        // Setup test accounts
        _setupTestAccounts();
        _setupSecondPoolTestAccounts();

        // Transfer tokens to profit manager for distribution
        MockERC20(Currency.unwrap(currency0)).mint(address(profitManager), 1000000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(profitManager), 1000000 ether);

        console.log("");
    }

    function _setupTestAccounts() private {
        address[4] memory accounts = [LP1, LP2, LP3, USER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);

            // Mint test tokens
            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            // Approve managers
            vm.startPrank(accounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(profitManager), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(profitManager), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _setupSecondPoolTestAccounts() private {
        currency0_2 = deployMintAndApproveCurrency();
        currency1_2 = deployMintAndApproveCurrency();
        (key2,) = initPool(currency0_2, currency1_2, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0_2)).mint(address(profitManager), 1000000 ether);
        MockERC20(Currency.unwrap(currency1_2)).mint(address(profitManager), 1000000 ether);
    }

    // ============ Test 1: Profit Accrual ============

    function testProfitAccrual() public {
        console.log("TEST 1: Profit Accrual");
        console.log("---------------------");

        // Accrue profits to LP1
        vm.prank(HOOK);
        vm.expectEmit(true, true, true, true);
        emit ProfitAccrued(LP1, keccak256(abi.encode(key)), 1000, 1500);
        profitManager.accrueProfit(key, LP1, 1000, 1500);

        console.log("Accrued profits to LP1: 1000 token0, 1500 token1");

        // Verify profits tracked
        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1000, "Token0 profit should be 1000");
        assertEq(profit1, 1500, "Token1 profit should be 1500");

        console.log("Verified profits: %s token0, %s token1", profit0, profit1);

        // Accrue more profits
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 500, 750);

        console.log("Accrued additional: 500 token0, 750 token1");

        // Verify cumulative profits
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1500, "Token0 profit should accumulate to 1500");
        assertEq(profit1, 2250, "Token1 profit should accumulate to 2250");

        console.log("Total profits: %s token0, %s token1", profit0, profit1);
        console.log("Profit accrual working correctly");
        console.log("");
    }

    // ============ Test 2: Manual Hedge ============

    function testManualHedge() public {
        console.log("TEST 2: Manual Hedge");
        console.log("-------------------");

        // Accrue profits first
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 3000);

        console.log("Initial profits: 2000 token0, 3000 token1");

        uint256 balance0Before = currency0.balanceOf(LP1);
        uint256 balance1Before = currency1.balanceOf(LP1);

        // Hedge 50% of profits
        vm.prank(LP1);
        vm.expectEmit(true, true, true, true);
        emit ProfitHedged(LP1, keccak256(abi.encode(key)), 1000, 1500, 50);
        profitManager.hedgeProfits(key, 50);

        console.log("Hedged 50%% of profits");

        uint256 balance0After = currency0.balanceOf(LP1);
        uint256 balance1After = currency1.balanceOf(LP1);

        // Verify tokens received
        assertEq(balance0After - balance0Before, 1000, "Should receive 1000 token0");
        assertEq(balance1After - balance1Before, 1500, "Should receive 1500 token1");

        console.log("Received: %s token0, %s token1", balance0After - balance0Before, balance1After - balance1Before);

        // Verify remaining profits
        (uint256 remainingProfit0, uint256 remainingProfit1) = profitManager.getLPProfits(key, LP1);
        assertEq(remainingProfit0, 1000, "Should have 1000 token0 remaining");
        assertEq(remainingProfit1, 1500, "Should have 1500 token1 remaining");

        console.log("Remaining profits: %s token0, %s token1", remainingProfit0, remainingProfit1);
        console.log("Manual hedge successful");
        console.log("");
    }

    // ============ Test 3: Full Withdrawal ============

    function testFullWithdrawal() public {
        console.log("TEST 3: Full Withdrawal");
        console.log("----------------------");

        // Accrue profits
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 1500, 2000);

        console.log("Accrued profits: 1500 token0, 2000 token1");

        uint256 balance0Before = currency0.balanceOf(LP1);
        uint256 balance1Before = currency1.balanceOf(LP1);

        // Withdraw all profits
        vm.prank(LP1);
        vm.expectEmit(true, true, true, true);
        emit ProfitWithdrawn(LP1, keccak256(abi.encode(key)), 1500, 2000);
        profitManager.withdrawProfits(key);

        console.log("Withdrew all profits");

        uint256 balance0After = currency0.balanceOf(LP1);
        uint256 balance1After = currency1.balanceOf(LP1);

        // Verify tokens received
        assertEq(balance0After - balance0Before, 1500, "Should receive all token0");
        assertEq(balance1After - balance1Before, 2000, "Should receive all token1");

        console.log("Received: %s token0, %s token1", balance0After - balance0Before, balance1After - balance1Before);

        // Verify profits cleared
        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0, "Profits should be cleared");
        assertEq(profit1, 0, "Profits should be cleared");

        console.log("Profits cleared successfully");
        console.log("");
    }

    // ============ Test 4: Auto-Hedge ============

    function testAutoHedge() public {
        console.log("TEST 4: Auto-Hedge");
        console.log("-----------------");

        // Configure LP with auto-hedge enabled
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory encProfit = createInEuint32(30, LP1);
        InEuint32 memory encHedge = createInEuint32(60, LP1);
        configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);
        vm.stopPrank();

        console.log("LP1 configured with 60%% auto-hedge");

        // Accrue profits
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 3000);

        console.log("Accrued profits: 2000 token0, 3000 token1");

        // Trigger decryption
        vm.prank(HOOK);
        configManager.decryptHedgePercentage(key, LP1);

        vm.warp(block.timestamp + 10);

        uint256 balance0Before = currency0.balanceOf(LP1);
        uint256 balance1Before = currency1.balanceOf(LP1);

        // Trigger auto-hedge
        vm.prank(HOOK);
        profitManager.autoHedgeProfits(key, LP1);

        console.log("Auto-hedge triggered");

        uint256 balance0After = currency0.balanceOf(LP1);
        uint256 balance1After = currency1.balanceOf(LP1);

        // Verify 60% hedged
        assertEq(balance0After - balance0Before, 1200, "Should receive 60% of token0");
        assertEq(balance1After - balance1Before, 1800, "Should receive 60% of token1");

        console.log("Auto-hedged: %s token0, %s token1", balance0After - balance0Before, balance1After - balance1Before);

        // Verify remaining profits (40%)
        (uint256 remainingProfit0, uint256 remainingProfit1) = profitManager.getLPProfits(key, LP1);
        assertEq(remainingProfit0, 800, "Should have 40% remaining");
        assertEq(remainingProfit1, 1200, "Should have 40% remaining");

        console.log("Remaining: %s token0, %s token1", remainingProfit0, remainingProfit1);
        console.log("Auto-hedge successful");
        console.log("");
    }

    // ============ Test 5: Profit Compounding ============

    function testProfitCompounding() public {
        console.log("TEST 5: Profit Compounding");
        console.log("-------------------------");

        // Accrue profits
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 3000, 4000);

        console.log("Accrued profits: 3000 token0, 4000 token1");

        // Get initial position count
        LPPositionManager.LPPosition[] memory positionsBefore = positionManager.getLPPositions(key, LP1);
        uint256 positionCountBefore = positionsBefore.length;
        console.log("Initial position count: %s", positionCountBefore);

        // Compound profits
        vm.prank(LP1);
        uint256 newTokenId = profitManager.compoundProfits(key, -120, 120);

        console.log("Compounded into new position, token ID: %s", newTokenId);

        // Verify profits cleared
        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0, "Profits should be cleared");
        assertEq(profit1, 0, "Profits should be cleared");

        console.log("Profits cleared after compounding");

        // Verify new position created
        LPPositionManager.LPPosition[] memory positionsAfter = positionManager.getLPPositions(key, LP1);
        assertEq(positionsAfter.length, positionCountBefore + 1, "Should have one more position");
        console.log("New position created successfully");

        console.log("Compounding successful");
        console.log("");
    }

    // ============ Test 6: Batch Hedge ============

    function testBatchHedge() public {
        console.log("TEST 6: Batch Hedge Across Pools");
        console.log("--------------------------------");

        // Accrue profits in both pools
        vm.startPrank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 3000);
        profitManager.accrueProfit(key2, LP1, 1500, 2500);
        vm.stopPrank();

        console.log("Pool 1 profits: 2000 token0, 3000 token1");
        console.log("Pool 2 profits: 1500 token0, 2500 token1");

        // Setup batch hedge
        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key2;

        uint256[] memory hedgePercentages = new uint256[](2);
        hedgePercentages[0] = 50; // Hedge 50% from pool 1
        hedgePercentages[1] = 75; // Hedge 75% from pool 2

        uint256 balance0_1Before = currency0.balanceOf(LP1);
        uint256 balance1_1Before = currency1.balanceOf(LP1);
        uint256 balance0_2Before = currency0_2.balanceOf(LP1);
        uint256 balance1_2Before = currency1_2.balanceOf(LP1);

        // Execute batch hedge
        vm.prank(LP1);
        profitManager.batchHedgeProfits(pools, hedgePercentages);

        console.log("Batch hedge executed");

        uint256 balance0_1After = currency0.balanceOf(LP1);
        uint256 balance1_1After = currency1.balanceOf(LP1);
        uint256 balance0_2After = currency0_2.balanceOf(LP1);
        uint256 balance1_2After = currency1_2.balanceOf(LP1);

        // Verify pool 1 hedge (50%)
        assertEq(balance0_1After - balance0_1Before, 1000, "Pool 1: Should receive 50% of token0");
        assertEq(balance1_1After - balance1_1Before, 1500, "Pool 1: Should receive 50% of token1");

        // Verify pool 2 hedge (75%)
        assertEq(balance0_2After - balance0_2Before, 1125, "Pool 2: Should receive 75% of token0");
        assertEq(balance1_2After - balance1_2Before, 1875, "Pool 2: Should receive 75% of token1");

        console.log(
            "Pool 1 hedged: %s token0, %s token1",
            balance0_1After - balance0_1Before,
            balance1_1After - balance1_1Before
        );
        console.log(
            "Pool 2 hedged: %s token0, %s token1",
            balance0_2After - balance0_2Before,
            balance1_2After - balance1_2Before
        );

        // Verify remaining profits
        (uint256 pool1Profit0, uint256 pool1Profit1) = profitManager.getLPProfits(key, LP1);
        (uint256 pool2Profit0, uint256 pool2Profit1) = profitManager.getLPProfits(key2, LP1);

        assertEq(pool1Profit0, 1000, "Pool 1: 50% should remain");
        assertEq(pool1Profit1, 1500, "Pool 1: 50% should remain");
        assertEq(pool2Profit0, 375, "Pool 2: 25% should remain");
        assertEq(pool2Profit1, 625, "Pool 2: 25% should remain");

        console.log("Batch hedge successful");
        console.log("");
    }

    // ============ Test 7: Multiple LP Profit Tracking ============

    function testMultipleLPProfitTracking() public {
        console.log("TEST 7: Multiple LP Profit Tracking");
        console.log("----------------------------------");

        vm.startPrank(HOOK);

        // Accrue profits to different LPs
        profitManager.accrueProfit(key, LP1, 1000, 1500);
        profitManager.accrueProfit(key, LP2, 2000, 2500);
        profitManager.accrueProfit(key, LP3, 1500, 2000);

        vm.stopPrank();

        console.log("LP1 profits: 1000 token0, 1500 token1");
        console.log("LP2 profits: 2000 token0, 2500 token1");
        console.log("LP3 profits: 1500 token0, 2000 token1");

        // Verify independent tracking
        (uint256 lp1Profit0, uint256 lp1Profit1) = profitManager.getLPProfits(key, LP1);
        (uint256 lp2Profit0, uint256 lp2Profit1) = profitManager.getLPProfits(key, LP2);
        (uint256 lp3Profit0, uint256 lp3Profit1) = profitManager.getLPProfits(key, LP3);

        assertEq(lp1Profit0, 1000, "LP1 token0 profit correct");
        assertEq(lp2Profit0, 2000, "LP2 token0 profit correct");
        assertEq(lp3Profit0, 1500, "LP3 token0 profit correct");

        console.log("All LP profits tracked independently");

        // LP2 hedges 30%
        vm.prank(LP2);
        profitManager.hedgeProfits(key, 30);

        console.log("LP2 hedged 30%%");

        // Verify only LP2 affected
        (lp1Profit0, lp1Profit1) = profitManager.getLPProfits(key, LP1);
        (lp2Profit0, lp2Profit1) = profitManager.getLPProfits(key, LP2);
        (lp3Profit0, lp3Profit1) = profitManager.getLPProfits(key, LP3);

        assertEq(lp1Profit0, 1000, "LP1 unchanged");
        assertEq(lp2Profit0, 1400, "LP2 reduced by 30%");
        assertEq(lp3Profit0, 1500, "LP3 unchanged");

        console.log("LP profits remain independent after individual hedge");
        console.log("");
    }

    // ============ Test 8: Total Profits Across Pools ============

    function testTotalProfitsAcrossPools() public {
        console.log("TEST 8: Total Profits Across Multiple Pools");
        console.log("------------------------------------------");

        vm.startPrank(HOOK);

        // Accrue profits across multiple pools
        profitManager.accrueProfit(key, LP1, 1000, 1500);
        profitManager.accrueProfit(key2, LP1, 2000, 2500);

        vm.stopPrank();

        console.log("Pool 1: 1000 token0, 1500 token1");
        console.log("Pool 2: 2000 token0, 2500 token1");

        // Get total profits
        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key2;

        (uint256 totalProfit0, uint256 totalProfit1) = profitManager.getTotalProfits(pools, LP1);

        console.log("Total across pools: %s token0, %s token1", totalProfit0, totalProfit1);

        assertEq(totalProfit0, 3000, "Total token0 should be 3000");
        assertEq(totalProfit1, 4000, "Total token1 should be 4000");

        console.log("Total profit calculation accurate");
        console.log("");
    }

    // ============ Test 9: Authorization Checks ============

    // function testAuthorizationChecks() public {
    //     console.log("TEST 9: Authorization & Security");
    //     console.log("-------------------------------");

    //     // Test unauthorized accrueProfit
    //     vm.prank(USER);
    //     vm.expectRevert(ProfitManager.Unauthorized.selector);
    //     profitManager.accrueProfit(key, LP1, 1000, 1000);
    //     console.log("Unauthorized accrueProfit blocked");

    //     // Test unauthorized autoHedgeProfits
    //     vm.prank(USER);
    //     vm.expectRevert(ProfitManager.Unauthorized.selector);
    //     profitManager.autoHedgeProfits(key, LP1);
    //     console.log("Unauthorized autoHedgeProfits blocked");

    //     console.log("All authorization checks passed");
    //     console.log("");
    // }

    // ============ Test 10: Invalid Operations ============

    function testInvalidOperations() public {
        console.log("TEST 10: Invalid Operations");
        console.log("--------------------------");

        // Test hedge with invalid percentage
        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InvalidPercentage.selector);
        profitManager.hedgeProfits(key, 101);
        console.log("Invalid percentage (>100) rejected");

        // Test hedge with no profits
        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.hedgeProfits(key, 50);
        console.log("Hedge with no profits rejected");

        // Test withdraw with no profits
        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.withdrawProfits(key);
        console.log("Withdraw with no profits rejected");

        // Test compound with no profits
        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.compoundProfits(key, -60, 60);
        console.log("Compound with no profits rejected");

        // Test batch hedge with mismatched arrays
        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key2;

        uint256[] memory hedgePercentages = new uint256[](1);
        hedgePercentages[0] = 50;

        vm.prank(LP1);
        vm.expectRevert(ProfitManager.ArrayLengthMismatch.selector);
        profitManager.batchHedgeProfits(pools, hedgePercentages);
        console.log("Batch hedge with mismatched arrays rejected");

        console.log("Invalid operation checks passed");
        console.log("");
    }

    // ============ Test 11: Edge Cases ============

    function testEdgeCases() public {
        console.log("TEST 11: Edge Cases");
        console.log("------------------");

        vm.startPrank(HOOK);

        // Test with very small profits
        profitManager.accrueProfit(key, LP1, 1, 1);
        console.log("Accrued minimal profits: 1, 1");

        vm.stopPrank();

        // Hedge 100%
        vm.prank(LP1);
        profitManager.hedgeProfits(key, 100);
        console.log("Hedged 100%% of minimal profits");

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0, "All profits hedged");
        assertEq(profit1, 0, "All profits hedged");

        // Test with zero hedge percentage
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 1000, 1500);

        uint256 balanceBefore = currency0.balanceOf(LP1);

        vm.prank(LP1);
        profitManager.hedgeProfits(key, 0);
        console.log("Hedged 0%% (no-op)");

        uint256 balanceAfter = currency0.balanceOf(LP1);

        assertEq(balanceAfter, balanceBefore, "No tokens transferred with 0% hedge");
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1000, "Profits unchanged");

        console.log("Edge cases handled correctly");
        console.log("");
    }

    // ============ Test 12: Hedge Percentage Validation ============

    function testHedgePercentageValidation() public {
        console.log("TEST 12: Hedge Percentage Validation");
        console.log("-----------------------------------");

        // Accrue profits
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 10000, 15000);

        console.log("Accrued: 10000 token0, 15000 token1");

        // Test different percentages
        uint256[] memory percentages = new uint256[](5);
        percentages[0] = 0;
        percentages[1] = 25;
        percentages[2] = 50;
        percentages[3] = 75;
        percentages[4] = 100;

        for (uint256 i = 0; i < percentages.length; i++) {
            // Re-accrue for each test
            vm.prank(HOOK);
            profitManager.accrueProfit(key, LP2, 10000, 15000);

            uint256 expected0 = (10000 * percentages[i]) / 100;
            uint256 expected1 = (15000 * percentages[i]) / 100;

            uint256 balanceBefore0 = currency0.balanceOf(LP2);
            uint256 balanceBefore1 = currency1.balanceOf(LP2);

            vm.prank(LP2);
            profitManager.hedgeProfits(key, percentages[i]);

            uint256 balanceAfter0 = currency0.balanceOf(LP2);
            uint256 balanceAfter1 = currency1.balanceOf(LP2);

            assertEq(balanceAfter0 - balanceBefore0, expected0, "Token0 amount should match percentage");
            assertEq(balanceAfter1 - balanceBefore1, expected1, "Token1 amount should match percentage");

            console.log("%s%% hedge: received %s token0, %s token1", percentages[i], expected0, expected1);

            // Clear profits for next iteration exempting the last
            if (i < percentages.length - 1) {
                vm.prank(LP2);
                profitManager.withdrawProfits(key);
            }
        }

        console.log("All percentages validated correctly");
        console.log("");
    }

    // ============ Test 13: Profit Lifecycle ============

    function testProfitLifecycle() public {
        console.log("TEST 13: Complete Profit Lifecycle");
        console.log("---------------------------------");

        console.log("\nPhase 1: Initial Accrual");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 5000, 7000);
        console.log("  Accrued: 5000 token0, 7000 token1");

        console.log("\nPhase 2: First Hedge (25%)");
        vm.prank(LP1);
        profitManager.hedgeProfits(key, 25);
        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        console.log("  Remaining: %s token0, %s token1", profit0, profit1);

        console.log("\nPhase 3: More Profits Accrued");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 3000, 4000);
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        console.log("  Total now: %s token0, %s token1", profit0, profit1);

        console.log("\nPhase 4: Second Hedge (50%)");
        vm.prank(LP1);
        profitManager.hedgeProfits(key, 50);
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        console.log("  Remaining: %s token0, %s token1", profit0, profit1);

        console.log("\nPhase 5: Final Accrual");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 3000);
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        console.log("  Total now: %s token0, %s token1", profit0, profit1);

        console.log("\nPhase 6: Complete Withdrawal");
        vm.prank(LP1);
        profitManager.withdrawProfits(key);
        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        console.log("  Final: %s token0, %s token1 (cleared)", profit0, profit1);

        assertEq(profit0, 0, "Profits should be cleared");
        assertEq(profit1, 0, "Profits should be cleared");

        console.log("\nProfit lifecycle completed successfully");
        console.log("");
    }

    // ============ Test 14: Compounding with Multiple Positions ============

    function testCompoundingMultiplePositions() public {
        console.log("TEST 14: Compounding Multiple Times");
        console.log("----------------------------------");

        console.log("\nRound 1: First Compound");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 3000);

        vm.prank(LP1);
        uint256 tokenId1 = profitManager.compoundProfits(key, -60, 60);
        console.log("  Created position 1, token ID: %s", tokenId1);

        console.log("\nRound 2: Second Compound");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 1500, 2500);

        vm.prank(LP1);
        uint256 tokenId2 = profitManager.compoundProfits(key, -120, 120);
        console.log("  Created position 2, token ID: %s", tokenId2);

        console.log("\nRound 3: Third Compound");
        vm.prank(HOOK);
        profitManager.accrueProfit(key, LP1, 3000, 4000);

        vm.prank(LP1);
        uint256 tokenId3 = profitManager.compoundProfits(key, -180, 180);
        console.log("  Created position 3, token ID: %s", tokenId3);

        // Verify all positions created
        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions.length, 3, "Should have 3 compounded positions");

        console.log("\nMultiple compounding successful");
        console.log("");
    }

    // ============ Test 15: Integration Scenario ============

    function testIntegrationScenario() public {
        console.log("TEST 15: Integration Scenario - LP Profit Management Strategies");
        console.log("--------------------------------------------------------------");

        console.log("\n=== Setup: Three LPs with Different Strategies ===");

        // LP1: Conservative - Frequent small hedges
        console.log("\nLP1 Strategy: Conservative Hedger");
        vm.startPrank(LP1);
        InEuint128 memory enc1MinSwap = createInEuint128(1000, LP1);
        InEuint128 memory enc1MaxLiq = createInEuint128(50000, LP1);
        InEuint32 memory enc1Profit = createInEuint32(25, LP1);
        InEuint32 memory enc1Hedge = createInEuint32(75, LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, true);
        vm.stopPrank();
        console.log("  Auto-hedge: 75%%, Manual control");

        // LP2: Moderate - Let profits accumulate, then compound
        console.log("\nLP2 Strategy: Compounder");
        vm.startPrank(LP2);
        InEuint128 memory enc2MinSwap = createInEuint128(1000, LP2);
        InEuint128 memory enc2MaxLiq = createInEuint128(50000, LP2);
        InEuint32 memory enc2Profit = createInEuint32(30, LP2);
        InEuint32 memory enc2Hedge = createInEuint32(50, LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, false);
        vm.stopPrank();
        console.log("  Manual hedge: 0%%, Focus on compounding");

        // LP3: Aggressive - Max profits, minimal hedging
        console.log("\nLP3 Strategy: Profit Maximizer");
        vm.startPrank(LP3);
        InEuint128 memory enc3MinSwap = createInEuint128(500, LP3);
        InEuint128 memory enc3MaxLiq = createInEuint128(100000, LP3);
        InEuint32 memory enc3Profit = createInEuint32(40, LP3);
        InEuint32 memory enc3Hedge = createInEuint32(20, LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3MaxLiq, enc3Profit, enc3Hedge, false);
        vm.stopPrank();
        console.log("  Manual hedge: 20%%, Let profits grow");

        console.log("\n=== Week 1: JIT Trading Activity ===");
        vm.startPrank(HOOK);
        profitManager.accrueProfit(key, LP1, 1500, 2000);
        profitManager.accrueProfit(key, LP2, 2000, 2500);
        profitManager.accrueProfit(key, LP3, 2500, 3000);
        vm.stopPrank();

        console.log("Profits accrued:");
        console.log("  LP1: 1500 token0, 2000 token1");
        console.log("  LP2: 2000 token0, 2500 token1");
        console.log("  LP3: 2500 token0, 3000 token1");

        // LP1 hedges immediately (conservative)
        vm.prank(LP1);
        profitManager.hedgeProfits(key, 75);
        console.log("\nLP1 hedged 75%%");

        console.log("\n=== Week 2: More Activity ===");
        vm.startPrank(HOOK);
        profitManager.accrueProfit(key, LP1, 2000, 2500);
        profitManager.accrueProfit(key, LP2, 2500, 3000);
        profitManager.accrueProfit(key, LP3, 3000, 3500);
        vm.stopPrank();

        console.log("Additional profits accrued");

        // LP1 hedges again
        vm.prank(LP1);
        profitManager.hedgeProfits(key, 50);
        console.log("LP1 hedged 50%% of accumulated profits");

        // LP3 takes small hedge
        vm.prank(LP3);
        profitManager.hedgeProfits(key, 20);
        console.log("LP3 hedged 20%% (minimal)");

        console.log("\n=== Week 3: LP2 Compounds ===");
        vm.startPrank(HOOK);
        profitManager.accrueProfit(key, LP1, 1000, 1500);
        profitManager.accrueProfit(key, LP2, 1500, 2000);
        profitManager.accrueProfit(key, LP3, 2000, 2500);
        vm.stopPrank();

        console.log("More profits accrued");

        // LP2 compounds accumulated profits
        vm.prank(LP2);
        uint256 lp2CompoundedTokenId = profitManager.compoundProfits(key, -90, 90);
        console.log("LP2 compounded all profits into new position, token ID: %s", lp2CompoundedTokenId);

        console.log("\n=== Week 4: Final State ===");
        vm.startPrank(HOOK);
        profitManager.accrueProfit(key, LP1, 1800, 2200);
        profitManager.accrueProfit(key, LP2, 800, 1200);
        profitManager.accrueProfit(key, LP3, 3500, 4000);
        vm.stopPrank();

        console.log("Final profits accrued");

        // Get final profit states
        (uint256 lp1Profit0, uint256 lp1Profit1) = profitManager.getLPProfits(key, LP1);
        (uint256 lp2Profit0, uint256 lp2Profit1) = profitManager.getLPProfits(key, LP2);
        (uint256 lp3Profit0, uint256 lp3Profit1) = profitManager.getLPProfits(key, LP3);

        console.log("\n=== Final Profit Summary ===");
        console.log("\nLP1 (Conservative):");
        console.log("  Current profits: %s token0, %s token1", lp1Profit0, lp1Profit1);
        console.log("  Strategy: Frequent hedging preserved capital");

        console.log("\nLP2 (Compounder):");
        console.log("  Current profits: %s token0, %s token1", lp2Profit0, lp2Profit1);
        console.log("  Strategy: Compounded profits into growth");
        LPPositionManager.LPPosition[] memory lp2Positions = positionManager.getLPPositions(key, LP2);
        console.log("  Compounded positions: %s", lp2Positions.length);

        console.log("\nLP3 (Profit Maximizer):");
        console.log("  Current profits: %s token0, %s token1", lp3Profit0, lp3Profit1);
        console.log("  Strategy: Minimal hedging, maximum accumulation");

        // LP3 final withdrawal
        vm.prank(LP3);
        profitManager.withdrawProfits(key);
        console.log("\nLP3 withdrew all accumulated profits");

        console.log("\n=== Behavioral Analysis ===");
        console.log("LP1: Risk-averse, regular hedging maintained low profit balance");
        console.log("LP2: Growth-focused, compounded profits into more liquidity");
        console.log("LP3: Profit-maximizing, accumulated large profits before withdrawal");
        console.log("\nDifferent strategies served different LP goals successfully");

        // Verify positions
        assertTrue(lp2Positions.length > 0, "LP2 should have compounded positions");
        assertGt(lp1Profit0 + lp1Profit1, 0, "LP1 should have some remaining profits");

        console.log("\nIntegration scenario completed successfully");
        console.log("Demonstrated diverse profit management strategies");
        console.log("");
    }
}
