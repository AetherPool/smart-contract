// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {Test} from "forge-std/Test.sol";
// import "forge-std/console.sol";

// // Uniswap v4 imports
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
// import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// // Contract under test
// import {FHEConfigManager} from "../src/FHEConfigManager.sol";
// import {LPPositionManager} from "../src/LPPositionManager.sol";
// import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
// import {ProfitManager} from "../src/ProfitManager.sol";
// import {JITCoordinator} from "../src/JITCoordinator.sol";
// import {FeeCalculator} from "../src/FeeCalculator.sol";

// /**
//  * @title LPPositionManager Test Suite
//  * @notice Comprehensive tests for internal ERC-6909-style LP token management
//  * @dev Tests position creation, tracking, withdrawal, and multi-position scenarios
//  */
// contract LPPositionManagerTest is Test, Deployers, CoFheTest {
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;

//     // ============ Test Setup ============
//     FHEConfigManager public configManager;
//     LPPositionManager public positionManager;
//     DynamicFeeManager public feeManager;
//     ProfitManager public profitManager;
//     JITCoordinator public jitCoordinator;
//     FeeCalculator public feeCalculator;
//     ZKJITLiquidityHook public hook;

//     address public constant HOOK = address(0x1111);
//     address public constant LP1 = address(0x2222);
//     address public constant LP2 = address(0x3333);
//     address public constant LP3 = address(0x4444);
//     address public constant USER = address(0x5555);
//     address public constant OWNER = address(0x9999);

//     // Events for tracking
//     event LPTokenMinted(address indexed lp, bytes32 indexed poolId, uint256 tokenId, uint128 liquidity);
//     event LPTokenBurned(address indexed lp, bytes32 indexed poolId, uint256 tokenId, uint128 liquidity);
//     event LiquidityAdded(
//         address indexed lp, bytes32 indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity
//     );
//     event LiquidityRemoved(address indexed lp, bytes32 indexed poolId, uint128 liquidity);

//     function setUp() public {
//         console.log("=== LPPositionManager Test Setup ===");

//         // Deploy Uniswap v4 infrastructure
//         deployFreshManagerAndRouters();
//         (currency0, currency1) = deployMintAndApprove2Currencies();

//         // Calculate hook address with required permissions
//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
//                 | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
//         );
//         address hookAddress = address(flags);

//         vm.txGasPrice(10 gwei);

//         // ============ DEPLOY MODULES FIRST ============

//         positionManager = new LPPositionManager();
//         configManager = new FHEConfigManager();
//         feeCalculator = new FeeCalculator();

//         vm.startPrank(HOOK); // Hook needs to be the caller so as to update moving average
//         feeManager = new DynamicFeeManager(HOOK, OWNER);
//         vm.stopPrank();

//         profitManager = new ProfitManager(address(positionManager), address(configManager));
//         jitCoordinator = new JITCoordinator(
//             manager,
//             HOOK,
//             address(positionManager),
//             address(configManager),
//             address(profitManager),
//             address(feeCalculator)
//         );

//         console.log("Modules deployed:");
//         console.log("  PositionManager:", address(positionManager));
//         console.log("  ConfigManager:", address(configManager));
//         console.log("  FeeManager:", address(feeManager));
//         console.log("  ProfitManager:", address(profitManager));
//         console.log("  JITCoordinator:", address(jitCoordinator));

//         // ============ DEPLOY HOOK WITH MODULE ADDRESSES ============

//         deployCodeTo(
//             "ZKJITLiquidityHook.sol",
//             abi.encode(
//                 manager,
//                 address(positionManager),
//                 address(configManager),
//                 address(feeManager),
//                 address(profitManager),
//                 address(jitCoordinator),
//                 address(feeCalculator)
//             ),
//             hookAddress
//         );
//         hook = ZKJITLiquidityHook(hookAddress);

//         // Initialize pool
//         (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

//         console.log("Pool initialized");

//         // Setup test accounts with tokens
//         _setupTestAccounts();

//         console.log("");
//     }

//     function _setupTestAccounts() private {
//         address[4] memory accounts = [LP1, LP2, LP3, USER];

//         for (uint256 i = 0; i < accounts.length; i++) {
//             vm.deal(accounts[i], 100 ether);

//             // Mint test tokens
//             MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
//             MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

