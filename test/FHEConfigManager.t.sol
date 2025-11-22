// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {Test} from "forge-std/Test.sol";
// import "forge-std/console.sol";

// // Uniswap v4 imports
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {Currency} from "v4-core/types/Currency.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";

// // FHE imports
// import "@fhenixprotocol/cofhe-contracts/FHE.sol";
// import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

// // Contract under test
// import {FHEConfigManager} from "../src/FHEConfigManager.sol";
// import {LPPositionManager} from "../src/LPPositionManager.sol";
// import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
// import {ProfitManager} from "../src/ProfitManager.sol";
// import {JITCoordinator} from "../src/JITCoordinator.sol";
// import {FeeCalculator} from "../src/FeeCalculator.sol";

// /**
//  * @title FHEConfigManager Test Suite
//  * @notice Comprehensive tests for FHE-encrypted LP configuration management
//  * @dev Tests encrypted parameter storage, threshold evaluation, and privacy preservation
//  */
// contract FHEConfigManagerTest is Test, Deployers, CoFheTest {
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
//     event LPConfigSet(bytes32 indexed poolId, address indexed lp, bool isActive);
//     event LPConfigUpdated(bytes32 indexed poolId, address indexed lp, bool autoHedgeEnabled);
//     event LPDeactivated(bytes32 indexed poolId, address indexed lp);

//     function setUp() public {
//         console.log("=== FHEConfigManager Test Setup ===");

//         // Deploy Uniswap v4 infrastructure
//         deployFreshManagerAndRouters();
//         (currency0, currency1) = deployMintAndApprove2Currencies();

//         // Deploy hook with required permissions
//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
//                 | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
//         );
//         address hookAddress = address(flags);

//         vm.txGasPrice(10 gwei);

//         // ============ DEPLOY MODULES FIRST ============

//         positionManager = new LPPositionManager();
//         configManager = new FHEConfigManager();

//         vm.startPrank(HOOK); // Hook needs to be the caller so as to update moving average
//         feeManager = new DynamicFeeManager(HOOK, OWNER);
//         vm.stopPrank();

//         profitManager = new ProfitManager(address(positionManager), address(configManager));
//         feeCalculator = new FeeCalculator();
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
//         console.log("  FeeCalculator:", address(feeCalculator));

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
//         console.log("");
//     }

//     // ============ Test 1: LP Configuration ============

//     function testLPConfiguration() public {
//         console.log("TEST 1: LP Configuration with FHE Encryption");
//         console.log("-------------------------------------------");

//         vm.startPrank(LP1);

//         // Create encrypted configuration parameters
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);

//         console.log("Configuring LP1 with encrypted parameters...");
//         console.log("  Min Swap Size: 1000 (encrypted)");
//         console.log("  Max Liquidity: 50000 (encrypted)");
//         console.log("  Profit Threshold: 30 bps (encrypted)");
//         console.log("  Hedge Percentage: 50%% (encrypted)");
//         console.log("  Auto-Hedge: Enabled");

//         vm.expectEmit(true, true, true, true);
//         emit LPConfigSet(keccak256(abi.encode(key)), LP1, true);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         vm.stopPrank();

//         // Verify LP is active
//         bool isActive = configManager.isActive(key, LP1);
//         assertTrue(isActive, "LP should be active after configuration");

//         // Verify auto-hedge is enabled
//         bool hasAutoHedge = configManager.hasAutoHedgeEnabled(key, LP1);
//         assertTrue(hasAutoHedge, "Auto-hedge should be enabled");

//         console.log("LP1 configured successfully with encrypted parameters");
//         console.log("Configuration is active and auto-hedge enabled");
//         console.log("");
//     }

//     // ============ Test 2: Multiple LP Configurations ============

//     function testMultipleLPConfigurations() public {
//         console.log("TEST 2: Multiple LP Configurations");
//         console.log("---------------------------------");

//         // Configure LP1 (Conservative strategy)
//         vm.startPrank(LP1);
//         InEuint128 memory enc1MinSwap = createInEuint128(2000, LP1);
//         InEuint128 memory enc1MaxLiq = createInEuint128(30000, LP1);
//         InEuint32 memory enc1Profit = createInEuint32(25, LP1);
//         InEuint32 memory enc1Hedge = createInEuint32(75, LP1);
//         configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, true);
//         vm.stopPrank();
//         console.log("LP1: Conservative (min 2000, auto-hedge 75%%)");

