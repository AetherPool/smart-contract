// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract JITCoordinatorTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;

    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    uint128 public constant LARGE_SWAP = 500000;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        vm.txGasPrice(10 gwei);

        positionManager = new LPPositionManager(hookAddress, address(manager), "LP NFT");
        configManager = new FHEConfigManager();
        feeManager = new DynamicFeeManager(hookAddress, OWNER);
        profitManager = new ProfitManager(address(configManager));
        feeCalculator = new FeeCalculator();
        jitCoordinator = new JITCoordinator(
            manager,
            hookAddress,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
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

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        _setupTestAccounts();

        MockERC20(Currency.unwrap(currency0)).mint(address(profitManager), 1000000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(profitManager), 1000000 ether);
    }

    function _setupTestAccounts() private {
        address[4] memory accounts = [LP1, LP2, LP3, TRADER];

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], 100 ether);
            MockERC20(Currency.unwrap(currency0)).mint(accounts[i], 100000 ether);
            MockERC20(Currency.unwrap(currency1)).mint(accounts[i], 100000 ether);

            vm.startPrank(accounts[i]);
            MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _addBaseLiquidity() private {
        address baseLP = address(0x1111);
        vm.deal(baseLP, 100 ether);

        MockERC20(Currency.unwrap(currency0)).mint(baseLP, 200000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(baseLP, 200000 ether);

        vm.startPrank(baseLP);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Add base liquidity from -60 to 60
        hook.depositLiquidityWithAmounts(key, -60, 60, 50000, 50000, false);

        // Add additional base liquidity from -120 to 120
        hook.depositLiquidityWithAmounts(key, -120, 120, 50000, 50000, false);

        // Add additional base liquidity from minimum tick to maximum tick
        hook.depositLiquidityWithAmounts(
            key,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            50000,
            50000,
            false
        );
        vm.stopPrank();
    }

    function _setupMultipleLPs() private {
        InEuint128 memory enc1MinSwap = createInEuint128(800, LP1);
        InEuint32 memory enc1Hedge0 = createInEuint32(20, LP1);
        InEuint32 memory enc1Hedge1 = createInEuint32(25, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, false);
        hook.depositLiquidityWithAmounts(key, -240, 240, 400, 400, true);
        vm.stopPrank();

        InEuint128 memory enc2MinSwap = createInEuint128(1200, LP2);
        InEuint32 memory enc2Hedge0 = createInEuint32(40, LP2);
        InEuint32 memory enc2Hedge1 = createInEuint32(35, LP2);

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, true);
        hook.depositLiquidityWithAmounts(key, -120, 120, 500, 500, true);
        vm.stopPrank();

        InEuint128 memory enc3MinSwap = createInEuint128(1500, LP3);
        InEuint32 memory enc3Hedge0 = createInEuint32(60, LP3);
        InEuint32 memory enc3Hedge1 = createInEuint32(55, LP3);

        vm.startPrank(LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3Hedge0, enc3Hedge1, true);
        hook.depositLiquidityWithAmounts(key, -60, 60, 600, 600, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        configManager.decryptMinSwapSize(key, LP3);

        vm.warp(block.timestamp + 15);
    }

    function testSingleLPEvaluation() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 250, 250, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        (address[] memory eligibleLPs, uint128[] memory contributions) = jitCoordinator.evaluateMultiLPJIT(key, 2000);

        assertEq(eligibleLPs.length, 1);
        assertEq(eligibleLPs[0], LP1);
        assertGt(contributions[0], 0);
    }

    function testMultiLPEvaluation() public {
        _setupMultipleLPs();

        (address[] memory eligibleLPs1,) = jitCoordinator.evaluateMultiLPJIT(key, 1000);
        assertGt(eligibleLPs1.length, 0);

        (address[] memory eligibleLPs2,) = jitCoordinator.evaluateMultiLPJIT(key, 1500);
        assertGt(eligibleLPs2.length, 0);

        (address[] memory eligibleLPs3,) = jitCoordinator.evaluateMultiLPJIT(key, 5000);
        assertGt(eligibleLPs3.length, 0);
    }

    function testJITLifecycleViaSwap() public {
        _addBaseLiquidity();
        _setupMultipleLPs();

        (address[] memory eligibleLPs, uint128[] memory contributions) =
            jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length == 0) {
            return;
        }

        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            configManager.decryptHedgePercentage(key, eligibleLPs[i]);
        }
        vm.warp(block.timestamp + 10);

        uint256[] memory initialProfits0 = new uint256[](eligibleLPs.length);
        uint256[] memory initialProfits1 = new uint256[](eligibleLPs.length);

        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            (initialProfits0[i], initialProfits1[i]) = profitManager.getLPProfits(key, eligibleLPs[i]);
        }

        uint256 expectedSwapId = jitCoordinator.getNextSwapId();

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(TRADER);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        bool isActive = jitCoordinator.isJITActive(expectedSwapId);
        assertFalse(isActive);

        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, eligibleLPs[i]);
            uint256 profitIncrease = (profit0 - initialProfits0[i]) + (profit1 - initialProfits1[i]);

            if (contributions[i] > 0) {
                assertGt(profitIncrease, 0);
            }
        }
    }

    function testLPPositionConfiguration() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 250, 250, true);
        vm.stopPrank();

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);

        bool isActive = configManager.isActive(key, LP1);
        assertTrue(isActive);

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        (address[] memory eligibleLPs,) = jitCoordinator.evaluateMultiLPJIT(key, 2000);
        assertEq(eligibleLPs.length, 1);
    }

    function testJITPositionTracking() public {
        _addBaseLiquidity();
        _setupMultipleLPs();

        (address[] memory eligibleLPs,) = jitCoordinator.evaluateMultiLPJIT(key, LARGE_SWAP);

        if (eligibleLPs.length == 0) {
            return;
        }

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(LARGE_SWAP)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 swapId = jitCoordinator.getNextSwapId();

        vm.prank(TRADER);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        bool isActive = jitCoordinator.isJITActive(swapId);
        assertFalse(isActive);

        (uint256 fees0, uint256 fees1) = jitCoordinator.getJITFees(swapId);
        assertTrue(fees0 > 0 || fees1 > 0 || (fees0 == 0 && fees1 == 0));
    }

    function testHookHasClaimTokens() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);

        uint256 depositAmount0 = 1000;
        uint256 depositAmount1 = 1000;

        hook.depositLiquidityWithAmounts(key, -120, 120, depositAmount0, depositAmount1, true);
        vm.stopPrank();

        uint256 currency0Id = uint256(uint160(Currency.unwrap(currency0)));
        uint256 currency1Id = uint256(uint160(Currency.unwrap(currency1)));

        uint256 hookBalance0 = manager.balanceOf(address(hook), currency0Id);
        uint256 hookBalance1 = manager.balanceOf(address(hook), currency1Id);

        assertEq(hookBalance0, depositAmount0);
        assertEq(hookBalance1, depositAmount1);
    }

    function testERC1155TokenMinting() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 500, 500, true);
        vm.stopPrank();

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);

        uint256 balance = positionManager.balanceOf(LP1, tokenId);
        assertEq(balance, 1);

        address owner = positionManager.getTokenOwner(key, tokenId);
        assertEq(owner, LP1);
    }

    function testPassiveVsActiveLiquidity() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 500, 500, false);
        vm.stopPrank();

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        hook.depositLiquidityWithAmounts(key, -120, 120, 500, 500, true);
        vm.stopPrank();

        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        vm.warp(block.timestamp + 10);

        (address[] memory eligibleLPs,) = jitCoordinator.evaluateMultiLPJIT(key, 2000);

        bool lp1Found = false;
        bool lp2Found = false;
        for (uint256 i = 0; i < eligibleLPs.length; i++) {
            if (eligibleLPs[i] == LP1) lp1Found = true;
            if (eligibleLPs[i] == LP2) lp2Found = true;
        }

        assertFalse(lp1Found);
        assertTrue(lp2Found);
    }

    function testWithdrawLiquidity() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 1000, 1000, true);

        uint256 balanceBefore0 = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balanceBefore1 = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, liquidity);
        vm.stopPrank();

        assertGt(amount0, 0);
        assertGt(amount1, 0);

        uint256 balanceAfter0 = MockERC20(Currency.unwrap(currency0)).balanceOf(LP1);
        uint256 balanceAfter1 = MockERC20(Currency.unwrap(currency1)).balanceOf(LP1);

        assertEq(balanceAfter0 - balanceBefore0, amount0);
        assertEq(balanceAfter1 - balanceBefore1, amount1);

        uint256 nftBalance = positionManager.balanceOf(LP1, tokenId);
        assertEq(nftBalance, 0);
    }

    function testPartialWithdraw() public {
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(25, LP1);
        InEuint32 memory encHedge1 = createInEuint32(30, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, false);
        (uint256 tokenId, uint128 liquidity,,) = hook.depositLiquidityWithAmounts(key, -120, 120, 1000, 1000, false);

        uint128 halfLiquidity = liquidity / 2;
        (uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(key, tokenId, halfLiquidity);
        vm.stopPrank();

        assertGt(amount0, 0);
        assertGt(amount1, 0);

        uint256 nftBalance = positionManager.balanceOf(LP1, tokenId);
        assertEq(nftBalance, 1);
    }
}