//             // Approve position manager
//             vm.startPrank(accounts[i]);
//             MockERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint256).max);
//             MockERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint256).max);
//             vm.stopPrank();
//         }
//     }

//     // ============ Test 1: Single Position Deposit ============

//     function testSinglePositionDeposit() public {
//         console.log("TEST 1: Single Position Deposit");
//         console.log("-------------------------------");

//         uint256 balance0Before = currency0.balanceOf(LP1);
//         uint256 balance1Before = currency1.balanceOf(LP1);

//         console.log("LP1 balances before:");
//         console.log("  Token0: %s", balance0Before);
//         console.log("  Token1: %s", balance1Before);

//         // Deposit liquidity
//         vm.prank(HOOK);
//         vm.expectEmit(true, true, true, true);
//         emit LPTokenMinted(LP1, keccak256(abi.encode(key)), 1, 5000);
//         uint256 tokenId = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);

//         console.log("Position created with token ID: %s", tokenId);

//         uint256 balance0After = currency0.balanceOf(LP1);
//         uint256 balance1After = currency1.balanceOf(LP1);

//         console.log("LP1 balances after:");
//         console.log("  Token0: %s", balance0After);
//         console.log("  Token1: %s", balance1After);

//         // Verify balances decreased
//         assertEq(balance0Before - balance0After, 2500, "Token0 should be transferred");
//         assertEq(balance1Before - balance1After, 2500, "Token1 should be transferred");

//         // Verify position tracking
//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions.length, 1, "Should have 1 position");
//         assertEq(positions[0].tokenId, tokenId, "Token ID should match");
//         assertEq(positions[0].liquidity, 5000, "Liquidity should match");
//         assertEq(positions[0].tickLower, -60, "Tick lower should match");
//         assertEq(positions[0].tickUpper, 60, "Tick upper should match");
//         assertTrue(positions[0].isActive, "Position should be active");

//         // Verify LP registration
//         assertTrue(positionManager.isRegistered(key, LP1), "LP should be registered");

//         console.log("Single position deposit successful");
//         console.log("");
//     }

//     // ============ Test 2: Multiple Positions (Same LP) ============

//     function testMultiplePositionsSameLP() public {
//         console.log("TEST 2: Multiple Positions (Same LP)");
//         console.log("-----------------------------------");

//         vm.startPrank(HOOK);

//         // Create position 1: Wide range
//         uint256 tokenId1 = positionManager.depositLiquidity(key, -180, 180, 3000, 1500, 1500, LP1);
//         console.log("Position 1: Wide range (-180 to 180), Token ID: %s", tokenId1);

//         // Create position 2: Narrow range
//         uint256 tokenId2 = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);
//         console.log("Position 2: Narrow range (-60 to 60), Token ID: %s", tokenId2);

//         // Create position 3: Medium range
//         uint256 tokenId3 = positionManager.depositLiquidity(key, -120, 120, 4000, 2000, 2000, LP1);
//         console.log("Position 3: Medium range (-120 to 120), Token ID: %s", tokenId3);

//         vm.stopPrank();

//         // Verify all positions tracked
//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions.length, 3, "Should have 3 positions");

//         // Verify token IDs are unique and sequential
//         assertEq(positions[0].tokenId, 1, "First token ID should be 1");
//         assertEq(positions[1].tokenId, 2, "Second token ID should be 2");
//         assertEq(positions[2].tokenId, 3, "Third token ID should be 3");

//         // Verify all positions are active
//         for (uint256 i = 0; i < positions.length; i++) {
//             assertTrue(positions[i].isActive, "All positions should be active");
//             console.log(
//                 "Position %s verified: liquidity=%s, active=%s", i + 1, positions[i].liquidity, positions[i].isActive
//             );
//         }

//         console.log("Multiple positions created and tracked successfully");
//         console.log("");
//     }

//     // ============ Test 3: Multiple LPs ============

//     function testMultipleLPs() public {
//         console.log("TEST 3: Multiple LPs");
//         console.log("-------------------");

//         vm.startPrank(HOOK);

//         // LP1 creates position
//         uint256 tokenId1 = positionManager.depositLiquidity(key, -120, 120, 5000, 2500, 2500, LP1);
//         console.log("LP1 created position, Token ID: %s", tokenId1);