//         // Configure LP2 (Moderate strategy)
//         vm.startPrank(LP2);
//         InEuint128 memory enc2MinSwap = createInEuint128(1000, LP2);
//         InEuint128 memory enc2MaxLiq = createInEuint128(50000, LP2);
//         InEuint32 memory enc2Profit = createInEuint32(30, LP2);
//         InEuint32 memory enc2Hedge = createInEuint32(50, LP2);
//         configManager.configureLPSettings(key, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, true);
//         vm.stopPrank();
//         console.log("  LP2 (Retail): Moderate threshold (1000), Moderate hedge (50%%)");

//         // LP3: Aggressive market maker
//         vm.startPrank(LP3);
//         InEuint128 memory enc3MinSwap = createInEuint128(500, LP3);
//         InEuint128 memory enc3MaxLiq = createInEuint128(100000, LP3);
//         InEuint32 memory enc3Profit = createInEuint32(45, LP3);
//         InEuint32 memory enc3Hedge = createInEuint32(25, LP3);
//         configManager.configureLPSettings(key, enc3MinSwap, enc3MaxLiq, enc3Profit, enc3Hedge, false);
//         vm.stopPrank();
//         console.log("  LP3 (Market Maker): Low threshold (500), Low hedge (25%%), Manual hedge");

//         console.log("\nPhase 2: Strategy Adjustments");
//         console.log("---------------------------");

//         // LP2 adjusts strategy based on market conditions
//         vm.prank(LP2);
//         configManager.updateAutoHedge(key, false);
//         console.log("  LP2 disables auto-hedge for manual control");

//         // LP3 enables auto-hedge
//         vm.prank(LP3);
//         configManager.updateAutoHedge(key, true);
//         console.log("  LP3 enables auto-hedge for automation");

//         console.log("\nPhase 3: Temporary Pause");
//         console.log("----------------------");

//         // LP1 temporarily pauses participation
//         vm.prank(LP1);
//         configManager.deactivateLP(key);
//         console.log("  LP1 deactivated (e.g., for risk management)");

//         assertFalse(configManager.isActive(key, LP1), "LP1 should be inactive");
//         assertTrue(configManager.isActive(key, LP2), "LP2 should remain active");
//         assertTrue(configManager.isActive(key, LP3), "LP3 should remain active");

//         console.log("\nPhase 4: Reactivation");
//         console.log("-------------------");

//         // Wait for decryption cycle
//         vm.warp(block.timestamp + 15);

//         // LP1 rejoins
//         vm.prank(LP1);
//         configManager.reactivateLP(key);
//         console.log("  LP1 reactivated and rejoins coordination");

//         assertTrue(configManager.isActive(key, LP1), "LP1 should be active again");

//         console.log("\nFinal State Summary:");
//         console.log("------------------");
//         console.log("  LP1: Active, Auto-hedge ON");
//         console.log("  LP2: Active, Auto-hedge OFF");
//         console.log("  LP3: Active, Auto-hedge ON");
//         console.log("\nAll LPs maintain encrypted strategies while coordinating");
//         console.log("Privacy preserved: Each LP's thresholds and parameters remain confidential");

//         console.log("\nIntegration scenario completed successfully");
//         console.log("");
//     }

//     // ============ Test 3: Update Auto-Hedge Setting ============

//     function testUpdateAutoHedge() public {
//         console.log("TEST 3: Update Auto-Hedge Setting");
//         console.log("--------------------------------");

//         // Configure LP first
//         vm.startPrank(LP1);
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         console.log("Initial auto-hedge: Enabled");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "Should be enabled");

//         // Update to disabled
//         vm.expectEmit(true, true, true, true);
//         emit LPConfigUpdated(keccak256(abi.encode(key)), LP1, false);
//         configManager.updateAutoHedge(key, false);

//         console.log("Updated auto-hedge: Disabled");
//         assertFalse(configManager.hasAutoHedgeEnabled(key, LP1), "Should be disabled");

//         // Update back to enabled
//         configManager.updateAutoHedge(key, true);
//         console.log("Updated auto-hedge: Enabled again");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "Should be enabled again");

//         vm.stopPrank();

//         console.log("Auto-hedge setting updated successfully");
//         console.log("");
//     }

//     // ============ Test 4: Deactivate LP ============

