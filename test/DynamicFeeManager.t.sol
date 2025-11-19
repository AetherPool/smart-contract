// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";

/**
 * @title DynamicFeeManager Test Suite
 * @notice Comprehensive tests for gas-based dynamic fee calculations
 * @dev Tests fee tiers, moving averages, threshold logic, and admin controls
 */
contract DynamicFeeManagerTest is Test {
    // ============ Test Setup ============
    DynamicFeeManager public feeManager;

    address public constant HOOK = address(0x1111);
    address public constant OWNER = address(0x2222);
    address public constant USER = address(0x3333);

    // Gas price scenarios
    uint256 public constant BASE_GAS = 10 gwei;
    uint256 public constant LOW_GAS = 5 gwei;
    uint256 public constant HIGH_GAS = 15 gwei;
    uint256 public constant EXTREME_LOW_GAS = 2 gwei;
    uint256 public constant EXTREME_HIGH_GAS = 25 gwei;

    // Events for tracking
    event FeeCalculated(uint24 fee, uint128 currentGasPrice, uint128 movingAverage, DynamicFeeManager.FeeLevel level);
    event FeeParametersUpdated(uint24 baseFee, uint24 highGasFee, uint24 lowGasFee);
    event ThresholdsUpdated(uint256 highGasThreshold, uint256 lowGasThreshold);
    event MovingAverageUpdated(uint128 newAverage, uint104 count);

    function setUp() public {
        console.log("=== DynamicFeeManager Test Setup ===");

        // Deploy fee manager
        vm.txGasPrice(BASE_GAS);
        vm.prank(HOOK);
        feeManager = new DynamicFeeManager(HOOK, OWNER);

        console.log("DynamicFeeManager deployed at:", address(feeManager));
        console.log("Hook address:", HOOK);
        console.log("Owner address:", OWNER);
        console.log("");
    }

    // ============ Test 1: Initialization ============

    function testInitialization() public view {
        console.log("TEST 1: Initialization");
        console.log("---------------------");

        // Check initial parameters
        assertEq(feeManager.hook(), HOOK, "Hook should be set");
        assertEq(feeManager.owner(), OWNER, "Owner should be set");
        assertEq(feeManager.baseFee(), 3000, "Base fee should be 3000");
        assertEq(feeManager.highGasFee(), 1500, "High gas fee should be 1500");
        assertEq(feeManager.lowGasFee(), 6000, "Low gas fee should be 6000");
        assertEq(feeManager.highGasThreshold(), 110, "High gas threshold should be 110%");
        assertEq(feeManager.lowGasThreshold(), 90, "Low gas threshold should be 90%");

        // Check moving average was initialized
        (uint128 average, uint104 count) = feeManager.getMovingAverageData();
        assertGt(average, 0, "Moving average should be initialized");
        assertEq(count, 1, "Count should be 1 after initialization");

        console.log("Initialization successful");
        console.log("");
    }

    // ============ Test 2: Base Fee Calculation ============

    function testBaseFeeCalculation() public {
        console.log("TEST 2: Base Fee Calculation");
        console.log("---------------------------");

        vm.txGasPrice(BASE_GAS);

        vm.prank(HOOK);
        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        console.log("Gas price: %s gwei", BASE_GAS / 1e9);
        console.log("Fee returned: %s", fee);
        console.log("Fee level: %s", uint256(level));

        assertEq(fee, 3000, "Should return base fee at normal gas");
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.NORMAL), "Should be NORMAL level");

        console.log("Base fee calculation working correctly");
        console.log("");
    }

    // ============ Test 3: High Gas Fee (Low Fee) ============

    function testHighGasLowFee() public {
        console.log("TEST 3: High Gas (Low Fee to Incentivize Trading)");
        console.log("------------------------------------------------");

        // Set high gas price (above 110% of moving average)
        vm.txGasPrice(EXTREME_HIGH_GAS);

        vm.prank(HOOK);
        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        console.log("Gas price: %s gwei", EXTREME_HIGH_GAS / 1e9);
        console.log("Fee returned: %s (0.15%%)", fee);
        console.log("Fee level: %s", uint256(level));

        assertEq(fee, 1500, "Should return low fee during high gas");
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.HIGH_GAS), "Should be HIGH_GAS level");

        console.log("High gas / low fee working correctly");
        console.log("");
    }

    // ============ Test 4: Low Gas Fee (High Fee) ============

    function testLowGasHighFee() public {
        console.log("TEST 4: Low Gas (High Fee to Maximize LP Returns)");
        console.log("------------------------------------------------");

        // Set low gas price (below 90% of moving average)
        vm.txGasPrice(EXTREME_LOW_GAS);

        vm.prank(HOOK);
        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        console.log("Gas price: %s gwei", EXTREME_LOW_GAS / 1e9);
        console.log("Fee returned: %s (0.6%%)", fee);
        console.log("Fee level: %s", uint256(level));

        assertEq(fee, 6000, "Should return high fee during low gas");
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.LOW_GAS), "Should be LOW_GAS level");

        console.log("Low gas / high fee working correctly");
        console.log("");
    }

    // ============ Test 5: Moving Average Updates ============

    function testMovingAverageUpdates() public {
        console.log("TEST 5: Moving Average Updates");
        console.log("------------------------------");

        (uint128 initialAverage, uint104 initialCount) = feeManager.getMovingAverageData();
        console.log("Initial average: %s gwei", initialAverage / 1e9);
        console.log("Initial count: %s", initialCount);

        // Simulate multiple swaps with different gas prices
        uint256[] memory gasPrices = new uint256[](5);
        gasPrices[0] = 8 gwei;
        gasPrices[1] = 10 gwei;
        gasPrices[2] = 12 gwei;
        gasPrices[3] = 9 gwei;
        gasPrices[4] = 11 gwei;

        for (uint256 i = 0; i < gasPrices.length; i++) {
            vm.txGasPrice(gasPrices[i]);
            vm.prank(HOOK);
            feeManager.updateMovingAverage();
        }

        (uint128 finalAverage, uint104 finalCount) = feeManager.getMovingAverageData();
        console.log("Final average: %s gwei", finalAverage / 1e9);
        console.log("Final count: %s", finalCount);

        assertGt(finalCount, initialCount, "Count should increase");
        assertGt(finalAverage, 0, "Average should be positive");

        console.log("Moving average updates working correctly");
        console.log("");
    }

    // ============ Test 6: Fee Transitions ============

    function testFeeTransitions() public {
        console.log("TEST 6: Fee Level Transitions");
        console.log("-----------------------------");

        // Build up a stable moving average
        for (uint256 i = 0; i < 10; i++) {
            vm.txGasPrice(10 gwei);
            vm.prank(HOOK);
            feeManager.updateMovingAverage();
        }

        (uint128 average,) = feeManager.getMovingAverageData();
        console.log("Stable moving average: %s gwei", average / 1e9);

        // Test LOW_GAS level (high fee)
        vm.txGasPrice(7 gwei); // Below 90% of ~10 gwei
        vm.prank(HOOK);
        (uint24 fee1, DynamicFeeManager.FeeLevel level1) = feeManager.getFee();
        console.log("Low gas (7 gwei) -> Fee: %s, Level: %s", fee1, uint256(level1));
        assertEq(fee1, 6000, "Should be high fee");

        // Test NORMAL level
        vm.txGasPrice(10 gwei); // Between 90% and 110%
        vm.prank(HOOK);
        (uint24 fee2, DynamicFeeManager.FeeLevel level2) = feeManager.getFee();
        console.log("Normal gas (10 gwei) -> Fee: %s, Level: %s", fee2, uint256(level2));
        assertEq(fee2, 3000, "Should be base fee");

        // Test HIGH_GAS level (low fee)
        vm.txGasPrice(13 gwei); // Above 110% of ~10 gwei
        vm.prank(HOOK);
        (uint24 fee3, DynamicFeeManager.FeeLevel level3) = feeManager.getFee();
        console.log("High gas (13 gwei) -> Fee: %s, Level: %s", fee3, uint256(level3));
        assertEq(fee3, 1500, "Should be low fee");

        console.log("Fee transitions working correctly");
        console.log("");
    }

    // ============ Test 7: View Function (getCurrentFee) ============

    function testGetCurrentFeeView() public {
        console.log("TEST 7: View Function getCurrentFee");
        console.log("-----------------------------------");

        // Build stable average
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(10 gwei);
            vm.prank(HOOK);
            feeManager.updateMovingAverage();
        }

        // Test view function (doesn't update state)
        vm.txGasPrice(15 gwei);
        (uint24 viewFee, DynamicFeeManager.FeeLevel viewLevel) = feeManager.getCurrentFee();

        console.log("View function fee: %s", viewFee);
        console.log("View function level: %s", uint256(viewLevel));

        assertEq(viewFee, 1500, "View should return low fee for high gas");
        assertEq(uint256(viewLevel), uint256(DynamicFeeManager.FeeLevel.HIGH_GAS), "Should be HIGH_GAS");

        console.log("View function working correctly");
        console.log("");
    }

    // ============ Test 8: Admin - Update Fee Parameters ============

    function testUpdateFeeParameters() public {
        console.log("TEST 8: Update Fee Parameters");
        console.log("-----------------------------");

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit FeeParametersUpdated(2500, 1000, 5000);
        feeManager.updateFeeParameters(2500, 1000, 5000);

        assertEq(feeManager.baseFee(), 2500, "Base fee should be updated");
        assertEq(feeManager.highGasFee(), 1000, "High gas fee should be updated");
        assertEq(feeManager.lowGasFee(), 5000, "Low gas fee should be updated");

        console.log("Fee parameters updated successfully");
        console.log("New base fee: 2500");
        console.log("New high gas fee: 1000");
        console.log("New low gas fee: 5000");
        console.log("");
    }

    // ============ Test 9: Admin - Update Thresholds ============

    function testUpdateThresholds() public {
        console.log("TEST 9: Update Thresholds");
        console.log("------------------------");

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit ThresholdsUpdated(120, 80);
        feeManager.updateThresholds(120, 80);

        assertEq(feeManager.highGasThreshold(), 120, "High threshold should be updated");
        assertEq(feeManager.lowGasThreshold(), 80, "Low threshold should be updated");

        console.log("Thresholds updated successfully");
        console.log("New high gas threshold: 120%");
        console.log("New low gas threshold: 80%");
        console.log("");
    }

    // ============ Test 10: Admin - Transfer Ownership ============

    function testTransferOwnership() public {
        console.log("TEST 10: Transfer Ownership");
        console.log("--------------------------");

        address newOwner = address(0x9999);

        vm.prank(OWNER);
        feeManager.transferOwnership(newOwner);

        assertEq(feeManager.owner(), newOwner, "Owner should be transferred");

        console.log("Ownership transferred to:", newOwner);
        console.log("");
    }

    // ============ Test 11: Authorization Checks ============

    function testAuthorizationChecks() public {
        console.log("TEST 11: Authorization & Security");
        console.log("--------------------------------");

        // Test unauthorized updateMovingAverage
        vm.prank(USER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.updateMovingAverage();
        console.log("Unauthorized updateMovingAverage blocked");

        // Test unauthorized getFee
        vm.prank(USER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.getFee();
        console.log("Unauthorized getFee blocked");

        // Test unauthorized updateFeeParameters
        vm.prank(USER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.updateFeeParameters(2000, 1000, 4000);
        console.log("Unauthorized updateFeeParameters blocked");

        // Test unauthorized updateThresholds
        vm.prank(USER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.updateThresholds(120, 80);
        console.log("Unauthorized updateThresholds blocked");

        // Test unauthorized transferOwnership
        vm.prank(USER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.transferOwnership(USER);
        console.log("Unauthorized transferOwnership blocked");

        console.log("All authorization checks passed");
        console.log("");
    }

    // ============ Test 12: Invalid Parameter Validation ============

    function testInvalidParameters() public {
        console.log("TEST 12: Invalid Parameter Validation");
        console.log("------------------------------------");

        // Test invalid fee parameters (zero values)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(0, 1000, 5000);
        console.log("Zero base fee rejected");

        // Test invalid fee hierarchy (highGasFee >= baseFee)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(3000, 3000, 6000);
        console.log("Invalid fee hierarchy rejected (highGasFee >= baseFee)");

        // Test invalid fee hierarchy (lowGasFee <= baseFee)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(3000, 1500, 3000);
        console.log("Invalid fee hierarchy rejected (lowGasFee <= baseFee)");

        // Test invalid thresholds (highGasThreshold <= 100)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(100, 80);
        console.log("Invalid high threshold rejected (<=100%)");

        // Test invalid thresholds (lowGasThreshold >= 100)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(120, 100);
        console.log("Invalid low threshold rejected (>=100%)");

        // Test invalid thresholds (lowGasThreshold >= highGasThreshold)
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(120, 120);
        console.log("Invalid threshold order rejected");

        // Test transfer to zero address
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.transferOwnership(address(0));
        console.log("Transfer to zero address rejected");

        console.log("All validation checks passed");
        console.log("");
    }

    // ============ Test 13: Edge Cases ============

    function testEdgeCases() public {
        console.log("TEST 13: Edge Cases");
        console.log("------------------");

        // Build stable average at 10 gwei
        for (uint256 i = 0; i < 10; i++) {
            vm.txGasPrice(10 gwei);
            vm.prank(HOOK);
            feeManager.updateMovingAverage();
        }

        // Test exactly at threshold boundaries
        // 10 gwei * 110% = 11 gwei (boundary for HIGH_GAS)
        vm.txGasPrice(11 gwei);
        vm.prank(HOOK);
        (uint24 fee1,) = feeManager.getFee();
        console.log("At high threshold (11 gwei): fee = %s", fee1);

        // 10 gwei * 90% = 9 gwei (boundary for LOW_GAS)
        vm.txGasPrice(9 gwei);
        vm.prank(HOOK);
        (uint24 fee2,) = feeManager.getFee();
        console.log("At low threshold (9 gwei): fee = %s", fee2);

        // Test with extremely high count (overflow prevention)
        console.log("Testing with high sample count...");
        for (uint256 i = 0; i < 100; i++) {
            vm.txGasPrice(10 gwei);
            vm.prank(HOOK);
            feeManager.updateMovingAverage();
        }

        (uint128 average, uint104 count) = feeManager.getMovingAverageData();
        console.log("After 100 samples - Average: %s, Count: %s", average, count);
        assertGt(count, 100, "Count should increase properly");

        console.log("Edge cases handled correctly");
        console.log("");
    }

    // ============ Test 14: Gas Price Volatility ============

    function testGasPriceVolatility() public {
        console.log("TEST 14: Gas Price Volatility Handling");
        console.log("-------------------------------------");

        // Simulate volatile gas conditions
        uint256[] memory volatileGas = new uint256[](10);
        volatileGas[0] = 5 gwei;
        volatileGas[1] = 15 gwei;
        volatileGas[2] = 8 gwei;
        volatileGas[3] = 20 gwei;
        volatileGas[4] = 6 gwei;
        volatileGas[5] = 18 gwei;
        volatileGas[6] = 10 gwei;
        volatileGas[7] = 12 gwei;
        volatileGas[8] = 7 gwei;
        volatileGas[9] = 16 gwei;

        console.log("Simulating volatile gas conditions...");

        for (uint256 i = 0; i < volatileGas.length; i++) {
            vm.txGasPrice(volatileGas[i]);
            vm.prank(HOOK);
            (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();
            console.log("Gas: %s gwei -> Fee: %s, Level: %s", volatileGas[i] / 1e9, fee, uint256(level));
        }

        (uint128 finalAverage,) = feeManager.getMovingAverageData();
        console.log("Final moving average after volatility: %s gwei", finalAverage / 1e9);

        assertGt(finalAverage, 5 gwei, "Average should stabilize above minimum");
        assertLt(finalAverage, 20 gwei, "Average should stabilize below maximum");

        console.log("Volatility handling successful");
        console.log("");
    }

    // ============ Test 15: Integration Scenario ============

    function testIntegrationScenario() public {
        console.log("TEST 15: Integration Scenario");
        console.log("----------------------------");
        console.log("Simulating realistic trading session...");

        // Morning: Low activity (low gas)
        console.log("\nMorning (Low Activity):");
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(5 gwei);
            vm.prank(HOOK);
            (uint24 fee,) = feeManager.getFee();
            console.log("  Swap %s: Gas 5 gwei -> Fee %s (0.6%%)", i + 1, fee);
        }

        // Afternoon: Normal activity
        console.log("\nAfternoon (Normal Activity):");
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(10 gwei);
            vm.prank(HOOK);
            (uint24 fee,) = feeManager.getFee();
            console.log("  Swap %s: Gas 10 gwei -> Fee %s (0.3%%)", i + 1, fee);
        }

        // Evening: High activity (high gas)
        console.log("\nEvening (High Activity):");
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(20 gwei);
            vm.prank(HOOK);
            (uint24 fee,) = feeManager.getFee();
            console.log("  Swap %s: Gas 20 gwei -> Fee %s (0.15%%)", i + 1, fee);
        }

        (uint128 finalAverage, uint104 count) = feeManager.getMovingAverageData();
        console.log("\nFinal Statistics:");
        console.log("  Moving Average: %s gwei", finalAverage / 1e9);
        console.log("  Total Swaps: %s", count);

        console.log("\nIntegration scenario completed successfully");
        console.log("");
    }
}
