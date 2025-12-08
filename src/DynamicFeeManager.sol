// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DynamicFeeManager
 * @notice Adjusts swap fees based on gas price conditions to optimize LP returns
 * @dev Uses moving average gas price to determine fee tiers
 */
contract DynamicFeeManager {
    // ============ Storage ============

    uint128 public movingAverageGasPrice;
    uint104 public movingAverageGasPriceCount;

    uint24 public baseFee = 3000;
    uint24 public highGasFee = 1500;
    uint24 public lowGasFee = 6000;

    uint256 public highGasThreshold = 110;
    uint256 public lowGasThreshold = 90;

    address public hook;
    address public owner;

    // ============ Events ============

    event FeeCalculated(uint24 fee, uint128 currentGasPrice, uint128 movingAverage, FeeLevel level);
    event FeeParametersUpdated(uint24 baseFee, uint24 highGasFee, uint24 lowGasFee);
    event ThresholdsUpdated(uint256 highGasThreshold, uint256 lowGasThreshold);
    event MovingAverageUpdated(uint128 newAverage, uint104 count);
    event HookUpdated(address indexed newHook);

    // ============ Enums ============

    enum FeeLevel {
        LOW_GAS,
        NORMAL,
        HIGH_GAS
    }

    // ============ Errors ============

    error Unauthorized();
    error InvalidFee();
    error InvalidThreshold();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(address _owner) {
        owner = _owner;
        updateMovingAverage();
    }

    // ============ External Functions ============

    /**
     * @notice Update hook address (only callable once, during deployment)
     * @param _hook New hook address
     */
    function updateHook(address _hook) external {
        require(hook == address(0), "Hook already set");
        require(_hook != address(0), "Invalid hook address");
        hook = _hook;
        emit HookUpdated(_hook);
    }

    /**
     * @notice Calculate dynamic fee based on current gas conditions
     * @return fee The calculated fee in basis points
     * @return level The current fee level
     */
    function getFee() external returns (uint24 fee, FeeLevel level) {
        uint128 gasPrice = uint128(tx.gasprice);
        updateMovingAverage();

        if (gasPrice > (movingAverageGasPrice * highGasThreshold) / 100) {
            fee = highGasFee;
            level = FeeLevel.HIGH_GAS;
        } else if (gasPrice < (movingAverageGasPrice * lowGasThreshold) / 100) {
            fee = lowGasFee;
            level = FeeLevel.LOW_GAS;
        } else {
            fee = baseFee;
            level = FeeLevel.NORMAL;
        }

        emit FeeCalculated(fee, gasPrice, movingAverageGasPrice, level);
        return (fee, level);
    }

    /**
     * @notice Get current fee without updating state
     * @return fee The current fee in basis points
     * @return level The current fee level
     */
    function getCurrentFee() external view returns (uint24 fee, FeeLevel level) {
        uint128 gasPrice = uint128(tx.gasprice);

        if (gasPrice > (movingAverageGasPrice * highGasThreshold) / 100) {
            return (highGasFee, FeeLevel.HIGH_GAS);
        } else if (gasPrice < (movingAverageGasPrice * lowGasThreshold) / 100) {
            return (lowGasFee, FeeLevel.LOW_GAS);
        } else {
            return (baseFee, FeeLevel.NORMAL);
        }
    }

    /**
     * @notice Update moving average gas price
     */
    function updateMovingAverage() public {
        uint128 gasPrice = uint128(tx.gasprice);

        if (movingAverageGasPriceCount == 0) {
            movingAverageGasPrice = gasPrice;
            movingAverageGasPriceCount = 1;
        } else {
            movingAverageGasPrice =
                ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);
            movingAverageGasPriceCount++;
        }

        emit MovingAverageUpdated(movingAverageGasPrice, movingAverageGasPriceCount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update fee parameters
     * @param _baseFee New base fee in basis points
     * @param _highGasFee New high gas fee in basis points
     * @param _lowGasFee New low gas fee in basis points
     */
    function updateFeeParameters(uint24 _baseFee, uint24 _highGasFee, uint24 _lowGasFee) external onlyOwner {
        if (_baseFee == 0 || _highGasFee == 0 || _lowGasFee == 0) revert InvalidFee();
        if (_highGasFee >= _baseFee || _lowGasFee <= _baseFee) revert InvalidFee();

        baseFee = _baseFee;
        highGasFee = _highGasFee;
        lowGasFee = _lowGasFee;

        emit FeeParametersUpdated(_baseFee, _highGasFee, _lowGasFee);
    }

    /**
     * @notice Update gas price thresholds
     * @param _highGasThreshold Percentage above average for high gas (> 100)
     * @param _lowGasThreshold Percentage below average for low gas (< 100)
     */
    function updateThresholds(uint256 _highGasThreshold, uint256 _lowGasThreshold) external onlyOwner {
        if (_highGasThreshold <= 100 || _lowGasThreshold >= 100) revert InvalidThreshold();
        if (_lowGasThreshold >= _highGasThreshold) revert InvalidThreshold();

        highGasThreshold = _highGasThreshold;
        lowGasThreshold = _lowGasThreshold;

        emit ThresholdsUpdated(_highGasThreshold, _lowGasThreshold);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        owner = newOwner;
    }

    // ============ View Functions ============

    function getMovingAverageData() external view returns (uint128 average, uint104 count) {
        return (movingAverageGasPrice, movingAverageGasPriceCount);
    }

    function getFeeParameters() external view returns (uint24 _baseFee, uint24 _highGasFee, uint24 _lowGasFee) {
        return (baseFee, highGasFee, lowGasFee);
    }

    function getThresholds() external view returns (uint256 _highGasThreshold, uint256 _lowGasThreshold) {
        return (highGasThreshold, lowGasThreshold);
    }

    function getCurrentFeeLevel() external view returns (FeeLevel) {
        uint128 gasPrice = uint128(tx.gasprice);

        if (gasPrice > (movingAverageGasPrice * highGasThreshold) / 100) {
            return FeeLevel.HIGH_GAS;
        } else if (gasPrice < (movingAverageGasPrice * lowGasThreshold) / 100) {
            return FeeLevel.LOW_GAS;
        } else {
            return FeeLevel.NORMAL;
        }
    }
}
