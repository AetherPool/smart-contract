// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ProfitManager
 * @notice Manages LP profit tracking, hedging, and compounding operations
 * @dev Handles both manual and automatic profit management strategies
 */
contract ProfitManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Storage ============

    mapping(PoolId => mapping(address => uint256)) public lpProfits0;
    mapping(PoolId => mapping(address => uint256)) public lpProfits1;
    
    address public hook; // Main hook contract address
    address public positionManager; // Position manager contract
    address public configManager; // FHE config manager contract

    // ============ Events ============

    event ProfitHedged(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 hedgePercentage
    );

    event ProfitCompounded(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 newTokenId
    );

    event ProfitAccrued(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1
    );

    event ProfitWithdrawn(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1
    );

    // ============ Errors ============

    error Unauthorized();
    error InvalidPercentage();
    error InsufficientProfit();
    error ArrayLengthMismatch();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(
        address _hook,
        address _positionManager,
        address _configManager
    ) {
        hook = _hook;
        positionManager = _positionManager;
        configManager = _configManager;
    }

    // ============ External Functions ============

    /**
     * @notice Accrue profits to LP (called by hook after JIT operations)
     * @param poolKey Pool identifier
     * @param lp LP address
     * @param amount0 Token0 profit amount
     * @param amount1 Token1 profit amount
     */
    function accrueProfit(
        PoolKey calldata poolKey,
        address lp,
        uint256 amount0,
        uint256 amount1
    ) external onlyHook {
        PoolId poolId = poolKey.toId();
        
        lpProfits0[poolId][lp] += amount0;
        lpProfits1[poolId][lp] += amount1;

        emit ProfitAccrued(lp, poolId, amount0, amount1);
    }

    /**
     * @notice Manually hedge LP profits
     * @param poolKey The pool to hedge profits from
     * @param hedgePercentage Percentage of profits to hedge (0-100)
     */
    function hedgeProfits(
        PoolKey calldata poolKey,
        uint256 hedgePercentage
    ) external {
        if (hedgePercentage > 100) revert InvalidPercentage();
        
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 == 0 && profit1 == 0) revert InsufficientProfit();

        uint256 hedgeAmount0 = (profit0 * hedgePercentage) / 100;
        uint256 hedgeAmount1 = (profit1 * hedgePercentage) / 100;

        // Update tracked profits
        lpProfits0[poolId][msg.sender] -= hedgeAmount0;
        lpProfits1[poolId][msg.sender] -= hedgeAmount1;

        // Transfer hedged amounts
        if (hedgeAmount0 > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, hedgeAmount0);
        }
        if (hedgeAmount1 > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, hedgeAmount1);
        }

        emit ProfitHedged(msg.sender, poolId, hedgeAmount0, hedgeAmount1, hedgePercentage);
    }

    /**
     * @notice Automatically hedge profits based on LP configuration
     * @param poolKey Pool identifier
     * @param lp LP address
     */
    function autoHedgeProfits(
        PoolKey calldata poolKey,
        address lp
    ) external onlyHook {
        PoolId poolId = poolKey.toId();

        // Get hedge percentage from config manager
        // For demo: using 50% (in production, decrypt from FHE config)
        uint256 hedgePercentage = 50;

        uint256 profit0 = lpProfits0[poolId][lp];
        uint256 profit1 = lpProfits1[poolId][lp];

        if (profit0 > 0 || profit1 > 0) {
            uint256 hedgeAmount0 = (profit0 * hedgePercentage) / 100;
            uint256 hedgeAmount1 = (profit1 * hedgePercentage) / 100;

            // Update tracked profits
            lpProfits0[poolId][lp] -= hedgeAmount0;
            lpProfits1[poolId][lp] -= hedgeAmount1;

            // Transfer hedged amounts (in production, handle properly)
            if (hedgeAmount0 > 0) {
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(lp, hedgeAmount0);
            }
            if (hedgeAmount1 > 0) {
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(lp, hedgeAmount1);
            }

            emit ProfitHedged(lp, poolId, hedgeAmount0, hedgeAmount1, hedgePercentage);
        }
    }

    /**
     * @notice Compound profits into new liquidity position
     * @param poolKey The pool to compound profits in
     * @param tickLower Lower tick for new position
     * @param tickUpper Upper tick for new position
     */
    function compoundProfits(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper
    ) external returns (uint256 tokenId) {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 == 0 || profit1 == 0) revert InsufficientProfit();

        // Reset profits
        lpProfits0[poolId][msg.sender] = 0;
        lpProfits1[poolId][msg.sender] = 0;

        // Calculate liquidity from profits (simplified)
        uint128 liquidityFromProfits = uint128((profit0 + profit1) / 2);

        // Approve position manager to spend profits
        IERC20(Currency.unwrap(poolKey.currency0)).approve(positionManager, profit0);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(positionManager, profit1);

        // Create new position through position manager
        // Note: In production, add proper interface call
        // tokenId = ILPPositionManager(positionManager).depositLiquidity(
        //     poolKey,
        //     tickLower,
        //     tickUpper,
        //     liquidityFromProfits,
        //     uint128(profit0),
        //     uint128(profit1),
        //     msg.sender
        // );

        emit ProfitCompounded(
            msg.sender,
            poolId,
            profit0,
            profit1,
            tokenId
        );

        return tokenId;
    }

    /**
     * @notice Withdraw all accumulated profits
     * @param poolKey The pool to withdraw profits from
     */
    function withdrawProfits(PoolKey calldata poolKey) external {
        PoolId poolId = poolKey.toId();

        uint256 profit0 = lpProfits0[poolId][msg.sender];
        uint256 profit1 = lpProfits1[poolId][msg.sender];

        if (profit0 == 0 && profit1 == 0) revert InsufficientProfit();

        // Reset profits
        lpProfits0[poolId][msg.sender] = 0;
        lpProfits1[poolId][msg.sender] = 0;

        // Transfer all profits
        if (profit0 > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, profit0);
        }
        if (profit1 > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, profit1);
        }

        emit ProfitWithdrawn(msg.sender, poolId, profit0, profit1);
    }

    /**
     * @notice Batch hedge profits across multiple pools
     * @param poolKeys Array of pools to hedge
     * @param hedgePercentages Array of hedge percentages
     */
    function batchHedgeProfits(
        PoolKey[] calldata poolKeys,
        uint256[] calldata hedgePercentages
    ) external {
        if (poolKeys.length != hedgePercentages.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < poolKeys.length; i++) {
            if (hedgePercentages[i] > 100) revert InvalidPercentage();
            
            PoolId poolId = poolKeys[i].toId();
            uint256 profit0 = lpProfits0[poolId][msg.sender];
            uint256 profit1 = lpProfits1[poolId][msg.sender];

            if (profit0 > 0 || profit1 > 0) {
                uint256 hedgeAmount0 = (profit0 * hedgePercentages[i]) / 100;
                uint256 hedgeAmount1 = (profit1 * hedgePercentages[i]) / 100;

                // Update tracked profits
                lpProfits0[poolId][msg.sender] -= hedgeAmount0;
                lpProfits1[poolId][msg.sender] -= hedgeAmount1;

                // Transfer hedged amounts
                if (hedgeAmount0 > 0) {
                    IERC20(Currency.unwrap(poolKeys[i].currency0)).transfer(
                        msg.sender,
                        hedgeAmount0
                    );
                }
                if (hedgeAmount1 > 0) {
                    IERC20(Currency.unwrap(poolKeys[i].currency1)).transfer(
                        msg.sender,
                        hedgeAmount1
                    );
                }

                emit ProfitHedged(
                    msg.sender,
                    poolId,
                    hedgeAmount0,
                    hedgeAmount1,
                    hedgePercentages[i]
                );
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get LP profits for a pool
     * @param poolKey Pool to query
     * @param lp LP address
     * @return profits0 Token0 profits
     * @return profits1 Token1 profits
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
     * @param poolKeys Array of pools to check
     * @param lp LP address
     * @return totalProfits0 Total token0 profits
     * @return totalProfits1 Total token1 profits
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
}