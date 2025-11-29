// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";

/**
 * @title ProfitManager
 * @notice Manages LP profit tracking and withdrawal operations with auto-hedge support
 * @dev Tracks profits separately for token0 and token1, triggers auto-hedge when either hits threshold
 */
contract ProfitManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Storage ============

    mapping(PoolId => mapping(address => uint256)) public lpProfits0;
    mapping(PoolId => mapping(address => uint256)) public lpProfits1;

    address public configManager;

    // ============ Events ============

    event ProfitAccrued(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ProfitWithdrawn(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event AutoHedgeExecuted(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        bool token0Triggered,
        bool token1Triggered
    );
    event AutoHedgeReady(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    // ============ Errors ============

    error InsufficientProfit();
    error InvalidInput();

    // ============ Constructor ============

    constructor(address _configManager) {
        configManager = _configManager;
    }

    // ============ External Functions ============

    /**
     * @notice Accrue profits to LP (called by JITCoordinator after swaps)
     * @param poolKey Pool key
     * @param lp LP address
     * @param amount0 Profit in token0
     * @param amount1 Profit in token1
     */
    function accrueProfit(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external {
        PoolId poolId = poolKey.toId();

        lpProfits0[poolId][lp] += amount0;
        lpProfits1[poolId][lp] += amount1;

        emit ProfitAccrued(lp, poolId, amount0, amount1);
    }

    /**
     * @notice Withdraw all accumulated profits
     * @param poolKey Pool key
     * @param lp LP address
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
    function withdrawProfits(PoolKey calldata poolKey, address lp)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = poolKey.toId();

        amount0 = lpProfits0[poolId][lp];
        amount1 = lpProfits1[poolId][lp];

        if (amount0 == 0 && amount1 == 0) revert InsufficientProfit();

        if (amount0 > 0) lpProfits0[poolId][lp] = 0;
        if (amount1 > 0) lpProfits1[poolId][lp] = 0;

        emit ProfitWithdrawn(lp, poolId, amount0, amount1);
        return (amount0, amount1);
    }

    /**
     * @notice Withdraw partial profits
     * @param poolKey Pool key
     * @param lp LP address
     * @param amount0 Amount of token0 to withdraw
     * @param amount1 Amount of token1 to withdraw
     * @return withdrawn0 Amount of token0 withdrawn
     * @return withdrawn1 Amount of token1 withdrawn
     */
    function withdrawPartialProfits(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1)
        external
        returns (uint256 withdrawn0, uint256 withdrawn1)
    {
        PoolId poolId = poolKey.toId();

        uint256 availableProfit0 = lpProfits0[poolId][lp];
        uint256 availableProfit1 = lpProfits1[poolId][lp];

        if (amount0 > availableProfit0 || amount1 > availableProfit1) {
            revert InsufficientProfit();
        }

        if (availableProfit0 == 0 && availableProfit1 == 0) revert InsufficientProfit();

        withdrawn0 = amount0;
        withdrawn1 = amount1;

        if (amount0 > 0) lpProfits0[poolId][lp] -= amount0;
        if (amount1 > 0) lpProfits1[poolId][lp] -= amount1;

        emit ProfitWithdrawn(lp, poolId, amount0, amount1);
        return (withdrawn0, withdrawn1);
    }

    /**
     * @notice Check and execute auto-hedge if threshold is met for either token
     * @dev Called by JITCoordinator after fee distribution
     * @param poolKey Pool key
     * @param lp LP address
     * @return shouldHedge True if auto-hedge was triggered
     * @return amount0 Amount of token0 to transfer
     * @return amount1 Amount of token1 to transfer
     * @return token0Triggered True if token0 hit threshold
     * @return token1Triggered True if token1 hit threshold
     */
    function checkAndExecuteAutoHedge(PoolKey calldata poolKey, address lp)
        external
        returns (bool shouldHedge, uint256 amount0, uint256 amount1, bool token0Triggered, bool token1Triggered)
    {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        shouldHedge = IFHEConfigManager(configManager).shouldAutoHedge(poolKey, lp, profit0, profit1);

        if (shouldHedge) {
            (token0Triggered, token1Triggered) =
                IFHEConfigManager(configManager).getHedgeTriggers(poolKey, lp, profit0, profit1);

            amount0 = 0;
            amount1 = 0;

            if (token0Triggered) {
                amount0 = profit0;
                lpProfits0[poolId][lp] = 0;
            }
            if (token1Triggered) {
                amount1 = profit1;
                lpProfits1[poolId][lp] = 0;
            }

            emit AutoHedgeExecuted(lp, poolId, amount0, amount1, token0Triggered, token1Triggered);
            emit AutoHedgeReady(lp, poolId, amount0, amount1);
            emit ProfitWithdrawn(lp, poolId, amount0, amount1);
        }

        return (shouldHedge, amount0, amount1, token0Triggered, token1Triggered);
    }

    /**
     * @notice Manually trigger hedge (withdraw all profits)
     * @param poolKey Pool key
     */
    function manualHedge(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 == 0 && profit1 == 0) revert InsufficientProfit();

        emit AutoHedgeReady(msg.sender, poolId, profit0, profit1);
    }

    // ============ View Functions ============

    /**
     * @notice Get LP profits for a pool
     * @param poolKey Pool key
     * @param lp LP address
     * @return profits0 Profits in token0
     * @return profits1 Profits in token1
     */
    function getLPProfits(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 profits0, uint256 profits1)
    {
        PoolId poolId = poolKey.toId();
        return (lpProfits0[poolId][lp], lpProfits1[poolId][lp]);
    }

    /**
     * @notice Get total profits across all pools for an LP
     * @param poolKeys Array of pool keys
     * @param lp LP address
     * @return totalProfits0 Total profits in token0
     * @return totalProfits1 Total profits in token1
     */
    function getTotalProfits(PoolKey[] calldata poolKeys, address lp)
        external
        view
        returns (uint256 totalProfits0, uint256 totalProfits1)
    {
        for (uint256 i = 0; i < poolKeys.length; i++) {
            PoolId poolId = poolKeys[i].toId();
            totalProfits0 += lpProfits0[poolId][lp];
            totalProfits1 += lpProfits1[poolId][lp];
        }
        return (totalProfits0, totalProfits1);
    }

    /**
     * @notice Check if LP's profits have reached auto-hedge threshold
     * @param poolKey Pool key
     * @param lp LP address
     * @return bool True if auto-hedge threshold is met
     */
    function isAutoHedgeReady(PoolKey calldata poolKey, address lp) external view returns (bool) {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        return IFHEConfigManager(configManager).shouldAutoHedge(poolKey, lp, profit0, profit1);
    }

    /**
     * @notice Get LP's profit percentage relative to deposit for each token
     * @dev Returns percentages in basis points (1% = 100 basis points)
     * @param poolKey Pool key
     * @param lp LP address
     * @return percent0 Profit percentage for token0 in basis points
     * @return percent1 Profit percentage for token1 in basis points
     */
    function getProfitPercentages(PoolKey calldata poolKey, address lp)
        external
        view
        returns (uint256 percent0, uint256 percent1)
    {
        PoolId poolId = poolKey.toId();

        (uint256 depositedAmount0, uint256 depositedAmount1) =
            IFHEConfigManager(configManager).getDepositedAmounts(poolKey, lp);

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        percent0 = depositedAmount0 == 0 ? 0 : (profit0 * 10000) / depositedAmount0;
        percent1 = depositedAmount1 == 0 ? 0 : (profit1 * 10000) / depositedAmount1;

        return (percent0, percent1);
    }
}