//         // LP2 creates position
//         uint256 tokenId2 = positionManager.depositLiquidity(key, -60, 60, 3000, 1500, 1500, LP2);
//         console.log("LP2 created position, Token ID: %s", tokenId2);

//         // LP3 creates position
//         uint256 tokenId3 = positionManager.depositLiquidity(key, -180, 180, 4000, 2000, 2000, LP3);
//         console.log("LP3 created position, Token ID: %s", tokenId3);

//         vm.stopPrank();

//         // Verify each LP has their own positions
//         LPPositionManager.LPPosition[] memory lp1Positions = positionManager.getLPPositions(key, LP1);
//         LPPositionManager.LPPosition[] memory lp2Positions = positionManager.getLPPositions(key, LP2);
//         LPPositionManager.LPPosition[] memory lp3Positions = positionManager.getLPPositions(key, LP3);

//         assertEq(lp1Positions.length, 1, "LP1 should have 1 position");
//         assertEq(lp2Positions.length, 1, "LP2 should have 1 position");
//         assertEq(lp3Positions.length, 1, "LP3 should have 1 position");

//         // Verify all LPs are registered
//         address[] memory poolLPs = positionManager.getPoolLPs(key);
//         assertEq(poolLPs.length, 3, "Should have 3 registered LPs");
//         console.log("Total registered LPs in pool: %s", poolLPs.length);

//         // Verify token ownership
//         assertEq(positionManager.getTokenOwner(key, tokenId1), LP1, "LP1 should own token 1");
//         assertEq(positionManager.getTokenOwner(key, tokenId2), LP2, "LP2 should own token 2");
//         assertEq(positionManager.getTokenOwner(key, tokenId3), LP3, "LP3 should own token 3");

//         console.log("Multiple LPs managed independently");
//         console.log("");
//     }

//     // ============ Test 4: Partial Liquidity Removal ============

//     function testPartialLiquidityRemoval() public {
//         console.log("TEST 4: Partial Liquidity Removal");
//         console.log("--------------------------------");

//         // Create position
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -120, 120, 6000, 3000, 3000, LP1);
//         console.log("Initial position: liquidity=6000");

//         LPPositionManager.LPPosition[] memory positionsBefore = positionManager.getLPPositions(key, LP1);
//         console.log("Liquidity before removal: %s", positionsBefore[0].liquidity);

//         uint256 balance0Before = currency0.balanceOf(LP1);
//         uint256 balance1Before = currency1.balanceOf(LP1);

//         // Remove 2000 liquidity (1/3)
//         vm.prank(HOOK);
//         (uint128 amount0, uint128 amount1) = positionManager.removeLiquidity(key, tokenId, 2000, LP1);

//         console.log("Removed liquidity: 2000");
//         console.log("Tokens returned: %s token0, %s token1", amount0, amount1);

//         // Verify proportional withdrawal
//         assertEq(amount0, 1000, "Should receive 1/3 of token0");
//         assertEq(amount1, 1000, "Should receive 1/3 of token1");

//         // Verify balances increased
//         uint256 balance0After = currency0.balanceOf(LP1);
//         uint256 balance1After = currency1.balanceOf(LP1);
//         assertEq(balance0After - balance0Before, 1000, "Token0 balance should increase");
//         assertEq(balance1After - balance1Before, 1000, "Token1 balance should increase");

//         // Verify position updated
//         LPPositionManager.LPPosition[] memory positionsAfter = positionManager.getLPPositions(key, LP1);
//         assertEq(positionsAfter[0].liquidity, 4000, "Remaining liquidity should be 4000");
//         assertTrue(positionsAfter[0].isActive, "Position should still be active");

//         console.log("Remaining liquidity: %s", positionsAfter[0].liquidity);
//         console.log("Partial removal successful");
//         console.log("");
//     }

//     // ============ Test 5: Complete Liquidity Removal ============

//     function testCompleteLiquidityRemoval() public {
//         console.log("TEST 5: Complete Liquidity Removal");
//         console.log("---------------------------------");

//         // Create position
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);
//         console.log("Initial position: liquidity=5000, token ID=%s", tokenId);

//         // Remove all liquidity
//         vm.prank(HOOK);
//         vm.expectEmit(true, true, true, true);
//         emit LPTokenBurned(LP1, keccak256(abi.encode(key)), tokenId, 5000);
//         (uint128 amount0, uint128 amount1) = positionManager.removeLiquidity(key, tokenId, 5000, LP1);

