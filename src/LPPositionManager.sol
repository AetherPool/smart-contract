// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title LPPositionManager
 * @notice Manages LP positions with ERC1155 tokens, liquidity calculations and passive/active deposits
 * @dev Enhanced with proper token minting/burning and automatic liquidity calculations
 */
contract LPPositionManager is ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Data Structures ============

    struct LPPosition {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 token0Amount;
        uint128 token1Amount;
        bool isActive;
        bool isJITEnabled; // true = active JIT, false = passive liquidity
        uint256 depositTimestamp;
    }

    // ============ Storage ============

    IPoolManager public immutable poolManager;

    mapping(PoolId => mapping(address => LPPosition[])) public lpPositions;
    mapping(PoolId => mapping(uint256 => address)) public tokenIdToLP;
    mapping(PoolId => address[]) public poolLPs;
    mapping(PoolId => mapping(address => bool)) public isLPRegistered;

    address public hook;
    uint256 public nextTokenId = 1;

    // ============ Events ============

    event LPTokenMinted(
        address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity, bool isJITEnabled
    );
    event LPTokenBurned(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);
    event LiquidityAdded(
        address indexed lp,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0,
        uint128 amount1,
        bool isJITEnabled
    );
    event LiquidityRemoved(
        address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity, uint128 amount0, uint128 amount1
    );

    // ============ Errors ============

    error Unauthorized();
    error InvalidLiquidity();
    error NotTokenOwner();
    error InsufficientLiquidity();
    error PositionNotFound();
    error InvalidTickRange();

    // ============ Modifiers ============

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(address _hook, address _poolManager, string memory _uri) ERC1155(_uri) {
        hook = _hook;
        poolManager = IPoolManager(_poolManager);
    }

    // ============ External Functions ============

    /**
     * @notice Deposit liquidity and receive ERC1155 LP token
     * @dev Calculates liquidity automatically from amounts
     * @param poolKey The pool to add liquidity to
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param amount0 Token0 deposited
     * @param amount1 Token1 deposited
     * @param depositor Address depositing liquidity
     * @param isJITEnabled True for active JIT, false for passive liquidity
     * @return tokenId Unique identifier for the LP position
     * @return liquidity Calculated liquidity amount
     */
    function depositLiquidity(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0,
        uint128 amount1,
        address depositor,
        bool isJITEnabled
    ) external onlyHook returns (uint256 tokenId, uint128 liquidity) {
        PoolId poolId = poolKey.toId();

        // Calculate liquidity from the provided amounts
        (liquidity,,) = calculateLiquidityForAmounts(poolKey, tickLower, tickUpper, amount0, amount1);

        if (liquidity == 0) revert InvalidLiquidity();

        tokenId = nextTokenId++;

        // Mint ERC1155 token to depositor
        _mint(depositor, tokenId, 1, "");

        LPPosition memory newPosition = LPPosition({
            tokenId: tokenId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            token0Amount: amount0,
            token1Amount: amount1,
            isActive: true,
            isJITEnabled: isJITEnabled,
            depositTimestamp: block.timestamp
        });

        lpPositions[poolId][depositor].push(newPosition);
        tokenIdToLP[poolId][tokenId] = depositor;

        if (!isLPRegistered[poolId][depositor]) {
            poolLPs[poolId].push(depositor);
            isLPRegistered[poolId][depositor] = true;
        }

        emit LPTokenMinted(depositor, poolId, tokenId, liquidity, isJITEnabled);
        emit LiquidityAdded(depositor, poolId, tickLower, tickUpper, liquidity, amount0, amount1, isJITEnabled);

        return (tokenId, liquidity);
    }

    /**
     * @notice Remove liquidity by burning ERC1155 LP token
     * @param liquidityDelta Amount of liquidity to remove
     */
    function removeLiquidity(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta, address withdrawer)
        external
        onlyHook
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toId();

        if (tokenIdToLP[poolId][tokenId] != withdrawer) revert NotTokenOwner();

        // Check token ownership
        if (balanceOf(withdrawer, tokenId) == 0) revert NotTokenOwner();

        LPPosition[] storage positions = lpPositions[poolId][withdrawer];
        bool found = false;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tokenId == tokenId) {
                if (positions[i].liquidity < liquidityDelta) revert InsufficientLiquidity();

                amount0 = uint128((uint256(positions[i].token0Amount) * liquidityDelta) / positions[i].liquidity);
                amount1 = uint128((uint256(positions[i].token1Amount) * liquidityDelta) / positions[i].liquidity);

                positions[i].liquidity -= liquidityDelta;
                positions[i].token0Amount -= amount0;
                positions[i].token1Amount -= amount1;

                if (positions[i].liquidity == 0) {
                    positions[i].isActive = false;
                    // Burn the ERC1155 token
                    _burn(withdrawer, tokenId, 1);
                }

                emit LPTokenBurned(withdrawer, poolId, tokenId, liquidityDelta);
                emit LiquidityRemoved(withdrawer, poolId, tokenId, liquidityDelta, amount0, amount1);

                found = true;
                break;
            }
        }

        if (!found) revert PositionNotFound();

        return (amount0, amount1);
    }

    // ============ Liquidity Calculation Functions ============

    /**
     * @notice Get current pool price (sqrtPriceX96)
     * @param poolKey Pool to query
     * @return sqrtPriceX96 Current sqrt price
     * @return tick Current tick
     */
    function getCurrentPrice(PoolKey calldata poolKey) public view returns (uint160 sqrtPriceX96, int24 tick) {
        PoolId poolId = poolKey.toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(poolId);
        return (sqrtPriceX96, tick);
    }

    /**
     * @notice Calculate liquidity for given token amounts
     * @param poolKey Pool to calculate for
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @return liquidity Calculated liquidity
     * @return amount0 Actual amount0 needed
     * @return amount1 Actual amount1 needed
     */
    function calculateLiquidityForAmounts(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (tickLower >= tickUpper) revert InvalidTickRange();

        (uint160 sqrtPriceX96, int24 currentTick) = getCurrentPrice(poolKey);

        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (currentTick < tickLower) {
            // Price below range, only token0 needed
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0Desired);
            amount0 = amount0Desired;
            amount1 = 0;
        } else if (currentTick >= tickUpper) {
            // Price above range, only token1 needed
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1Desired);
            amount0 = 0;
            amount1 = amount1Desired;
        } else {
            // Price in range, both tokens needed
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0Desired);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1Desired);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;

            // Calculate actual amounts needed for this liquidity
            (amount0, amount1) = getAmountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }

        return (liquidity, amount0, amount1);
    }

    /**
     * @notice Calculate token amounts needed for given liquidity
     * @param poolKey Pool to calculate for
     * @param tickLower Lower tick
     * @param tickUpper Upper tick
     * @param liquidity Liquidity amount
     * @return amount0 Amount of token0 needed
     * @return amount1 Amount of token1 needed
     */
    function calculateAmountsForLiquidity(PoolKey calldata poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (tickLower >= tickUpper) revert InvalidTickRange();

        (uint160 sqrtPriceX96,) = getCurrentPrice(poolKey);

        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        return getAmountsForLiquidity(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    /**
     * @notice Get price ratio (token1/token0)
     * @param poolKey Pool to query
     * @return ratio Price ratio scaled by 1e18
     */
    function getPriceRatio(PoolKey calldata poolKey) external view returns (uint256 ratio) {
        (uint160 sqrtPriceX96,) = getCurrentPrice(poolKey);

        // Price = (sqrtPriceX96 / 2^96)^2
        // Scaled to 1e18 for precision
        uint256 price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        ratio = FullMath.mulDiv(price, 1e18, FixedPoint96.Q96);

        return ratio;
    }

    // ============ Internal Helper Functions ============

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, FixedPoint96.Q96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96
        ) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    // ============ View Functions ============

    function getLPPositions(PoolKey calldata poolKey, address lp) external view returns (LPPosition[] memory) {
        PoolId poolId = poolKey.toId();
        return lpPositions[poolId][lp];
    }

    function getPoolLPs(PoolKey calldata poolKey) external view returns (address[] memory) {
        return poolLPs[poolKey.toId()];
    }

    /**
     * @notice Get only JIT-enabled LPs
     */
    function getJITEnabledLPs(PoolKey calldata poolKey) external view returns (address[] memory) {
        PoolId poolId = poolKey.toId();
        address[] memory allLPs = poolLPs[poolId];

        uint256 jitCount = 0;
        for (uint256 i = 0; i < allLPs.length; i++) {
            LPPosition[] memory positions = lpPositions[poolId][allLPs[i]];
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].isActive && positions[j].isJITEnabled) {
                    jitCount++;
                    break;
                }
            }
        }

        address[] memory jitLPs = new address[](jitCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allLPs.length; i++) {
            LPPosition[] memory positions = lpPositions[poolId][allLPs[i]];
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].isActive && positions[j].isJITEnabled) {
                    jitLPs[index++] = allLPs[i];
                    break;
                }
            }
        }

        return jitLPs;
    }

    function isRegistered(PoolKey calldata poolKey, address lp) external view returns (bool) {
        return isLPRegistered[poolKey.toId()][lp];
    }

    function getTokenOwner(PoolKey calldata poolKey, uint256 tokenId) external view returns (address) {
        return tokenIdToLP[poolKey.toId()][tokenId];
    }

    function hasOverlappingPosition(PoolId poolId, address lp, int24 currentTick, int24 tickRange)
        external
        view
        returns (bool)
    {
        LPPosition[] memory positions = lpPositions[poolId][lp];
        int24 jitLower = currentTick - tickRange;
        int24 jitUpper = currentTick + tickRange;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive && positions[i].isJITEnabled) {
                if (positions[i].tickLower <= jitUpper && positions[i].tickUpper >= jitLower) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Get total JIT-enabled liquidity for an LP
     */
    function getTotalLiquidity(PoolId poolId, address lp) external view returns (uint128) {
        LPPosition[] memory positions = lpPositions[poolId][lp];
        uint128 totalLiquidity = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive && positions[i].isJITEnabled) {
                totalLiquidity += positions[i].liquidity;
            }
        }

        return totalLiquidity;
    }

    /**
     * @notice Get total deposited token amounts for an LP
     */
    function getTotalDeposited(PoolId poolId, address lp) external view returns (uint128 total0, uint128 total1) {
        LPPosition[] memory positions = lpPositions[poolId][lp];

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].isActive) {
                total0 += positions[i].token0Amount;
                total1 += positions[i].token1Amount;
            }
        }

        return (total0, total1);
    }

    /**
     * @notice Get specific LP position by tokenId
     */
    function getPosition(PoolKey calldata poolKey, address lp, uint256 tokenId)
        external
        view
        returns (LPPosition memory)
    {
        PoolId poolId = poolKey.toId();
        LPPosition[] memory positions = lpPositions[poolId][lp];

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].tokenId == tokenId) {
                return positions[i];
            }
        }

        revert PositionNotFound();
    }
}
