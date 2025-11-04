// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDynamicFeeManager {
    function getFee() external returns (uint24 fee, uint8 level);
    function updateMovingAverage() external;
}
