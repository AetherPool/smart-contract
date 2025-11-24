// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

enum FeeLevel {
    LOW_GAS,
    NORMAL,
    HIGH_GAS
}

interface IDynamicFeeManager {
    function getFee() external returns (uint24 fee, FeeLevel level);
    function updateMovingAverage() external;
}