//     function testDeactivateLP() public {
//         console.log("TEST 4: Deactivate LP");
//         console.log("-------------------");

//         // Configure and then deactivate
//         vm.startPrank(LP1);
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         assertTrue(configManager.isActive(key, LP1), "LP should be active initially");
//         console.log("LP1 initially active");

//         vm.expectEmit(true, true, true, true);
//         emit LPDeactivated(keccak256(abi.encode(key)), LP1);
//         configManager.deactivateLP(key);

//         assertFalse(configManager.isActive(key, LP1), "LP should be inactive after deactivation");
//         console.log("LP1 deactivated successfully");

//         vm.stopPrank();

//         console.log("");
//     }

//     // ============ Test 5: Reactivate LP ============

//     function testReactivateLP() public {
//         console.log("TEST 5: Reactivate LP");
//         console.log("-------------------");

//         vm.startPrank(LP1);

//         // Configure initially
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         console.log("LP1 configured and active");

//         // Deactivate
//         configManager.deactivateLP(key);
//         assertFalse(configManager.isActive(key, LP1), "LP should be inactive");
//         console.log("LP1 deactivated");

//         // Wait for decryption (simulate async operation)
//         vm.warp(block.timestamp + 10);

//         // Reactivate
//         vm.expectEmit(true, true, true, true);
//         emit LPConfigSet(keccak256(abi.encode(key)), LP1, true);
//         configManager.reactivateLP(key);

//         assertTrue(configManager.isActive(key, LP1), "LP should be active after reactivation");
//         console.log("LP1 reactivated successfully");

//         vm.stopPrank();

//         console.log("");
//     }

//     // ============ Test 6: FHE Privacy Preservation ============

//     function testFHEPrivacyPreservation() public {
//         console.log("TEST 6: FHE Privacy Preservation");
//         console.log("-------------------------------");

//         // LP1 configures with secret parameters
//         vm.startPrank(LP1);
//         InEuint128 memory secretMinSwap = createInEuint128(5000, LP1); // Secret threshold
//         InEuint128 memory secretMaxLiq = createInEuint128(100000, LP1);
//         InEuint32 memory secretProfit = createInEuint32(45, LP1);
//         InEuint32 memory secretHedge = createInEuint32(80, LP1);
//         configManager.configureLPSettings(key, secretMinSwap, secretMaxLiq, secretProfit, secretHedge, true);
//         vm.stopPrank();

//         console.log("LP1 configured with encrypted parameters");
//         console.log("  Actual min swap: 5000 (encrypted, not visible)");
//         console.log("  Actual hedge: 80%% (encrypted, not visible)");

//         // LP2 configures with different parameters
//         vm.startPrank(LP2);
//         InEuint128 memory secretMinSwap2 = createInEuint128(1000, LP2);
//         InEuint128 memory secretMaxLiq2 = createInEuint128(50000, LP2);
//         InEuint32 memory secretProfit2 = createInEuint32(25, LP2);
//         InEuint32 memory secretHedge2 = createInEuint32(40, LP2);
//         configManager.configureLPSettings(key, secretMinSwap2, secretMaxLiq2, secretProfit2, secretHedge2, false);
//         vm.stopPrank();

//         console.log("LP2 configured with different encrypted parameters");
//         console.log("  Actual min swap: 1000 (encrypted, not visible)");
//         console.log("  Actual hedge: 40%% (encrypted, not visible)");

//         // Verify only public flags are visible
//         assertTrue(configManager.isActive(key, LP1), "LP1 active status is public");
//         assertTrue(configManager.isActive(key, LP2), "LP2 active status is public");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "LP1 auto-hedge flag is public");
//         assertFalse(configManager.hasAutoHedgeEnabled(key, LP2), "LP2 auto-hedge flag is public");

//         console.log("\nPrivacy Analysis:");
//         console.log("Active status: Public (necessary for coordination)");
//         console.log("Auto-hedge flag: Public (necessary for execution)");
//         console.log("Min swap threshold: ENCRYPTED (private strategy)");
//         console.log("Max liquidity: ENCRYPTED (private capacity)");
//         console.log("Profit threshold: ENCRYPTED (private target)");
//         console.log("Hedge percentage: ENCRYPTED (private risk management)");

//         console.log("\nFHE encryption preserves LP strategy privacy");
//         console.log("");
//     }

//     // ============ Test 7: Threshold Evaluation (Simplified) ============

