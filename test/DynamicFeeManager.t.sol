// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";

contract DynamicFeeManagerTest is Test {
    DynamicFeeManager public feeManager;

    address public constant HOOK = address(0x1111);
    address public constant OWNER = address(0x2222);
    address public constant USER = address(0x3333);

    uint256 public constant BASE_GAS = 10 gwei;
    uint256 public constant LOW_GAS = 5 gwei;
    uint256 public constant HIGH_GAS = 15 gwei;
    uint256 public constant EXTREME_LOW_GAS = 2 gwei;
    uint256 public constant EXTREME_HIGH_GAS = 25 gwei;

    event FeeCalculated(uint24 fee, uint128 currentGasPrice, uint128 movingAverage, DynamicFeeManager.FeeLevel level);
    event FeeParametersUpdated(uint24 baseFee, uint24 highGasFee, uint24 lowGasFee);
    event ThresholdsUpdated(uint256 highGasThreshold, uint256 lowGasThreshold);
    event MovingAverageUpdated(uint128 newAverage, uint104 count);

    function setUp() public {
        vm.txGasPrice(BASE_GAS);
        feeManager = new DynamicFeeManager(HOOK, OWNER);
    }

    function testInitialization() public view {
        assertEq(feeManager.hook(), HOOK);
        assertEq(feeManager.owner(), OWNER);
        assertEq(feeManager.baseFee(), 3000);
        assertEq(feeManager.highGasFee(), 1500);
        assertEq(feeManager.lowGasFee(), 6000);
        assertEq(feeManager.highGasThreshold(), 110);
        assertEq(feeManager.lowGasThreshold(), 90);

        (uint128 average, uint104 count) = feeManager.getMovingAverageData();
        assertGt(average, 0);
        assertEq(count, 1);
    }

    function testBaseFeeCalculation() public {
        vm.txGasPrice(BASE_GAS);

        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        assertEq(fee, 3000);
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.NORMAL));
    }

    function testHighGasLowFee() public {
        vm.txGasPrice(EXTREME_HIGH_GAS);

        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        assertEq(fee, 1500);
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.HIGH_GAS));
    }

    function testLowGasHighFee() public {
        vm.txGasPrice(EXTREME_LOW_GAS);

        (uint24 fee, DynamicFeeManager.FeeLevel level) = feeManager.getFee();

        assertEq(fee, 6000);
        assertEq(uint256(level), uint256(DynamicFeeManager.FeeLevel.LOW_GAS));
    }

    function testMovingAverageUpdates() public {
        (, uint104 initialCount) = feeManager.getMovingAverageData();

        uint256[] memory gasPrices = new uint256[](5);
        gasPrices[0] = 8 gwei;
        gasPrices[1] = 10 gwei;
        gasPrices[2] = 12 gwei;
        gasPrices[3] = 9 gwei;
        gasPrices[4] = 11 gwei;

        for (uint256 i = 0; i < gasPrices.length; i++) {
            vm.txGasPrice(gasPrices[i]);
            feeManager.updateMovingAverage();
        }

        (uint128 finalAverage, uint104 finalCount) = feeManager.getMovingAverageData();
        assertGt(finalCount, initialCount);
        assertGt(finalAverage, 0);
    }

    function testFeeTransitions() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.txGasPrice(10 gwei);
            feeManager.updateMovingAverage();
        }

        vm.txGasPrice(7 gwei);
        (uint24 fee1,) = feeManager.getFee();
        assertEq(fee1, 6000);

        vm.txGasPrice(10 gwei);
        (uint24 fee2,) = feeManager.getFee();
        assertEq(fee2, 3000);

        vm.txGasPrice(13 gwei);
        (uint24 fee3,) = feeManager.getFee();
        assertEq(fee3, 1500);
    }

    function testGetCurrentFeeView() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(10 gwei);
            feeManager.updateMovingAverage();
        }

        vm.txGasPrice(15 gwei);
        (uint24 viewFee, DynamicFeeManager.FeeLevel viewLevel) = feeManager.getCurrentFee();

        assertEq(viewFee, 1500);
        assertEq(uint256(viewLevel), uint256(DynamicFeeManager.FeeLevel.HIGH_GAS));
    }

    function testUpdateFeeParameters() public {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit FeeParametersUpdated(2500, 1000, 5000);
        feeManager.updateFeeParameters(2500, 1000, 5000);

        assertEq(feeManager.baseFee(), 2500);
        assertEq(feeManager.highGasFee(), 1000);
        assertEq(feeManager.lowGasFee(), 5000);
    }

    function testUpdateThresholds() public {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit ThresholdsUpdated(120, 80);
        feeManager.updateThresholds(120, 80);

        assertEq(feeManager.highGasThreshold(), 120);
        assertEq(feeManager.lowGasThreshold(), 80);
    }

    function testTransferOwnership() public {
        address newOwner = address(0x9999);

        vm.prank(OWNER);
        feeManager.transferOwnership(newOwner);

        assertEq(feeManager.owner(), newOwner);
    }

    function testInvalidFeeParameters() public {
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(0, 1000, 5000);

        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(3000, 3000, 6000);

        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidFee.selector);
        feeManager.updateFeeParameters(3000, 1500, 3000);
    }

    function testInvalidThresholds() public {
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(100, 80);

        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(120, 100);

        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.InvalidThreshold.selector);
        feeManager.updateThresholds(120, 120);
    }

    function testTransferToZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(DynamicFeeManager.Unauthorized.selector);
        feeManager.transferOwnership(address(0));
    }

    function testThresholdBoundaries() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.txGasPrice(10 gwei);
            feeManager.updateMovingAverage();
        }

        vm.txGasPrice(11 gwei);
        (uint24 fee1,) = feeManager.getFee();
        assertEq(fee1, 3000);

        vm.txGasPrice(9 gwei);
        (uint24 fee2,) = feeManager.getFee();
        assertEq(fee2, 3000);
    }

    function testHighSampleCount() public {
        for (uint256 i = 0; i < 100; i++) {
            vm.txGasPrice(10 gwei);
            feeManager.updateMovingAverage();
        }

        (, uint104 count) = feeManager.getMovingAverageData();
        assertGt(count, 100);
    }

    function testGasPriceVolatility() public {
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

        for (uint256 i = 0; i < volatileGas.length; i++) {
            vm.txGasPrice(volatileGas[i]);
            feeManager.getFee();
        }

        (uint128 finalAverage,) = feeManager.getMovingAverageData();
        assertGt(finalAverage, 5 gwei);
        assertLt(finalAverage, 20 gwei);
    }

    function testRealisticTradingSession() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(10 gwei);
            (uint24 fee,) = feeManager.getFee();
            assertEq(fee, 3000);
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(5 gwei);
            (uint24 fee,) = feeManager.getFee();
            assertEq(fee, 6000);
        }

        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(20 gwei);
            (uint24 fee,) = feeManager.getFee();
            assertEq(fee, 1500);
        }

        (, uint104 count) = feeManager.getMovingAverageData();
        assertGt(count, 15);
    }
}
