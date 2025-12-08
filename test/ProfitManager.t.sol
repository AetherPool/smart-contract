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
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract ProfitManagerTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FHEConfigManager public configManager;
    LPPositionManager public positionManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;
    ZKJITLiquidityHook public hook;
    FeeCalculator public feeCalculator;

    address public constant HOOK = address(0x1111);
    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant LP3 = address(0x4444);
    address public constant OWNER = address(0x9999);

    PoolKey public key2;

    event ProfitAccrued(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ProfitWithdrawn(address indexed lp, PoolId indexed poolId, uint256 amount0, uint256 amount1);

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
        address[3] memory accounts = [LP1, LP2, LP3];

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

    function testProfitAccrual() public {
        vm.expectEmit(true, true, true, true);
        emit ProfitAccrued(LP1, key.toId(), 1000, 1500);
        profitManager.accrueProfit(key, LP1, 1000, 1500);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1000);
        assertEq(profit1, 1500);

        profitManager.accrueProfit(key, LP1, 500, 750);

        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1500);
        assertEq(profit1, 2250);
    }

    function testFullWithdrawal() public {
        profitManager.accrueProfit(key, LP1, 1500, 2000);

        vm.prank(LP1);
        vm.expectEmit(true, true, true, true);
        emit ProfitWithdrawn(LP1, key.toId(), 1500, 2000);
        (uint256 withdrawn0, uint256 withdrawn1) = profitManager.withdrawProfits(key, LP1);

        assertEq(withdrawn0, 1500);
        assertEq(withdrawn1, 2000);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0);
        assertEq(profit1, 0);
    }

    function testPartialWithdrawal() public {
        profitManager.accrueProfit(key, LP1, 2000, 3000);

        vm.prank(LP1);
        (uint256 withdrawn0, uint256 withdrawn1) = profitManager.withdrawPartialProfits(key, LP1, 800, 1200);

        assertEq(withdrawn0, 800);
        assertEq(withdrawn1, 1200);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1200);
        assertEq(profit1, 1800);
    }

    function testMultipleLPProfitTracking() public {
        profitManager.accrueProfit(key, LP1, 1000, 1500);
        profitManager.accrueProfit(key, LP2, 2000, 2500);
        profitManager.accrueProfit(key, LP3, 1500, 2000);

        (uint256 lp1Profit0, uint256 lp1Profit1) = profitManager.getLPProfits(key, LP1);
        (uint256 lp2Profit0, uint256 lp2Profit1) = profitManager.getLPProfits(key, LP2);
        (uint256 lp3Profit0, uint256 lp3Profit1) = profitManager.getLPProfits(key, LP3);

        assertEq(lp1Profit0, 1000);
        assertEq(lp2Profit0, 2000);
        assertEq(lp3Profit0, 1500);

        vm.prank(LP2);
        profitManager.withdrawPartialProfits(key, LP2, 600, 750);

        (lp1Profit0, lp1Profit1) = profitManager.getLPProfits(key, LP1);
        (lp2Profit0, lp2Profit1) = profitManager.getLPProfits(key, LP2);
        (lp3Profit0, lp3Profit1) = profitManager.getLPProfits(key, LP3);

        assertEq(lp1Profit0, 1000);
        assertEq(lp2Profit0, 1400);
        assertEq(lp3Profit0, 1500);
    }

    function testTotalProfitsAcrossPools() public {
        Currency currency0_2 = deployMintAndApproveCurrency();
        Currency currency1_2 = deployMintAndApproveCurrency();
        (key2,) = initPool(currency1_2, currency0_2, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        profitManager.accrueProfit(key, LP1, 1000, 1500);
        profitManager.accrueProfit(key2, LP1, 2000, 2500);

        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = key;
        pools[1] = key2;

        (uint256 totalProfit0, uint256 totalProfit1) = profitManager.getTotalProfits(pools, LP1);

        assertEq(totalProfit0, 3000);
        assertEq(totalProfit1, 4000);
    }

    function testInvalidOperations() public {
        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.withdrawProfits(key, LP1);

        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.withdrawPartialProfits(key, LP1, 100, 100);
    }

    function testWithdrawExcessiveAmount() public {
        profitManager.accrueProfit(key, LP1, 1000, 1500);

        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.withdrawPartialProfits(key, LP1, 2000, 1500);

        vm.prank(LP1);
        vm.expectRevert(ProfitManager.InsufficientProfit.selector);
        profitManager.withdrawPartialProfits(key, LP1, 1000, 2000);
    }

    function testGetProfitPercentages() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);
        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 10000, 20000);
        profitManager.accrueProfit(key, LP1, 2000, 4000);

        (uint256 percent0, uint256 percent1) = profitManager.getProfitPercentages(key, LP1);

        assertEq(percent0, 2000);
        assertEq(percent1, 2000);
    }

    function testIsAutoHedgeReady() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(40, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);
        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 1000, 1000);
        configManager.decryptHedgePercentage(key, LP1);
        vm.warp(block.timestamp + 10);

        bool ready = profitManager.isAutoHedgeReady(key, LP1);
        assertFalse(ready);

        profitManager.accrueProfit(key, LP1, 600, 500);

        ready = profitManager.isAutoHedgeReady(key, LP1);
        assertTrue(ready);
    }

    function testCheckAndExecuteAutoHedge() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(40, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);
        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 1000, 1000);
        profitManager.accrueProfit(key, LP1, 600, 500);

        configManager.decryptHedgePercentage(key, LP1);
        vm.warp(block.timestamp + 10);

        (bool shouldHedge, uint256 amount0, uint256 amount1, bool token0Triggered, bool token1Triggered) =
            profitManager.checkAndExecuteAutoHedge(key, LP1);

        assertTrue(shouldHedge);
        assertEq(amount0, 600);
        assertEq(amount1, 500);
        assertTrue(token0Triggered);
        assertTrue(token1Triggered);
    }

    function testZeroProfitAccrual() public {
        profitManager.accrueProfit(key, LP1, 0, 0);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0);
        assertEq(profit1, 0);
    }

    function testLargeProfitAccumulation() public {
        profitManager.accrueProfit(key, LP1, 1000000 ether, 2000000 ether);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 1000000 ether);
        assertEq(profit1, 2000000 ether);

        vm.prank(LP1);
        (uint256 withdrawn0, uint256 withdrawn1) = profitManager.withdrawProfits(key, LP1);
        assertEq(withdrawn0, 1000000 ether);
        assertEq(withdrawn1, 2000000 ether);
    }

    function testSequentialOperations() public {
        profitManager.accrueProfit(key, LP1, 5000, 7000);

        vm.prank(LP1);
        profitManager.withdrawPartialProfits(key, LP1, 1250, 1750);

        profitManager.accrueProfit(key, LP1, 3000, 4000);

        (uint256 profit0, uint256 profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 6750);
        assertEq(profit1, 9250);

        vm.prank(LP1);
        profitManager.withdrawProfits(key, LP1);

        (profit0, profit1) = profitManager.getLPProfits(key, LP1);
        assertEq(profit0, 0);
        assertEq(profit1, 0);
    }
}
