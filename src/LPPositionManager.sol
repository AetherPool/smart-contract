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
 * @notice Manages LP positions with ERC1155 tokens, supporting both passive liquidity and active JIT strategies
 * @dev Automatically calculates liquidity from token amounts based on current pool price
 */
contract LPPositionManager is ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============ Structs ============

    struct LPPosition {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 token0Amount;
        uint128 token1Amount;
        bool isActive;
        bool isJITEnabled;
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
    event HookUpdated(address indexed newHook);

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
     * @notice Deposit liquidity and receive ERC1155 LP token
     * @param poolKey The pool to add liquidity to
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param amount0 Token0 deposited
     * @param amount1 Token1 deposited
     * @param depositor Address depositing liquidity
     * @param isJITEnabled True for active JIT participation, false for passive liquidity
     * @return tokenId Unique identifier for the LP position
     * @return liquidity Calculated liquidity amount
     */
    function addLiquidity(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0,
        uint128 amount1,
        address depositor,
        bool isJITEnabled
    ) external onlyHook returns (uint256 tokenId, uint128 liquidity) {
        PoolId poolId = poolKey.toId();

        (liquidity,,) = calculateLiquidityForAmounts(poolKey, tickLower, tickUpper, amount0, amount1);
        if (liquidity == 0) revert InvalidLiquidity();

        tokenId = nextTokenId++;
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
     * @param poolKey The pool
     * @param tokenId Position token ID
     * @param liquidityDelta Amount of liquidity to remove
     * @param withdrawer Address withdrawing liquidity
     * @return amount0 Amount of token0 withdrawn
     * @return amount1 Amount of token1 withdrawn
     */
    function removeLiquidity(PoolKey calldata poolKey, uint256 tokenId, uint128 liquidityDelta, address withdrawer)
        external
        onlyHook
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toId();

        if (tokenIdToLP[poolId][tokenId] != withdrawer) revert NotTokenOwner();
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

    /**
     * @notice Calculate liquidity for given token amounts based on current pool price
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
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0Desired);
            amount0 = amount0Desired;
            amount1 = 0;
        } else if (currentTick >= tickUpper) {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1Desired);
            amount0 = 0;
            amount1 = amount1Desired;
        } else {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0Desired);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1Desired);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
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

    // ============ Internal Functions ============

    function getCurrentPrice(PoolKey calldata poolKey) public view returns (uint160 sqrtPriceX96, int24 tick) {
        PoolId poolId = poolKey.toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(poolId);
        return (sqrtPriceX96, tick);
    }

    function getPriceRatio(PoolKey calldata poolKey) external view returns (uint256 ratio) {
        (uint160 sqrtPriceX96,) = getCurrentPrice(poolKey);
        uint256 price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        ratio = FullMath.mulDiv(price, 1e18, FixedPoint96.Q96);
        return ratio;
    }

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
