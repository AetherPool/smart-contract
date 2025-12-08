// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract LPPositionManagerTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;

    address public constant HOOK = address(0x1111);
    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant USER = address(0x5555);
    address public constant OWNER = address(0x9999);

    event LPTokenMinted(
        address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity, bool isJITEnabled
    );
    event LPTokenBurned(address indexed lp, PoolId indexed poolId, uint256 tokenId, uint128 liquidity);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        positionManager = new LPPositionManager(address(manager), "LP NFT");
        configManager = new FHEConfigManager();
        feeCalculator = new FeeCalculator();

        vm.prank(HOOK);
        feeManager = new DynamicFeeManager(OWNER);

        profitManager = new ProfitManager(address(configManager));
        jitCoordinator = new JITCoordinator(
            manager, address(positionManager), address(configManager), address(profitManager), address(feeCalculator)
        );

        deployCodeTo(
            "ZKJITLiquidityHook.sol",
            abi.encode(
                manager,
                address(positionManager),
                address(configManager),
                address(feeManager),
                address(profitManager),
                address(jitCoordinator),
                address(feeCalculator)
            ),
            hookAddress
        );
        hook = ZKJITLiquidityHook(hookAddress);

        jitCoordinator.updateHook(address(hook));
        positionManager.updateHook(address(hook));
        feeManager.updateHook(address(hook));

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        _setupTestAccounts();
    }

    function _setupTestAccounts() private {
        address[4] memory accounts = [LP1, LP2, LP3, USER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);
            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            vm.startPrank(accounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function testSinglePositionDeposit() public {
        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        vm.prank(LP1);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);

        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1After = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        assertGt(balance0Before - balance0After, 0);
        assertGt(balance1Before - balance1After, 0);
        assertGt(tokenId, 0);
        assertGt(liquidity, 0);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions.length, 1);
        assertEq(positions[0].tokenId, tokenId);
        assertTrue(positions[0].isActive);
        assertTrue(positionManager.isRegistered(key, LP1));
    }

    function testMultiplePositionsSameLP() public {
        vm.startPrank(LP1);

        (uint256 tokenId1,,,) = hook.depositLiquidityWithAmounts(key, -180, 180, 1500, 1500, true);
        (uint256 tokenId2,,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);
        (uint256 tokenId3,,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 2000, 2000, true);

        vm.stopPrank();

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions.length, 3);
        assertEq(positions[0].tokenId, tokenId1);
        assertEq(positions[1].tokenId, tokenId2);
        assertEq(positions[2].tokenId, tokenId3);

        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].isActive);
        }
    }

    function testMultipleLPs() public {
        vm.prank(LP1);
        (uint256 tokenId1,,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 2500, 2500, true);

        vm.prank(LP2);
        (uint256 tokenId2,,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 1500, 1500, true);

        vm.prank(LP3);
        (uint256 tokenId3,,,) = hook.depositLiquidityWithAmounts(key, -180, 180, 2000, 2000, true);

        LPPositionManager.LPPosition[] memory lp1Positions = positionManager.getLPPositions(key, LP1);
        LPPositionManager.LPPosition[] memory lp2Positions = positionManager.getLPPositions(key, LP2);
        LPPositionManager.LPPosition[] memory lp3Positions = positionManager.getLPPositions(key, LP3);

        assertEq(lp1Positions.length, 1);
        assertEq(lp2Positions.length, 1);
        assertEq(lp3Positions.length, 1);

        address[] memory poolLPs = positionManager.getPoolLPs(key);
        assertEq(poolLPs.length, 3);

        assertEq(positionManager.getTokenOwner(key, tokenId1), LP1);
        assertEq(positionManager.getTokenOwner(key, tokenId2), LP2);
        assertEq(positionManager.getTokenOwner(key, tokenId3), LP3);
    }

    function testPartialLiquidityRemoval() public {
        vm.prank(LP1);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 3000, 3000, true);

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        vm.prank(LP1);
        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity / 3);

        uint256 balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balance1After = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(balance0After - balance0Before, amount0);
        assertEq(balance1After - balance1Before, amount1);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertLt(positions[0].liquidity, liquidity);
        assertTrue(positions[0].isActive);
    }

    function testCompleteLiquidityRemoval() public {
        vm.prank(LP1);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);

        vm.prank(LP1);
        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity);

        assertGt(amount0, 0);
        assertGt(amount1, 0);

        LPPositionManager.LPPosition[] memory positions = positionManager.getLPPositions(key, LP1);
        assertEq(positions[0].liquidity, 0);
        assertFalse(positions[0].isActive);

        uint256 balance = positionManager.balanceOf(LP1, tokenId);
        assertEq(balance, 0);
    }

    function testPositionOwnership() public {
        vm.prank(LP1);
        (uint256 tokenId,,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 2500, 2500, true);

        address owner = positionManager.getTokenOwner(key, tokenId);
        assertEq(owner, LP1);

        vm.prank(LP2);
        vm.expectRevert(LPPositionManager.PositionNotFound.selector);
        hook.withdrawLiquidity(key, tokenId, 1000);

        vm.prank(LP1);
        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, 1000);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function testOverlappingPositionDetection() public {
        PoolId poolId = key.toId();
        int24 currentTick = 0;
        int24 tickRange = 60;

        vm.startPrank(LP1);
        hook.depositLiquidityWithAmounts(key, -180, -120, 1500, 1500, true);
        hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);
        hook.depositLiquidityWithAmounts(key, 120, 180, 1500, 1500, true);
        vm.stopPrank();

        bool hasOverlap = positionManager.hasOverlappingPosition(poolId, LP1, currentTick, tickRange);
        assertTrue(hasOverlap);

        bool noOverlap = positionManager.hasOverlappingPosition(poolId, LP2, currentTick, tickRange);
        assertFalse(noOverlap);
    }

    function testTotalLiquidityCalculation() public {
        PoolId poolId = key.toId();

        vm.startPrank(LP1);
        hook.depositLiquidityWithAmounts(key, -180, 180, 1500, 1500, true);
        (, uint128 liq2,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);
        hook.depositLiquidityWithAmounts(key, -120, 120, 2000, 2000, true);
        vm.stopPrank();

        uint128 totalLiquidity = positionManager.getTotalLiquidity(poolId, LP1);
        assertGt(totalLiquidity, 0);

        vm.prank(LP1);
        hook.withdrawLiquidity(key, 2, liq2);

        uint128 newTotal = positionManager.getTotalLiquidity(poolId, LP1);
        assertLt(newTotal, totalLiquidity);
    }

    function testUnauthorizedAccess() public {
        vm.prank(LP1);
        (uint256 tokenId,,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);

        vm.prank(USER);
        vm.expectRevert(LPPositionManager.PositionNotFound.selector);
        hook.withdrawLiquidity(key, tokenId, 1000);
    }

    function testInvalidOperations() public {
        vm.prank(LP1);
        (uint256 tokenId,,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, false);

        vm.prank(LP1);
        vm.expectRevert();
        hook.withdrawLiquidity(key, tokenId, 10000000);

        vm.prank(LP1);
        vm.expectRevert(LPPositionManager.PositionNotFound.selector);
        hook.withdrawLiquidity(key, 999, 1000);
    }

    function testJITVsPassivePositions() public {
        PoolId poolId = key.toId();

        vm.startPrank(LP1);
        hook.depositLiquidityWithAmounts(key, -120, 120, 2500, 2500, false);
        hook.depositLiquidityWithAmounts(key, -60, 60, 2500, 2500, true);
        vm.stopPrank();

        address[] memory jitLPs = positionManager.getJITEnabledLPs(key);
        assertEq(jitLPs.length, 1);
        assertEq(jitLPs[0], LP1);

        uint128 totalJITLiquidity = positionManager.getTotalLiquidity(poolId, LP1);
        assertGt(totalJITLiquidity, 0);
    }

    function testMultiPoolPositions() public {
        PoolKey memory key2;
        Currency currency0_2 = deployMintAndApproveCurrency();
        Currency currency1_2 = deployMintAndApproveCurrency();
        (key2,) = initPool(currency1_2, currency0_2, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0_2)).mint(LP1, 100000 ether);
        MockERC20(Currency.unwrap(currency1_2)).mint(LP1, 100000 ether);

        vm.startPrank(LP1);
        MockERC20(Currency.unwrap(currency0_2)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1_2)).approve(address(hook), type(uint256).max);

        hook.depositLiquidityWithAmounts(key, -60, 60, 1500, 1500, true);
        hook.depositLiquidityWithAmounts(key2, -120, 120, 2500, 2500, true);
        vm.stopPrank();

        LPPositionManager.LPPosition[] memory positions1 = positionManager.getLPPositions(key, LP1);
        LPPositionManager.LPPosition[] memory positions2 = positionManager.getLPPositions(key2, LP1);

        assertEq(positions1.length, 1);
        assertEq(positions2.length, 1);
    }

    function testGetTotalDeposited() public {
        PoolId poolId = key.toId();

        vm.startPrank(LP1);
        hook.depositLiquidityWithAmounts(key, -120, 120, 2000, 3000, true);
        hook.depositLiquidityWithAmounts(key, -60, 60, 1500, 2500, true);
        vm.stopPrank();

        (uint128 total0, uint128 total1) = positionManager.getTotalDeposited(poolId, LP1);
        assertGt(total0, 0);
        assertGt(total1, 0);
    }

    function testLiquidityCalculationHelpers() public view {
        (uint160 sqrtPriceX96,) = positionManager.getCurrentPrice(key);
        assertGt(sqrtPriceX96, 0);

        uint256 ratio = positionManager.getPriceRatio(key);
        assertGt(ratio, 0);

        (uint128 liquidity, uint256 amount0, uint256 amount1) =
            positionManager.calculateLiquidityForAmounts(key, -60, 60, 1000, 1000);
        assertGt(liquidity, 0);

        (uint256 calcAmount0, uint256 calcAmount1) =
            positionManager.calculateAmountsForLiquidity(key, -60, 60, liquidity);
        assertApproxEqAbs(calcAmount0, amount0, 2);
        assertApproxEqAbs(calcAmount1, amount1, 2);
    }

    function testERC1155Compliance() public {
        vm.prank(LP1);
        (uint256 tokenId,,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 2500, 2500, true);

        uint256 balance = positionManager.balanceOf(LP1, tokenId);
        assertEq(balance, 1);

        address owner = positionManager.getTokenOwner(key, tokenId);
        assertEq(owner, LP1);

        vm.prank(LP1);
        (uint256 tokenId2,,,) = hook.depositLiquidityWithAmounts(key, -60, 60, 2000, 2000, true);

        uint256 balance2 = positionManager.balanceOf(LP1, tokenId2);
        assertEq(balance2, 1);
    }
}
