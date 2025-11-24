// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFHEConfigManager} from "./interfaces/IFHEConfigManager.sol";

/**
 * @title ProfitManager
 * @notice Manages LP profit tracking and withdrawal operations
 * @dev Enhanced to track tokens separately and trigger hedge when either hits threshold
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
     */
    function accrueProfit(PoolKey calldata poolKey, address lp, uint256 amount0, uint256 amount1) external {
        PoolId poolId = poolKey.toId();

        lpProfits0[poolId][lp] += amount0;
        lpProfits1[poolId][lp] += amount1;

        emit ProfitAccrued(lp, poolId, amount0, amount1);
    }

    /**
     * @notice Withdraw all accumulated profits
     */
    function withdrawProfits(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 == 0 && profit1 == 0) revert InsufficientProfit();

        if (profit0 > 0) {
            lpProfits0[poolId][msg.sender] = 0;
            IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, profit0);
        }
        if (profit1 > 0) {
            lpProfits1[poolId][msg.sender] = 0;
            IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, profit1);
        }

        emit ProfitWithdrawn(msg.sender, poolId, profit0, profit1);
    }

    /**
     * @notice Withdraw partial profits
     */
    function withdrawPartialProfits(PoolKey calldata poolKey, uint256 amount0, uint256 amount1) external {
        PoolId poolId = poolKey.toId();

        uint256 availableProfit0 = lpProfits0[poolId][msg.sender];
        uint256 availableProfit1 = lpProfits1[poolId][msg.sender];

        if (amount0 > availableProfit0 || amount1 > availableProfit1) {
            revert InsufficientProfit();
        }

        if (availableProfit0 == 0 && availableProfit1 == 0) revert InsufficientProfit();

        if (amount0 > 0) {
            lpProfits0[poolId][msg.sender] -= amount0;
            IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            lpProfits1[poolId][msg.sender] -= amount1;
            IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, amount1);
        }

        emit ProfitWithdrawn(msg.sender, poolId, amount0, amount1);
    }

    /**
     * @notice Check and execute auto-hedge if threshold is met for either token
     * @dev Called by JITCoordinator after fee distribution
     */
    function checkAndExecuteAutoHedge(PoolKey calldata poolKey, address lp) external {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        // Check if auto-hedge should trigger (either token)
        bool shouldHedge = IFHEConfigManager(configManager).shouldAutoHedge(poolKey, lp, profit0, profit1);

        if (shouldHedge) {
            // Get which tokens triggered
            (bool token0Triggered, bool token1Triggered) =
                IFHEConfigManager(configManager).getHedgeTriggers(poolKey, lp, profit0, profit1);

            // Transfer accumulated profits
            if (token0Triggered) {
                lpProfits0[poolId][lp] = 0;
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(lp, profit0);
            }
            if (token1Triggered) {
                lpProfits1[poolId][lp] = 0;
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(lp, profit1);
            }

            emit AutoHedgeExecuted(lp, poolId, profit0, profit1, token0Triggered, token1Triggered);
            emit ProfitWithdrawn(lp, poolId, profit0, profit1);
        }
    }

    /**
     * @notice Manually trigger hedge (withdraw all profits)
     */
    function manualHedge(PoolKey calldata poolKey) external {
        this.withdrawProfits(poolKey);
    }

    // ============ View Functions ============

    /**
     * @notice Get LP profits for a pool
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
