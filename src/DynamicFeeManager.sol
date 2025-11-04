// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DynamicFeeManager
 * @notice Manages dynamic fee calculation based on gas price conditions
 * @dev Adjusts fees to incentivize trading during high gas and maximize LP returns during low gas
 */
contract DynamicFeeManager {
    // ============ Storage ============

    uint128 public movingAverageGasPrice;
    uint104 public movingAverageGasPriceCount;

    uint24 public baseFee = 3000; // 0.3% base fee
    uint24 public highGasFee = 1500; // 0.15% during high gas
    uint24 public lowGasFee = 6000; // 0.6% during low gas

    uint256 public highGasThreshold = 110; // 110% of moving average
    uint256 public lowGasThreshold = 90; // 90% of moving average

    address public hook; // Main hook contract address
    address public owner;

    // ============ Events ============

    event FeeCalculated(uint24 fee, uint128 currentGasPrice, uint128 movingAverage, FeeLevel level);

    event FeeParametersUpdated(uint24 baseFee, uint24 highGasFee, uint24 lowGasFee);

    event ThresholdsUpdated(uint256 highGasThreshold, uint256 lowGasThreshold);

    event MovingAverageUpdated(uint128 newAverage, uint104 count);

    // ============ Enums ============

    enum FeeLevel {
        LOW_GAS, // High fee period
        NORMAL, // Base fee period
        HIGH_GAS // Low fee period (incentivize trading)

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

    constructor(address _hook, address _owner) {
        hook = _hook;
        owner = _owner;

        // Initialize with current gas price
        updateMovingAverage();
    }

    // ============ External Functions ============

    /**
     * @notice Calculate dynamic fee based on current gas conditions
     * @return fee The calculated fee in basis points
     * @return level The fee level category
     */
    function getFee() external returns (uint24 fee, FeeLevel level) {
        uint128 gasPrice = uint128(tx.gasprice);

        // Update moving average
        updateMovingAverage();

        // Determine fee level
        if (gasPrice > (movingAverageGasPrice * highGasThreshold) / 100) {
            // High gas: Lower fees to incentivize trading
            fee = highGasFee;
            level = FeeLevel.HIGH_GAS;
        } else if (gasPrice < (movingAverageGasPrice * lowGasThreshold) / 100) {
            // Low gas: Higher fees to maximize LP returns
            fee = lowGasFee;
            level = FeeLevel.LOW_GAS;
        } else {
            // Normal gas: Base fee
            fee = baseFee;
            level = FeeLevel.NORMAL;
        }

        emit FeeCalculated(fee, gasPrice, movingAverageGasPrice, level);

        return (fee, level);
    }

    /**
     * @notice Get current fee without updating state (view function)
     * @return fee The calculated fee in basis points
     * @return level The fee level category
     */
    function getCurrentFee() external view returns (uint24 fee, FeeLevel level) {
        uint128 gasPrice = uint128(tx.gasprice);

        // Determine fee level
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
     * @dev Called by hook after each swap
     */
    function updateMovingAverage() public onlyHook {
        uint128 gasPrice = uint128(tx.gasprice);

        if (movingAverageGasPriceCount == 0) {
            // First initialization
            movingAverageGasPrice = gasPrice;
            movingAverageGasPriceCount = 1;
        } else {
            // Update moving average
            movingAverageGasPrice =
                ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);
            movingAverageGasPriceCount++;
        }

        emit MovingAverageUpdated(movingAverageGasPrice, movingAverageGasPriceCount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update fee parameters
     * @param _baseFee New base fee
     * @param _highGasFee New high gas fee
     * @param _lowGasFee New low gas fee
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
     * @param _highGasThreshold New high gas threshold (percentage)
     * @param _lowGasThreshold New low gas threshold (percentage)
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
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        owner = newOwner;
    }

    // ============ View Functions ============

    /**
     * @notice Get current moving average and count
     * @return average Current moving average gas price
     * @return count Number of samples in moving average
     */
    function getMovingAverageData() external view returns (uint128 average, uint104 count) {
        return (movingAverageGasPrice, movingAverageGasPriceCount);
    }

    /**
     * @notice Get all fee parameters
     * @return _baseFee Base fee
     * @return _highGasFee High gas fee
     * @return _lowGasFee Low gas fee
     */
    function getFeeParameters() external view returns (uint24 _baseFee, uint24 _highGasFee, uint24 _lowGasFee) {
        return (baseFee, highGasFee, lowGasFee);
    }

    /**
     * @notice Get threshold parameters
     * @return _highGasThreshold High gas threshold
     * @return _lowGasThreshold Low gas threshold
     */
    function getThresholds() external view returns (uint256 _highGasThreshold, uint256 _lowGasThreshold) {
        return (highGasThreshold, lowGasThreshold);
    }

    /**
     * @notice Get current fee level based on gas price
     * @return Current fee level
     */
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