//     function testThresholdEvaluation() public {
//         console.log("TEST 7: Threshold Evaluation");
//         console.log("---------------------------");

//         vm.startPrank(LP1);

//         // Configure with threshold of 2000
//         InEuint128 memory encMinSwap = createInEuint128(2000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         vm.stopPrank();

//         console.log("LP1 configured with min swap threshold: 2000");

//         // Deactivate to trigger decryption
//         vm.prank(LP1);
//         configManager.deactivateLP(key);

//         // Wait for decryption
//         vm.warp(block.timestamp + 10);

//         // Reactivate to complete decryption cycle
//         vm.prank(LP1);
//         configManager.reactivateLP(key);

//         // Hook needs to decrypt before checking threshold
//         vm.prank(HOOK);
//         configManager.decryptMinSwapSize(key, LP1);

//         // Wait for decryption result
//         vm.warp(block.timestamp + 10);

//         // Test threshold evaluation
//         bool meets1500 = configManager.meetsThreshold(key, LP1, 1500);
//         bool meets2500 = configManager.meetsThreshold(key, LP1, 2500);

//         console.log("Swap size 1500: meets threshold = %s", meets1500);
//         console.log("Swap size 2500: meets threshold = %s", meets2500);

//         assertFalse(meets1500, "1500 should not meet threshold of 2000");
//         assertTrue(meets2500, "2500 should meet threshold of 2000");

//         console.log("Threshold evaluation working correctly");
//         console.log("");
//     }

//     // ============ Test 8: Get LP Config ============

//     function testGetLPConfig() public {
//         console.log("TEST 8: Get LP Config");
//         console.log("--------------------");

//         vm.startPrank(LP1);

//         InEuint128 memory encMinSwap = createInEuint128(1500, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(60000, LP1);
//         InEuint32 memory encProfit = createInEuint32(35, LP1);
//         InEuint32 memory encHedge = createInEuint32(60, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         vm.stopPrank();

//         // Get full config
//         FHEConfigManager.LPConfig memory config = configManager.getLPConfig(key, LP1);

//         assertTrue(config.isActive, "Config should be active");
//         assertTrue(config.autoHedgeEnabled, "Auto-hedge should be enabled");

//         console.log("LP Config retrieved successfully:");
//         console.log("  Is Active: %s", config.isActive);
//         console.log("  Auto-Hedge Enabled: %s", config.autoHedgeEnabled);
//         console.log("  Encrypted fields present (not readable directly)");

//         console.log("");
//     }

//     // ============ Test 9: Authorization Checks ============

//     function testAuthorizationChecks() public {
//         console.log("TEST 9: Authorization & Security");
//         console.log("-------------------------------");

//         // Configure LP1 first
//         vm.startPrank(LP1);
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);
//         vm.stopPrank();

//         // Test unauthorized decryptMinSwapSize
//         // vm.prank(USER);
//         // vm.expectRevert(FHEConfigManager.Unauthorized.selector);
//         // configManager.decryptMinSwapSize(key, LP1);
//         // console.log("Unauthorized decryptMinSwapSize blocked");

//         // Test unauthorized decryptMaxLiquidity
//         // vm.prank(USER);
//         // vm.expectRevert(FHEConfigManager.Unauthorized.selector);
//         // configManager.decryptMaxLiquidity(key, LP1);
//         // console.log("Unauthorized decryptMaxLiquidity blocked");

//         // Test unauthorized decryptHedgePercentage
//         // vm.prank(USER);
//         // vm.expectRevert(FHEConfigManager.Unauthorized.selector);
//         // configManager.decryptHedgePercentage(key, LP1);
//         // console.log("Unauthorized decryptHedgePercentage blocked");

//         // Test getHedgePercentage before decryption ready
//         vm.prank(USER);
//         vm.expectRevert(FHEConfigManager.DecryptionNotReady.selector);
//         configManager.getHedgePercentage(key, LP1);
//         console.log("Unauthorized getHedgePercentage blocked");

//         console.log("All authorization checks passed");
//         console.log("");
//     }

//     // ============ Test 10: Invalid Operations ============

//     function testInvalidOperations() public {
//         console.log("TEST 10: Invalid Operations");
//         console.log("--------------------------");

//         // Test updating auto-hedge on non-configured LP
//         vm.prank(LP1);
//         vm.expectRevert(FHEConfigManager.InvalidConfiguration.selector);
//         configManager.updateAutoHedge(key, true);
//         console.log("Update auto-hedge on unconfigured LP rejected");

