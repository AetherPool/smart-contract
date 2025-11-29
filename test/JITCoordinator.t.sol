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
import {HookSwapRouter} from "../src/HookSwapRouter.sol";
import {SlippageLib} from "../src/libraries/SlippageLib.sol";

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
    HookSwapRouter public hookSwapRouter;

    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant TRADER = address(0x5555);
    address public constant OWNER = address(0x9999);

    uint128 public constant LARGE_SWAP = 500000;

    // ============ Storage for Test State ============

    struct TestSwapState {
        address[] eligibleLPs;
        uint128[] contributions;
        uint256 expectedSwapId;
        uint256[] initialProfits0;
        uint256[] initialProfits1;
    }

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

        hookSwapRouter = new HookSwapRouter(manager);

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        _setupTestAccounts();
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
            MockERC20(Currency.unwrap(currency0)).approve(address(hookSwapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(address(hookSwapRouter), type(uint256).max);
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
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50000, 50000, false
        );
        vm.stopPrank();
    }

    function _setupMultipleLPs() private {
        _setupLP1();
        _setupLP2();
        _setupLP3();
        _decryptAllLPs();
    }

    function _setupLP1() private {
        InEuint128 memory enc1MinSwap = createInEuint128(800, LP1);
        InEuint32 memory enc1Hedge0 = createInEuint32(20, LP1);
        InEuint32 memory enc1Hedge1 = createInEuint32(25, LP1);

        vm.startPrank(LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, false);
        hook.depositLiquidityWithAmounts(key, -240, 240, 400, 400, true);
        vm.stopPrank();
    }

    function _setupLP2() private {
        InEuint128 memory enc2MinSwap = createInEuint128(1200, LP2);
        InEuint32 memory enc2Hedge0 = createInEuint32(40, LP2);
        InEuint32 memory enc2Hedge1 = createInEuint32(35, LP2);

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, true);
        hook.depositLiquidityWithAmounts(key, -120, 120, 500, 500, true);
        vm.stopPrank();
    }

    function _setupLP3() private {
        InEuint128 memory enc3MinSwap = createInEuint128(1500, LP3);
        InEuint32 memory enc3Hedge0 = createInEuint32(60, LP3);
        InEuint32 memory enc3Hedge1 = createInEuint32(55, LP3);

        vm.startPrank(LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3Hedge0, enc3Hedge1, true);
        hook.depositLiquidityWithAmounts(key, -60, 60, 600, 600, true);
        vm.stopPrank();
    }

    function _decryptAllLPs() private {
        configManager.decryptMinSwapSize(key, LP1);
        configManager.decryptMinSwapSize(key, LP2);
        configManager.decryptMinSwapSize(key, LP3);
        vm.warp(block.timestamp + 15);
    }

    // ============ Original Tests (Unchanged) ============

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
        assertEq(eligibleLPs1.length, 1);

        (address[] memory eligibleLPs2,) = jitCoordinator.evaluateMultiLPJIT(key, 1500);
        assertGt(eligibleLPs2.length, 2);

        (address[] memory eligibleLPs3,) = jitCoordinator.evaluateMultiLPJIT(key, 5000);
        assertEq(eligibleLPs3.length, 3);
    }

    /**
     * @notice Comprehensive test of JIT lifecycle via swap
     */
    function testJITLifecycleViaSwap() public {
        _addBaseLiquidity();
        _setupMultipleLPs();

        // Step 1: Evaluate and prepare
        TestSwapState memory state = _prepareSwapTest(LARGE_SWAP);

        // Step 2: Execute swap
        _executeSwapForTest(state);

        // Step 3: Verify results
        _verifySwapResults(state);
    }

    /**
     * @notice Prepare swap test by evaluating LPs and storing initial state
     */
    function _prepareSwapTest(uint128 swapAmount) private returns (TestSwapState memory state) {
        // Evaluate eligible LPs
        (state.eligibleLPs, state.contributions) = jitCoordinator.evaluateMultiLPJIT(key, swapAmount);
        assertEq(state.eligibleLPs.length, 3, "Should have 3 eligible LPs");

        // Decrypt hedge percentages for all LPs
        _decryptHedgePercentages(state.eligibleLPs);

        // Store initial profits
        state.initialProfits0 = new uint256[](state.eligibleLPs.length);
        state.initialProfits1 = new uint256[](state.eligibleLPs.length);

        _storeInitialProfits(state);

        // Get expected swap ID
        state.expectedSwapId = jitCoordinator.getNextSwapId();

        return state;
    }

    /**
     * @notice Decrypt hedge percentages for eligible LPs
     */
    function _decryptHedgePercentages(address[] memory lps) private {
        for (uint256 i = 0; i < lps.length; i++) {
            configManager.decryptHedgePercentage(key, lps[i]);
        }
        vm.warp(block.timestamp + 10);
    }

    /**
     * @notice Store initial profit values for all LPs
     */
    function _storeInitialProfits(TestSwapState memory state) private view {
        for (uint256 i = 0; i < state.eligibleLPs.length; i++) {
            (state.initialProfits0[i], state.initialProfits1[i]) = profitManager.getLPProfits(key, state.eligibleLPs[i]);
        }
    }

    /**
     * @notice Execute the swap transaction
     */
    function _executeSwapForTest(TestSwapState memory) private {
        uint128 swapAmount = 100000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 slippageBps = 100; // 1%

        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, slippageBps);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            swapAmount,
            minOut,
            block.timestamp + 10 minutes
        );
    }

    /**
     * @notice Verify swap results and profit distribution
     */
    function _verifySwapResults(TestSwapState memory state) private view {
        // Verify JIT position is no longer active
        bool isActive = jitCoordinator.isJITActive(state.expectedSwapId);
        assertFalse(isActive, "JIT should be inactive after swap");

        // Verify each LP received profits
        _verifyLPProfits(state);
    }

    /**
     * @notice Verify that each LP received proportional profits
     */
    function _verifyLPProfits(TestSwapState memory state) private view {
        for (uint256 i = 0; i < state.eligibleLPs.length; i++) {
            _verifyIndividualLPProfit(
                state.eligibleLPs[i], state.initialProfits0[i], state.initialProfits1[i], state.contributions[i]
            );
        }
    }

    /**
     * @notice Verify individual LP's profit increase
     */
    function _verifyIndividualLPProfit(address lp, uint256 initialProfit0, uint256 initialProfit1, uint128 contribution)
        private
        view
    {
        (uint256 currentProfit0, uint256 currentProfit1) = profitManager.getLPProfits(key, lp);

        // Verify profits increased
        assertTrue(currentProfit0 > initialProfit0 || currentProfit1 > initialProfit1, "LP profits should increase");

        // Calculate total profit increase
        uint256 profitIncrease = (currentProfit0 - initialProfit0) + (currentProfit1 - initialProfit1);

        // Verify LPs with contributions received profits
        if (contribution > 0) {
            assertGt(profitIncrease, 0, "LP with contribution should earn profit");
        }
    }

    /* ------------- Additional Tests ------------- */

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
        assertEq(eligibleLPs.length, 3);

        _decryptHedgePercentages(eligibleLPs);

        uint256 swapId = jitCoordinator.getNextSwapId();
        _executeSimpleSwap();

        bool isActive = jitCoordinator.isJITActive(swapId);
        assertFalse(isActive);

        (uint256 fees0, uint256 fees1) = jitCoordinator.getJITFees(swapId);
        assertTrue(fees0 > 0 || fees1 > 0);
    }

    function _executeSimpleSwap() private {
        uint128 swapAmount = 100000;
        uint256 priceRatio = hook.getPriceRatio(key);
        uint256 minOut = SlippageLib.calculateMinOutput(swapAmount, priceRatio, true, 100);

        vm.prank(TRADER);
        hookSwapRouter.swapExactInputForOutput(
            key,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            swapAmount,
            minOut,
            block.timestamp + 10 minutes
        );
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

        assertApproxEqAbs(hookBalance0, depositAmount0, 2);
        assertApproxEqAbs(hookBalance1, depositAmount1, 2);
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

        InEuint128 memory enc2MinSwap = createInEuint128(1200, LP2);
        InEuint32 memory enc2Hedge0 = createInEuint32(40, LP2);
        InEuint32 memory enc2Hedge1 = createInEuint32(35, LP2);

        vm.startPrank(LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, false);
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