//         console.log("Removed all liquidity: 5000");
//         console.log("Tokens returned: %s token0, %s token1", amount0, amount1);

//         // Verify complete withdrawal
//         assertEq(amount0, 2500, "Should receive all token0");
//         assertEq(amount1, 2500, "Should receive all token1");

//         // Verify position is deactivated
//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions[0].liquidity, 0, "Liquidity should be 0");
//         assertFalse(positions[0].isActive, "Position should be inactive");

//         console.log("Position deactivated after complete removal");
//         console.log("");
//     }

//     // ============ Test 6: Position Ownership Verification ============

//     function testPositionOwnership() public {
//         console.log("TEST 6: Position Ownership Verification");
//         console.log("--------------------------------------");

//         // LP1 creates position
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -120, 120, 5000, 2500, 2500, LP1);
//         console.log("LP1 created position with token ID: %s", tokenId);

//         // Verify ownership
//         address owner = positionManager.getTokenOwner(key, tokenId);
//         assertEq(owner, LP1, "LP1 should be the owner");
//         console.log("Token owner verified: %s", owner);

//         // Try to remove liquidity as non-owner (should fail)
//         vm.prank(HOOK);
//         vm.expectRevert(LPPositionManager.NotTokenOwner.selector);
//         positionManager.removeLiquidity(key, tokenId, 1000, LP2);
//         console.log("LP2 cannot remove LP1's liquidity (ownership protected)");

//         // Owner can remove successfully
//         vm.prank(HOOK);
//         (uint128 amount0, uint128 amount1) = positionManager.removeLiquidity(key, tokenId, 1000, LP1);
//         console.log("LP1 successfully removed liquidity: %s, %s", amount0, amount1);

//         console.log("Ownership verification passed");
//         console.log("");
//     }

//     // ============ Test 7: Overlapping Position Detection ============

//     function testOverlappingPositionDetection() public {
//         console.log("TEST 7: Overlapping Position Detection");
//         console.log("-------------------------------------");

//         PoolId poolId = key.toId();
//         int24 currentTick = 0; // Assume price at 1:1
//         int24 tickRange = 60;

//         vm.startPrank(HOOK);

//         // Create positions with different ranges
//         positionManager.depositLiquidity(key, -180, -120, 3000, 1500, 1500, LP1); // Far below
//         positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1); // Overlaps
//         positionManager.depositLiquidity(key, 120, 180, 3000, 1500, 1500, LP1); // Far above

//         vm.stopPrank();

//         console.log("Created 3 positions:");
//         console.log("  Position 1: -180 to -120 (below JIT range)");
//         console.log("  Position 2: -60 to 60 (overlaps JIT range)");
//         console.log("  Position 3: 120 to 180 (above JIT range)");

//         // Check for overlapping positions
//         bool hasOverlap = positionManager.hasOverlappingPosition(poolId, LP1, currentTick, tickRange);
//         assertTrue(hasOverlap, "Should detect overlapping position");
//         console.log("Overlap detected: %s", hasOverlap);

//         // Test with LP that has no positions
//         bool noOverlap = positionManager.hasOverlappingPosition(poolId, LP2, currentTick, tickRange);
//         assertFalse(noOverlap, "LP2 should have no overlapping positions");
//         console.log("LP2 has no overlap: %s", !noOverlap);

//         console.log("Overlapping position detection working correctly");
//         console.log("");
//     }

//     // ============ Test 8: Total Liquidity Calculation ============

//     function testTotalLiquidityCalculation() public {
//         console.log("TEST 8: Total Liquidity Calculation");
//         console.log("----------------------------------");

//         PoolId poolId = key.toId();

//         vm.startPrank(HOOK);

//         // Create multiple positions
//         positionManager.depositLiquidity(key, -180, 180, 3000, 1500, 1500, LP1);
//         positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);
//         positionManager.depositLiquidity(key, -120, 120, 4000, 2000, 2000, LP1);

//         vm.stopPrank();

//         console.log("Created 3 positions:");
//         console.log("  Position 1: 3000 liquidity");
//         console.log("  Position 2: 5000 liquidity");
//         console.log("  Position 3: 4000 liquidity");