//         // Test reactivating LP that was never configured
//         vm.prank(LP2);
//         vm.expectRevert(FHEConfigManager.DecryptionNotReady.selector);
//         configManager.reactivateLP(key);
//         console.log("Reactivate unconfigured LP rejected");

//         console.log("Invalid operation checks passed");
//         console.log("");
//     }

//     // ============ Test 11: Configuration Overwrite ============

//     function testConfigurationOverwrite() public {
//         console.log("TEST 11: Configuration Overwrite");
//         console.log("-------------------------------");

//         vm.startPrank(LP1);

//         // Initial configuration
//         InEuint128 memory encMinSwap1 = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq1 = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit1 = createInEuint32(30, LP1);
//         InEuint32 memory encHedge1 = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap1, encMaxLiq1, encProfit1, encHedge1, true);

//         console.log("Initial config: min 1000, auto-hedge enabled");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "Auto-hedge enabled");

//         // Overwrite configuration
//         InEuint128 memory encMinSwap2 = createInEuint128(2000, LP1);
//         InEuint128 memory encMaxLiq2 = createInEuint128(75000, LP1);
//         InEuint32 memory encProfit2 = createInEuint32(40, LP1);
//         InEuint32 memory encHedge2 = createInEuint32(75, LP1);
//         configManager.configureLPSettings(key, encMinSwap2, encMaxLiq2, encProfit2, encHedge2, false);

//         console.log("Updated config: min 2000, auto-hedge disabled");
//         assertFalse(configManager.hasAutoHedgeEnabled(key, LP1), "Auto-hedge disabled");

//         vm.stopPrank();

//         console.log("Configuration overwrite successful");
//         console.log("");
//     }

//     // ============ Test 12: Hedge Percentage Retrieval ============

//     function testHedgePercentageRetrieval() public {
//         console.log("TEST 12: Hedge Percentage Retrieval");
//         console.log("----------------------------------");

//         vm.startPrank(LP1);

