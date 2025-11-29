// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title FHEConfigManager
 * @notice Manages encrypted LP strategy parameters using Fhenix FHE for privacy-preserving configurations
 * @dev All sensitive parameters (min swap size, hedge percentages) are stored encrypted
 */
contract FHEConfigManager {
    using PoolIdLibrary for PoolKey;

    // ============ Structs ============

    struct LPConfig {
        euint128 minSwapSize;
        euint32 hedgePercentage0;
        euint32 hedgePercentage1;
        bool isActive;
        bool autoHedgeEnabled;
        uint256 depositedAmount0;
        uint256 depositedAmount1;
    }

    // ============ Storage ============

    mapping(PoolId => mapping(address => LPConfig)) public lpConfigs;

    euint128 private ENCRYPTED_ZERO;
    euint32 private ENCRYPTED_ZERO_32;

    // ============ Events ============

    event LPConfigSet(PoolId indexed poolId, address indexed lp, bool isActive);
    event LPConfigUpdated(PoolId indexed poolId, address indexed lp, bool autoHedgeEnabled);
    event LPDeactivated(PoolId indexed poolId, address indexed lp);
    event HedgeTriggered(
        PoolId indexed poolId,
        address indexed lp,
        uint256 profitAmount0,
        uint256 profitAmount1,
        uint256 depositAmount0,
        uint256 depositAmount1,
        bool isToken0Trigger,
        bool isToken1Trigger
    );

    // ============ Errors ============

    error InvalidConfiguration();
    error DecryptionNotReady();

    // ============ Constructor ============

    constructor() {
        ENCRYPTED_ZERO = FHE.asEuint128(0);
        ENCRYPTED_ZERO_32 = FHE.asEuint32(0);
        FHE.allowThis(ENCRYPTED_ZERO);
        FHE.allowThis(ENCRYPTED_ZERO_32);
    }

    // ============ External Functions ============

    /**
     * @notice Configure LP's private JIT parameters using FHE encryption
     * @param poolKey The pool to configure for
     * @param minSwapSize Encrypted minimum swap size to trigger JIT
     * @param hedgePercentage0 Encrypted percentage (0-100) for token0 hedge threshold
     * @param hedgePercentage1 Encrypted percentage (0-100) for token1 hedge threshold
     * @param autoHedgeEnabled Whether to enable automatic hedging
     */
    function configureLPSettings(
        PoolKey calldata poolKey,
        InEuint128 calldata minSwapSize,
        InEuint32 calldata hedgePercentage0,
        InEuint32 calldata hedgePercentage1,
        bool autoHedgeEnabled
    ) external {
        PoolId poolId = poolKey.toId();

        euint128 encMinSwap = FHE.asEuint128(minSwapSize);
        euint32 encHedge0 = FHE.asEuint32(hedgePercentage0);
        euint32 encHedge1 = FHE.asEuint32(hedgePercentage1);

        lpConfigs[poolId][msg.sender] = LPConfig({
            minSwapSize: encMinSwap,
            hedgePercentage0: encHedge0,
            hedgePercentage1: encHedge1,
            isActive: true,
            autoHedgeEnabled: autoHedgeEnabled,
            depositedAmount0: 0,
            depositedAmount1: 0
        });

        FHE.allowThis(encMinSwap);
        FHE.allowThis(encHedge0);
        FHE.allowThis(encHedge1);
        FHE.allowSender(encMinSwap);
        FHE.allowSender(encHedge0);
        FHE.allowSender(encHedge1);

        emit LPConfigSet(poolId, msg.sender, true);
    }

    /**
     * @notice Update deposited amounts (called by hook when LP deposits)
     * @param poolKey The pool
     * @param lp LP address
     * @param amount0 Token0 deposited
     * @param amount1 Token1 deposited
     */
    function updateDepositedAmounts(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external {
        PoolId poolId = poolKey.toId();
        lpConfigs[poolId][lp].depositedAmount0 = amount0;
        lpConfigs[poolId][lp].depositedAmount1 = amount1;
    }

    /**
     * @notice Update auto-hedge setting for LP
     * @param poolKey The pool
     * @param autoHedgeEnabled New auto-hedge setting
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
     * @param poolKey The pool
     */
    function deactivateLP(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();
        lpConfigs[poolId][msg.sender].isActive = false;
        FHE.decrypt(lpConfigs[poolId][msg.sender].minSwapSize);
        emit LPDeactivated(poolId, msg.sender);
    }

    /**
     * @notice Reactivate LP participation
     * @param poolKey The pool
     */
    function reactivateLP(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();
        LPConfig storage config = lpConfigs[poolId][msg.sender];

        (uint128 minSwapValue, bool minSwapDecrypted) = FHE.getDecryptResultSafe(config.minSwapSize);
        if (!minSwapDecrypted) revert DecryptionNotReady();
        if (minSwapValue == 0) revert InvalidConfiguration();

        config.isActive = true;
        emit LPConfigSet(poolId, msg.sender, true);
    }

    // ============ View Functions ============

    function isActive(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return lpConfigs[poolKey.toId()][lp].isActive;
    }

    function hasAutoHedgeEnabled(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return lpConfigs[poolKey.toId()][lp].autoHedgeEnabled;
    }

    function getLPConfig(PoolKey calldata poolKey, address lp) external view returns (LPConfig memory config) {
        return lpConfigs[poolKey.toId()][lp];
    }

    function getDepositedAmounts(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = poolKey.toId();
        return (lpConfigs[poolId][lp].depositedAmount0, lpConfigs[poolId][lp].depositedAmount1);
    }

    /**
     * @notice Check if swap amount meets LP's encrypted threshold
     * @param poolKey The pool
     * @param lp LP address
     * @param swapAmount Swap amount to check
     * @return bool True if threshold is met
     */
    function meetsThreshold(PoolKey calldata poolKey, address lp, uint128 swapAmount) external view returns (bool) {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        if (!config.isActive) return false;

        (uint128 minSwapValue, bool minSwapDecrypted) = FHE.getDecryptResultSafe(config.minSwapSize);
        if (!minSwapDecrypted) revert DecryptionNotReady();

        return (swapAmount >= minSwapValue);
    }

    /**
     * @notice Check if profits should trigger auto-hedge (either token triggers)
     * @param poolKey The pool
     * @param lp LP address
     * @param currentProfits0 Current profit in token0
     * @param currentProfits1 Current profit in token1
     * @return bool True if either token's profit exceeds its threshold
     */
    function shouldAutoHedge(PoolKey calldata poolKey, address lp, uint256 currentProfits0, uint256 currentProfits1)
        external
        view
        returns (bool)
    {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        if (!config.autoHedgeEnabled) return false;

        (uint32 hedgePercent0, bool hedge0Decrypted) = FHE.getDecryptResultSafe(config.hedgePercentage0);
        (uint32 hedgePercent1, bool hedge1Decrypted) = FHE.getDecryptResultSafe(config.hedgePercentage1);
        if (!hedge0Decrypted || !hedge1Decrypted) revert DecryptionNotReady();

        bool token0Threshold = false;
        bool token1Threshold = false;

        if (config.depositedAmount0 > 0) {
            uint256 threshold0 = (config.depositedAmount0 * hedgePercent0) / 100;
            token0Threshold = currentProfits0 >= threshold0;
        }

        if (config.depositedAmount1 > 0) {
            uint256 threshold1 = (config.depositedAmount1 * hedgePercent1) / 100;
            token1Threshold = currentProfits1 >= threshold1;
        }

        return token0Threshold || token1Threshold;
    }

    /**
     * @notice Get which token(s) triggered the hedge
     * @param poolKey The pool
     * @param lp LP address
     * @param currentProfits0 Current profit in token0
     * @param currentProfits1 Current profit in token1
     * @return token0Triggered True if token0 threshold met
     * @return token1Triggered True if token1 threshold met
     */
    function getHedgeTriggers(PoolKey calldata poolKey, address lp, uint256 currentProfits0, uint256 currentProfits1)
        external
        view
        returns (bool token0Triggered, bool token1Triggered)
    {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        if (!config.autoHedgeEnabled) return (false, false);

        (uint32 hedgePercent0, bool hedge0Decrypted) = FHE.getDecryptResultSafe(config.hedgePercentage0);
        (uint32 hedgePercent1, bool hedge1Decrypted) = FHE.getDecryptResultSafe(config.hedgePercentage1);
        if (!hedge0Decrypted || !hedge1Decrypted) revert DecryptionNotReady();

        if (config.depositedAmount0 > 0) {
            uint256 threshold0 = (config.depositedAmount0 * hedgePercent0) / 100;
            token0Triggered = currentProfits0 >= threshold0;
        }

        if (config.depositedAmount1 > 0) {
            uint256 threshold1 = (config.depositedAmount1 * hedgePercent1) / 100;
            token1Triggered = currentProfits1 >= threshold1;
        }

        return (token0Triggered, token1Triggered);
    }

    /**
     * @notice Get decrypted hedge percentage
     * @dev Requires prior decryption via decryptHedgePercentage
     * @param poolKey Pool to check
     * @param lp LP address
     * @return uint256 Hedge percentage for token0
     * @return uint256 Hedge percentage for token1
     */
    function getHedgePercentage(PoolKey calldata poolKey, address lp) external view returns (uint256, uint256) {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        if (!config.autoHedgeEnabled) return (0, 0);

        (uint32 hedgeValue0, bool hedgeDecrypted0) = FHE.getDecryptResultSafe(config.hedgePercentage0);
        if (!hedgeDecrypted0) revert DecryptionNotReady();

        (uint32 hedgeValue1, bool hedgeDecrypted1) = FHE.getDecryptResultSafe(config.hedgePercentage1);
        if (!hedgeDecrypted1) revert DecryptionNotReady();

        return (uint256(hedgeValue0), uint256(hedgeValue1));
    }

    /**
     * @notice Decrypt hedge percentage (should be restricted to authorized hook only)
     * @param poolKey Pool to query
     * @param lp LP address
     */
    function decryptHedgePercentage(PoolKey calldata poolKey, address lp) external {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        FHE.decrypt(config.hedgePercentage0);
        FHE.decrypt(config.hedgePercentage1);
    }

    /**
     * @notice Decrypt minimum swap size (should be restricted to authorized hook only)
     * @param poolKey Pool to query
     * @param lp LP address
     */
    function decryptMinSwapSize(PoolKey calldata poolKey, address lp) public {
        LPConfig memory config = lpConfigs[poolKey.toId()][lp];
        FHE.decrypt(config.minSwapSize);
    }
}