//         // Calculate total liquidity
//         uint128 totalLiquidity = positionManager.getTotalLiquidity(poolId, LP1);
//         console.log("Total liquidity: %s", totalLiquidity);

//         assertEq(totalLiquidity, 12000, "Total should be 12000");

//         // Remove one position completely
//         vm.prank(HOOK);
//         positionManager.removeLiquidity(key, 2, 5000, LP1);

//         console.log("Removed position 2 (5000 liquidity)");

//         // Recalculate
//         totalLiquidity = positionManager.getTotalLiquidity(poolId, LP1);
//         console.log("Total liquidity after removal: %s", totalLiquidity);

//         assertEq(totalLiquidity, 7000, "Total should be 7000 after removal");

//         console.log("Total liquidity calculation accurate");
//         console.log("");
//     }

//     // ============ Test 9: Fee Tracking Update ============

//     function testFeeTrackingUpdate() public {
//         console.log("TEST 9: Fee Tracking Update");
//         console.log("--------------------------");

//         PoolId poolId = key.toId();

//         // Create position
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);
//         console.log("Position created with token ID: %s", tokenId);

//         // Simulate fee accumulation
//         vm.prank(HOOK);
//         positionManager.updatePositionFees(poolId, LP1, tokenId, 100, 150);
//         console.log("Updated fees: 100 token0, 150 token1");

//         // Verify fees tracked
//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions[0].uncollectedFees0, 100, "Token0 fees should be tracked");
//         assertEq(positions[0].uncollectedFees1, 150, "Token1 fees should be tracked");

//         // Accumulate more fees
//         vm.prank(HOOK);
//         positionManager.updatePositionFees(poolId, LP1, tokenId, 50, 75);
//         console.log("Added more fees: 50 token0, 75 token1");

//         // Verify cumulative fees
//         positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions[0].uncollectedFees0, 150, "Token0 fees should accumulate");
//         assertEq(positions[0].uncollectedFees1, 225, "Token1 fees should accumulate");

//         console.log(
//             "Total uncollected fees: %s token0, %s token1", positions[0].uncollectedFees0, positions[0].uncollectedFees1
//         );
//         console.log("Fee tracking working correctly");
//         console.log("");
//     }

//     // ============ Test 10: Authorization Checks ============

//     function testAuthorizationChecks() public {
//         console.log("TEST 10: Authorization & Security");
//         console.log("--------------------------------");

//         // Test unauthorized deposit
//         // vm.prank(USER);
//         // vm.expectRevert(LPPositionManager.Unauthorized.selector);
//         // positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);
//         // console.log("Unauthorized deposit blocked");

//         // Create position as hook
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);

//         // Test unauthorized removal
//         vm.prank(USER);
//         vm.expectRevert(LPPositionManager.Unauthorized.selector);
//         positionManager.removeLiquidity(key, tokenId, 1000, LP1);
//         console.log("Unauthorized removal blocked");

//         // Test unauthorized fee update
//         vm.prank(USER);
//         vm.expectRevert(LPPositionManager.Unauthorized.selector);
//         positionManager.updatePositionFees(key.toId(), LP1, tokenId, 100, 100);
//         console.log("Unauthorized fee update blocked");

//         console.log("All authorization checks passed");
//         console.log("");
//     }

//     // ============ Test 11: Invalid Operations ============

//     function testInvalidOperations() public {
//         console.log("TEST 11: Invalid Operations");
//         console.log("--------------------------");

//         // Test deposit with zero liquidity
//         vm.prank(HOOK);
//         vm.expectRevert(LPPositionManager.InvalidLiquidity.selector);
//         positionManager.depositLiquidity(key, -60, 60, 0, 2500, 2500, LP1);
//         console.log("Zero liquidity deposit rejected");

//         // Create valid position
//         vm.prank(HOOK);
//         uint256 tokenId = positionManager.depositLiquidity(key, -60, 60, 5000, 2500, 2500, LP1);

//         // Test removing more liquidity than available
//         vm.prank(HOOK);
//         vm.expectRevert(LPPositionManager.InsufficientLiquidity.selector);
//         positionManager.removeLiquidity(key, tokenId, 6000, LP1);
//         console.log("Excessive liquidity removal rejected");