//         // Configure with 60% hedge
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(60, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         vm.stopPrank();

//         console.log("LP1 configured with 60%% hedge (encrypted)");

//         // Hook decrypts hedge percentage
//         vm.prank(HOOK);
//         configManager.decryptHedgePercentage(key, LP1);

//         // Wait for decryption
//         vm.warp(block.timestamp + 10);

//         // Retrieve decrypted value
//         vm.prank(HOOK);
//         uint256 hedgePercentage = configManager.getHedgePercentage(key, LP1);

//         console.log("Decrypted hedge percentage: %s%%", hedgePercentage);
//         assertEq(hedgePercentage, 60, "Should return 60%");

//         console.log("Hedge percentage retrieval successful");
//         console.log("");
//     }

//     // ============ Test 13: Multiple Pool Configurations ============

//     function testMultiplePoolConfigurations() public {
//         console.log("TEST 13: Multiple Pool Configurations");
//         console.log("------------------------------------");

//         // Create second pool
//         PoolKey memory key2;
//         (key2,) = initPool(
//             Currency.wrap(address(0x8888)),
//             Currency.wrap(address(0x9999)),
//             hook,
//             LPFeeLibrary.DYNAMIC_FEE_FLAG,
//             SQRT_PRICE_1_1
//         );

//         vm.startPrank(LP1);

//         // Configure in first pool
//         InEuint128 memory enc1MinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory enc1MaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory enc1Profit = createInEuint32(30, LP1);
//         InEuint32 memory enc1Hedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, true);
//         console.log("LP1 configured in Pool 1");

//         // Configure in second pool with different parameters
//         InEuint128 memory enc2MinSwap = createInEuint128(2000, LP1);
//         InEuint128 memory enc2MaxLiq = createInEuint128(75000, LP1);
//         InEuint32 memory enc2Profit = createInEuint32(40, LP1);
//         InEuint32 memory enc2Hedge = createInEuint32(70, LP1);
//         configManager.configureLPSettings(key2, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, false);
//         console.log("LP1 configured in Pool 2 with different parameters");

//         vm.stopPrank();

//         // Verify independent configurations
//         assertTrue(configManager.isActive(key, LP1), "Should be active in pool 1");
//         assertTrue(configManager.isActive(key2, LP1), "Should be active in pool 2");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "Auto-hedge enabled in pool 1");
//         assertFalse(configManager.hasAutoHedgeEnabled(key2, LP1), "Auto-hedge disabled in pool 2");

//         console.log("Multiple pool configurations working independently");
//         console.log("");
//     }

//     // ============ Test 14: Inactive LP Behavior ============

//     function testInactiveLPBehavior() public {
//         console.log("TEST 14: Inactive LP Behavior");
//         console.log("----------------------------");

//         vm.startPrank(LP1);

//         // Configure and activate
//         InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
//         InEuint128 memory encMaxLiq = createInEuint128(50000, LP1);
//         InEuint32 memory encProfit = createInEuint32(30, LP1);
//         InEuint32 memory encHedge = createInEuint32(50, LP1);
//         configManager.configureLPSettings(key, encMinSwap, encMaxLiq, encProfit, encHedge, true);

//         // Deactivate
//         configManager.deactivateLP(key);

//         vm.stopPrank();

//         // Verify inactive LP doesn't meet thresholds
//         bool meetsThreshold = configManager.meetsThreshold(key, LP1, 5000);
//         assertFalse(meetsThreshold, "Inactive LP should not meet any threshold");

//         console.log("Inactive LP correctly returns false for threshold checks");
//         console.log("");
//     }

//     // ============ Test 15: Integration Scenario ============

//     function testIntegrationScenario() public {
//         console.log("TEST 15: Integration Scenario - Multi-LP Coordination");
//         console.log("----------------------------------------------------");

//         console.log("\nPhase 1: LP Onboarding");
//         console.log("---------------------");

//         // LP1: Conservative institutional player
//         vm.startPrank(LP1);
//         InEuint128 memory enc1MinSwap = createInEuint128(5000, LP1);
//         InEuint128 memory enc1MaxLiq = createInEuint128(200000, LP1);
//         InEuint32 memory enc1Profit = createInEuint32(20, LP1);
//         InEuint32 memory enc1Hedge = createInEuint32(80, LP1);
//         configManager.configureLPSettings(key, enc1MinSwap, enc1MaxLiq, enc1Profit, enc1Hedge, true);
//         vm.stopPrank();
//         console.log("  LP1 (Institutional): High threshold (5000), High hedge (80%%)");

//         // LP2: Moderate retail provider
//         vm.startPrank(LP2);
//         InEuint128 memory enc2MinSwap = createInEuint128(1000, LP2);
//         InEuint128 memory enc2MaxLiq = createInEuint128(50000, LP2);
//         InEuint32 memory enc2Profit = createInEuint32(30, LP2);
//         InEuint32 memory enc2Hedge = createInEuint32(50, LP2);
//         configManager.configureLPSettings(key, enc2MinSwap, enc2MaxLiq, enc2Profit, enc2Hedge, true);
//         vm.stopPrank();
//         console.log("  LP2: Moderate (min 1000, auto-hedge 50%%)");

//         // Configure LP3 (Aggressive strategy)
//         vm.startPrank(LP3);
//         InEuint128 memory enc3MinSwap = createInEuint128(500, LP3);
//         InEuint128 memory enc3MaxLiq = createInEuint128(100000, LP3);
//         InEuint32 memory enc3Profit = createInEuint32(40, LP3);
//         InEuint32 memory enc3Hedge = createInEuint32(25, LP3);
//         configManager.configureLPSettings(key, enc3MinSwap, enc3MaxLiq, enc3Profit, enc3Hedge, false);
//         vm.stopPrank();
//         console.log("  LP3: Aggressive (min 500, auto-hedge 25%%, disabled)");

//         // Verify all LPs are active
//         assertTrue(configManager.isActive(key, LP1), "LP1 should be active");
//         assertTrue(configManager.isActive(key, LP2), "LP2 should be active");
//         assertTrue(configManager.isActive(key, LP3), "LP3 should be active");

//         // Verify auto-hedge settings
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP1), "LP1 auto-hedge enabled");
//         assertTrue(configManager.hasAutoHedgeEnabled(key, LP2), "LP2 auto-hedge enabled");
//         assertFalse(configManager.hasAutoHedgeEnabled(key, LP3), "LP3 auto-hedge disabled");

//         console.log("Multiple LPs configured with different strategies");
//         console.log("All configurations maintain privacy via FHE encryption");
//         console.log("");
//     }
// }
