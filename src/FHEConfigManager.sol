// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title FHEConfigManager
 * @notice Manages encrypted LP strategy parameters using Fhenix FHE
 * @dev Provides privacy-preserving configuration storage and threshold evaluation
 */
contract FHEConfigManager {
    using PoolIdLibrary for PoolKey;

    // ============ Data Structures ============

    struct LPConfig {
        euint128 minSwapSize; // Encrypted minimum swap to trigger JIT
        euint128 maxLiquidity; // Encrypted maximum liquidity capacity
        euint32 profitThresholdBps; // Encrypted profit threshold (basis points)
        euint32 hedgePercentage; // Encrypted auto-hedge percentage (0-100)
        bool isActive; // Public participation flag
        bool autoHedgeEnabled; // Auto-hedging toggle
    }

    // ============ Storage ============

    mapping(PoolId => mapping(address => LPConfig)) public lpConfigs;

    address public hook; // Main hook contract address

    // FHE Constants
    euint128 private ENCRYPTED_ZERO;
    euint32 private ENCRYPTED_ZERO_32;

    // ============ Events ============

    event LPConfigSet(PoolId indexed poolId, address indexed lp, bool isActive);

    event LPConfigUpdated(PoolId indexed poolId, address indexed lp, bool autoHedgeEnabled);

    event LPDeactivated(PoolId indexed poolId, address indexed lp);

    // ============ Errors ============

    error Unauthorized();
    error InvalidConfiguration();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(address _hook) {
        hook = _hook;

        // Initialize FHE constants
        ENCRYPTED_ZERO = FHE.asEuint128(0);
        ENCRYPTED_ZERO_32 = FHE.asEuint32(0);

        // Grant contract access to FHE constants
        FHE.allowThis(ENCRYPTED_ZERO);
        FHE.allowThis(ENCRYPTED_ZERO_32);
    }

    // ============ External Functions ============

    /**
     * @notice Configure LP's private JIT parameters using FHE encryption
     * @param poolKey The pool to configure for
     * @param minSwapSize Encrypted minimum swap size to trigger JIT
     * @param maxLiquidity Encrypted maximum liquidity to provide
     * @param profitThreshold Encrypted profit threshold in basis points
     * @param hedgePercentage Encrypted auto-hedge percentage (0-100)
     * @param autoHedgeEnabled Whether to enable automatic hedging
     */
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint128 calldata maxLiquidity,
        InEuint32 calldata profitThreshold,
        InEuint32 calldata hedgePercentage,
        bool autoHedgeEnabled
    ) external {
        PoolId poolId = poolKey.toId();

        // Create encrypted values
        euint128 encMinSwap = FHE.asEuint128(minSwapSize);
        euint128 encMaxLiq = FHE.asEuint128(maxLiquidity);
        euint32 encProfit = FHE.asEuint32(profitThreshold);
        euint32 encHedge = FHE.asEuint32(hedgePercentage);

        // Store LP configuration
        lpConfigs[poolId][msg.sender] = LPConfig({
            minSwapSize: encMinSwap,
            maxLiquidity: encMaxLiq,
            profitThresholdBps: encProfit,
            hedgePercentage: encHedge,
            isActive: true,
            autoHedgeEnabled: autoHedgeEnabled
        });

        // Grant FHE access permissions
        FHE.allowThis(encMinSwap);
        FHE.allowThis(encMaxLiq);
        FHE.allowThis(encProfit);
        FHE.allowThis(encHedge);
        FHE.allowSender(encMinSwap);
        FHE.allowSender(encMaxLiq);
        FHE.allowSender(encProfit);
        FHE.allowSender(encHedge);

        emit LPConfigSet(poolId, msg.sender, true);
    }

    /**
     * @notice Update auto-hedge setting for LP
     * @param poolKey The pool to update
     * @param autoHedgeEnabled New auto-hedge status
     */
    function updateAutoHedge(PoolKey calldata poolKey, bool autoHedgeEnabled) external {
        PoolId poolId = poolKey.toId();
        LPConfig storage config = lpConfigs[poolId][msg.sender];

        if (!config.isActive) revert InvalidConfiguration();

        config.autoHedgeEnabled = autoHedgeEnabled;

        emit LPConfigUpdated(poolId, msg.sender, autoHedgeEnabled);
    }

    /**
     * @notice Deactivate LP participation in JIT operations
     * @param poolKey The pool to deactivate in
     */
    function deactivateLP(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();
        lpConfigs[poolId][msg.sender].isActive = false;

        LPConfig storage config = lpConfigs[poolId][msg.sender];
        FHE.decrypt(config.minSwapSize);

        emit LPDeactivated(poolId, msg.sender);
    }

    /**
     * @notice Reactivate LP participation
     * @param poolKey The pool to reactivate in
     */
    function reactivateLP(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();
        LPConfig storage config = lpConfigs[poolId][msg.sender];

        (uint128 minSwapValue, bool minSwapDecrypted) = FHE.getDecryptResultSafe(config.minSwapSize); // decrypt already called in the deactivateLP function
        if (!minSwapDecrypted) revert("minSwapSize is not ready");

        // (uint128 zeroValue, bool zeroDecrypted) = FHE.getDecryptResultSafe(ENCRYPTED_ZERO);
        // if (!zeroDecrypted) revert("zeroValue is not ready");

        // Check if config exists (has been set before)
        if (minSwapValue == 0) {
            revert InvalidConfiguration();
        }

        config.isActive = true;

        emit LPConfigSet(poolId, msg.sender, true);
    }

    // ============ View Functions (Hook Access) ============

    /**
     * @notice Check if LP is active
     * @param poolKey Pool to query
     * @param lp LP address
     * @return Whether LP is active
     */
    function isActive(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return lpConfigs[poolKey.toId()][lp].isActive;
    }

    /**
     * @notice Check if LP has auto-hedge enabled
     * @param poolKey Pool to query
     * @param lp LP address
     * @return Whether auto-hedge is enabled
     */
    function hasAutoHedgeEnabled(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return lpConfigs[poolKey.toId()][lp].autoHedgeEnabled;
    }

    /**
     * @notice Get LP configuration (called by hook)
     * @param poolKey Pool to query
     * @param lp LP address
     * @return config LP configuration
     */
    function getLPConfig(PoolKey calldata poolKey, address lp) external view returns (LPConfig memory config) {
        return lpConfigs[poolKey.toId()][lp];
    }

    /**
     * @notice Evaluate if swap meets LP's encrypted threshold (simplified for demo)
     * @dev In production, this should use FHE comparisons without decryption
     * @param poolKey Pool to check
     * @param lp LP address
     * @param swapAmount Swap size to evaluate
     * @return Whether threshold is met
     */
    function meetsThreshold(PoolKey calldata poolKey, address lp, uint128 swapAmount) external view returns (bool) {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];

        if (!config.isActive) return false;

        (uint128 minSwapValue, bool minSwapDecrypted) = FHE.getDecryptResultSafe(config.minSwapSize); // Ensure to call decrypt first (decryptMinSwapSize) and wait some seconds before calling this function
        if (!minSwapDecrypted) revert("minSwapSize is not ready");

        return (swapAmount > minSwapValue);
    }

    /**
     * @notice Calculate hedge percentage (simplified for demo)
     * @dev In production, decrypt only when needed and with proper access control
     * @param poolKey Pool to check
     * @param lp LP address
     * @return Hedge percentage (0-100)
     */
    function getHedgePercentage(PoolKey calldata poolKey, address lp) external view onlyHook returns (uint256) {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];

        if (!config.autoHedgeEnabled) return 0;

        (uint32 hedgeValue, bool hedgeDecrypted) = FHE.getDecryptResultSafe(config.hedgePercentage); // Ensure to call decrypt first (decryptHedgePercentage) and wait some seconds before calling this function
        if (!hedgeDecrypted) revert("hedgePercentage is not ready");

        return uint256(hedgeValue);
    }

    /**
     * @notice Decrypt hedge percentage (would be set for authorized hook only)
     * @param poolKey Pool to query
     * @param lp LP address
     */
    function decryptHedgePercentage(PoolKey calldata poolKey, address lp) external onlyHook {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        FHE.decrypt(config.hedgePercentage);
    }

    /**
     * @notice Decrypt minimum swap size (would be set for authorized hook only)
     * @param poolKey Pool to query
     * @param lp LP address
     */
    function decryptMinSwapSize(PoolKey calldata poolKey, address lp) public onlyHook {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        FHE.decrypt(config.minSwapSize);
    }

    /**
     * @notice Decrypt max liquidity (would be set for authorized hook only)
     * @param poolKey Pool to query
     * @param lp LP address
     */
    function decryptMaxLiquidity(PoolKey calldata poolKey, address lp) external onlyHook {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        FHE.decrypt(config.maxLiquidity);
    }
}