//         // Test removing from non-existent token
//         vm.prank(HOOK);
//         vm.expectRevert(LPPositionManager.NotTokenOwner.selector);
//         positionManager.removeLiquidity(key, 999, 1000, LP1);
//         console.log("Non-existent position removal rejected");

//         console.log("Invalid operation checks passed");
//         console.log("");
//     }

//     // ============ Test 12: Edge Cases ============

//     function testEdgeCases() public {
//         console.log("TEST 12: Edge Cases");
//         console.log("------------------");

//         vm.startPrank(HOOK);

//         // Test with extreme tick ranges
//         uint256 tokenId1 = positionManager.depositLiquidity(key, -887220, 887220, 1000, 500, 500, LP1);
//         console.log("Position created with full tick range: token ID %s", tokenId1);

//         // Test with very small liquidity
//         uint256 tokenId2 = positionManager.depositLiquidity(key, -60, 60, 1, 1, 1, LP1);
//         console.log("Position created with minimal liquidity: token ID %s", tokenId2);

//         // Test with same tick (single tick position)
//         uint256 tokenId3 = positionManager.depositLiquidity(key, 0, 60, 1000, 500, 500, LP1);
//         console.log("Position created at specific tick: token ID %s", tokenId3);

//         vm.stopPrank();

//         // Verify all positions created successfully
//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         assertEq(positions.length, 3, "Should have 3 positions");

//         console.log("All edge case positions created successfully");
//         console.log("");
//     }

//     // ============ Test 13: Multi-Pool Positions ============

//     function testMultiPoolPositions() public {
//         console.log("TEST 13: Multi-Pool Positions");
//         console.log("----------------------------");

//         // Create second pool
//         PoolKey memory key2;
//         Currency currency0_2 = deployMintAndApproveCurrency();
//         Currency currency1_2 = deployMintAndApproveCurrency();
//         (key2,) = initPool(currency0_2, currency1_2, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

//         MockERC20(Currency.unwrap(currency0_2)).mint(LP1, 100000 ether);
//         MockERC20(Currency.unwrap(currency1_2)).mint(LP1, 100000 ether);

//         vm.startPrank(LP1);
//         MockERC20(Currency.unwrap(currency0_2)).approve(address(positionManager), type(uint256).max);
//         MockERC20(Currency.unwrap(currency1_2)).approve(address(positionManager), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(HOOK);

//         // Create positions in first pool
//         uint256 tokenId1 = positionManager.depositLiquidity(key, -60, 60, 3000, 1500, 1500, LP1);
//         console.log("Pool 1 position created: token ID %s", tokenId1);

//         // Create positions in second pool
//         uint256 tokenId2 = positionManager.depositLiquidity(key2, -120, 120, 5000, 2500, 2500, LP1);
//         console.log("Pool 2 position created: token ID %s", tokenId2);

//         vm.stopPrank();

//         // Verify independent tracking
//         LPPositionManager.LPPosition[] memory positions1 = positionManager.getLPPositions(key, LP1);
//         LPPositionManager.LPPosition[] memory positions2 = positionManager.getLPPositions(key2, LP1);

//         assertEq(positions1.length, 1, "Should have 1 position in pool 1");
//         assertEq(positions2.length, 1, "Should have 1 position in pool 2");

//         console.log("LP1 positions in Pool 1: %s", positions1.length);
//         console.log("LP1 positions in Pool 2: %s", positions2.length);
//         console.log("Multi-pool positions tracked independently");
//         console.log("");
//     }

//     // ============ Test 14: Position Lifecycle ============

//     function testPositionLifecycle() public {
//         console.log("TEST 14: Complete Position Lifecycle");
//         console.log("-----------------------------------");

//         vm.startPrank(HOOK);

//         console.log("\nPhase 1: Creation");
//         uint256 tokenId = positionManager.depositLiquidity(key, -120, 120, 10000, 5000, 5000, LP1);
//         console.log("  Position created: ID=%s, liquidity=10000", tokenId);

//         LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
//         console.log("  Status: Active=%s, Liquidity=%s", positions[0].isActive, positions[0].liquidity);

//         console.log("\nPhase 2: Partial Withdrawal");
//         positionManager.removeLiquidity(key, tokenId, 3000, LP1);
//         positions = positionManager.getLPPositions(key, LP1);
//         console.log("  Removed 3000 liquidity");
//         console.log("  Status: Active=%s, Remaining=%s", positions[0].isActive, positions[0].liquidity);

//         console.log("\nPhase 3: Fee Accumulation");
//         positionManager.updatePositionFees(key.toId(), LP1, tokenId, 200, 250);
//         positions = positionManager.getLPPositions(key, LP1);
//         console.log(
//             "  Fees accumulated: %s token0, %s token1", positions[0].uncollectedFees0, positions[0].uncollectedFees1
//         );

//         console.log("\nPhase 4: Another Partial Withdrawal");
//         positionManager.removeLiquidity(key, tokenId, 4000, LP1);
//         positions = positionManager.getLPPositions(key, LP1);
//         console.log("  Removed 4000 more liquidity");
//         console.log("  Status: Active=%s, Remaining=%s", positions[0].isActive, positions[0].liquidity);

//         console.log("\nPhase 5: More Fee Accumulation");
//         positionManager.updatePositionFees(key.toId(), LP1, tokenId, 150, 180);
//         positions = positionManager.getLPPositions(key, LP1);
//         console.log(
//             "  More fees: %s token0, %s token1 (cumulative)",
//             positions[0].uncollectedFees0,
//             positions[0].uncollectedFees1
//         );

//         console.log("\nPhase 6: Final Withdrawal");
//         positionManager.removeLiquidity(key, tokenId, 3000, LP1);
//         positions = positionManager.getLPPositions(key, LP1);
//         console.log("  Removed final 3000 liquidity");
//         console.log("  Status: Active=%s, Liquidity=%s", positions[0].isActive, positions[0].liquidity);

//         vm.stopPrank();

//         console.log("\nLifecycle completed successfully");
//         console.log("Position went from active -> partial withdrawals -> fully withdrawn");
//         console.log("");
//     }

//     // ============ Test 15: Integration Scenario ============

//     function testIntegrationScenario() public {
//         console.log("TEST 15: Integration Scenario - Diverse LP Strategies");
//         console.log("----------------------------------------------------");

//         vm.startPrank(HOOK);

//         console.log("\nPhase 1: Initial Liquidity Deployment");
//         console.log("------------------------------------");

//         // LP1: Conservative - Single wide position
//         uint256 lp1Token1 = positionManager.depositLiquidity(key, -240, 240, 8000, 4000, 4000, LP1);
//         console.log("LP1 (Conservative): Wide position (-240 to 240), 8000 liquidity");

//         // LP2: Moderate - Two medium positions
//         uint256 lp2Token1 = positionManager.depositLiquidity(key, -180, 0, 5000, 2500, 2500, LP2);
//         uint256 lp2Token2 = positionManager.depositLiquidity(key, 0, 180, 5000, 2500, 2500, LP2);
//         console.log("LP2 (Moderate): Two medium positions, 5000 each");

//         // LP3: Aggressive - Multiple concentrated positions
//         positionManager.depositLiquidity(key, -90, -30, 3000, 1500, 1500, LP3); // uint256 lp3Token1
//         uint256 lp3Token2 = positionManager.depositLiquidity(key, -30, 30, 6000, 3000, 3000, LP3);
//         positionManager.depositLiquidity(key, 30, 90, 3000, 1500, 1500, LP3); // uint256 lp3Token3
//         console.log("LP3 (Aggressive): Three concentrated positions, 12000 total liquidity");

//         console.log("\nCurrent State:");
//         console.log("  LP1 total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP1));
//         console.log("  LP2 total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP2));
//         console.log("  LP3 total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP3));
//         console.log("  Total registered LPs: %s", positionManager.getPoolLPs(key).length);

//         console.log("\nPhase 2: Swap Simulation - Fee Accumulation");
//         console.log("------------------------------------------");

//         // Simulate fees from swaps
//         positionManager.updatePositionFees(key.toId(), LP1, lp1Token1, 120, 140);
//         positionManager.updatePositionFees(key.toId(), LP2, lp2Token1, 80, 90);
//         positionManager.updatePositionFees(key.toId(), LP2, lp2Token2, 70, 85);
//         positionManager.updatePositionFees(key.toId(), LP3, lp3Token2, 200, 220); // Concentrated position earns more
//         console.log("Fees accumulated across all positions");

//         console.log("\nPhase 3: LP Strategy Adjustments");
//         console.log("-------------------------------");

//         // LP1 removes some liquidity (risk management)
//         positionManager.removeLiquidity(key, lp1Token1, 2000, LP1);
//         console.log("LP1 reduced exposure: removed 2000 liquidity");

//         // LP2 removes one position entirely
//         positionManager.removeLiquidity(key, lp2Token1, 5000, LP2);
//         console.log("LP2 removed lower position completely");

//         // LP3 adds more to concentrated position
//         uint256 lp3Token4 = positionManager.depositLiquidity(key, -30, 30, 4000, 2000, 2000, LP3);
//         console.log("LP3 increased concentrated position: added 4000 liquidity");

//         console.log("\nPhase 4: More Trading Activity");
//         console.log("-----------------------------");

//         // More fee accumulation
//         positionManager.updatePositionFees(key.toId(), LP1, lp1Token1, 60, 70);
//         positionManager.updatePositionFees(key.toId(), LP2, lp2Token2, 90, 100);
//         positionManager.updatePositionFees(key.toId(), LP3, lp3Token2, 150, 170);
//         positionManager.updatePositionFees(key.toId(), LP3, lp3Token4, 180, 200);
//         console.log("Additional fees accumulated");

//         console.log("\nPhase 5: Final State Analysis");
//         console.log("----------------------------");

//         // Get final positions
//         LPPositionManager.LPPosition[] memory lp1Positions = positionManager.getLPPositions(key, LP1);
//         LPPositionManager.LPPosition[] memory lp2Positions = positionManager.getLPPositions(key, LP2);
//         LPPositionManager.LPPosition[] memory lp3Positions = positionManager.getLPPositions(key, LP3);

//         console.log("\nLP1 Final State:");
//         console.log("  Active positions: 1");
//         console.log("  Total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP1));
//         console.log(
//             "  Uncollected fees: %s token0, %s token1",
//             lp1Positions[0].uncollectedFees0,
//             lp1Positions[0].uncollectedFees1
//         );

//         console.log("\nLP2 Final State:");
//         console.log("  Active positions: 1 (removed 1)");
//         console.log("  Total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP2));
//         uint256 lp2ActivePos = 0;
//         for (uint256 i = 0; i < lp2Positions.length; i++) {
//             if (lp2Positions[i].isActive) {
//                 console.log(
//                     "  Position %s fees: %s token0, %s token1",
//                     i + 1,
//                     lp2Positions[i].uncollectedFees0,
//                     lp2Positions[i].uncollectedFees1
//                 );
//                 lp2ActivePos++;
//             }
//         }

//         console.log("\nLP3 Final State:");
//         console.log("  Active positions: 4");
//         console.log("  Total liquidity: %s", positionManager.getTotalLiquidity(key.toId(), LP3));
//         console.log("  Concentrated position fees:");
//         for (uint256 i = 0; i < lp3Positions.length; i++) {
//             if (lp3Positions[i].isActive && lp3Positions[i].tickLower == -30 && lp3Positions[i].tickUpper == 30) {
//                 console.log(
//                     "    Position %s: %s token0, %s token1",
//                     i + 1,
//                     lp3Positions[i].uncollectedFees0,
//                     lp3Positions[i].uncollectedFees1
//                 );
//             }
//         }

//         console.log("\nPool Statistics:");
//         console.log("  Total LPs: %s", positionManager.getPoolLPs(key).length);
//         console.log("  LP1 positions: %s", lp1Positions.length);
//         console.log("  LP2 positions: %s", lp2Positions.length);
//         console.log("  LP3 positions: %s", lp3Positions.length);

//         vm.stopPrank();

//         // Verify key metrics
//         assertEq(positionManager.getPoolLPs(key).length, 3, "Should have 3 LPs");
//         assertGt(positionManager.getTotalLiquidity(key.toId(), LP1), 0, "LP1 should have liquidity");
//         assertGt(positionManager.getTotalLiquidity(key.toId(), LP2), 0, "LP2 should have liquidity");
//         assertGt(positionManager.getTotalLiquidity(key.toId(), LP3), 0, "LP3 should have liquidity");

//         console.log("\nIntegration scenario completed successfully");
//         console.log("Demonstrated: Multiple strategies, dynamic adjustments, fee tracking");
//         console.log("");
//     }
// }
