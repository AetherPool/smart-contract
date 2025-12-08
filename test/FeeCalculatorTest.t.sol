// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";

import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract FeeCalculatorTest is Test, Deployers, CoFheTest {
    using PoolIdLibrary for PoolKey;

    FeeCalculator public feeCalculator;
    ZKJITLiquidityHook public hook;
    LPPositionManager public positionManager;
    FHEConfigManager public configManager;
    DynamicFeeManager public feeManager;
    ProfitManager public profitManager;
    JITCoordinator public jitCoordinator;

    address public constant HOOK = address(0x1111);
    address public constant LP1 = address(0x2222);
    address public constant LP2 = address(0x3333);
    address public constant OWNER = address(0x9999);

    event FeesCalculated(PoolId indexed poolId, uint256 fees0, uint256 fees1, uint256 feeGrowth0, uint256 feeGrowth1);
    event PositionFeesUpdated(bytes32 indexed positionKey, uint256 tokensOwed0, uint256 tokensOwed1);

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
            manager,
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

        jitCoordinator.updateHook(address(hook));
        positionManager.updateHook(address(hook));
        feeManager.updateHook(address(hook));

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function testCalculateSwapFeesToken0() public {
        PoolId poolId = key.toId();
        BalanceDelta delta = toBalanceDelta(1000, 0);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 10000;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertEq(fees0, 3);
        assertEq(fees1, 0);

        (uint256 feeGrowth0, uint256 feeGrowth1) = feeCalculator.getGlobalFeeGrowth(poolId);
        assertGt(feeGrowth0, 0);
        assertEq(feeGrowth1, 0);
    }

    function testCalculateSwapFeesToken1() public {
        PoolId poolId = key.toId();
        BalanceDelta delta = toBalanceDelta(0, 2000);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 10000;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertEq(fees0, 0);
        assertEq(fees1, 6);

        (uint256 feeGrowth0, uint256 feeGrowth1) = feeCalculator.getGlobalFeeGrowth(poolId);
        assertEq(feeGrowth0, 0);
        assertGt(feeGrowth1, 0);
    }

    function testCalculateSwapFeesBothTokens() public {
        PoolId poolId = key.toId();
        BalanceDelta delta = toBalanceDelta(1000, 1500);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 10000;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertEq(fees0, 3);
        assertEq(fees1, 4);

        (uint256 feeGrowth0, uint256 feeGrowth1) = feeCalculator.getGlobalFeeGrowth(poolId);
        assertGt(feeGrowth0, 0);
        assertGt(feeGrowth1, 0);
    }

    function testCalculateSwapFeesZeroLiquidity() public {
        BalanceDelta delta = toBalanceDelta(1000, 1500);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 0;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    function testCalculateSwapFeesNegativeDeltas() public {
        BalanceDelta delta = toBalanceDelta(-1000, -1500);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 10000;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertEq(fees0, 3);
        assertEq(fees1, 4);
    }

    function testDifferentFeeTiers() public {
        BalanceDelta delta = toBalanceDelta(10000, 10000);
        uint128 totalLiquidity = 10000;

        (uint256 fees0_low,) = feeCalculator.calculateSwapFees(key, delta, 500, totalLiquidity);
        (uint256 fees0_mid,) = feeCalculator.calculateSwapFees(key, delta, 3000, totalLiquidity);
        (uint256 fees0_high,) = feeCalculator.calculateSwapFees(key, delta, 10000, totalLiquidity);

        assertEq(fees0_low, 5);
        assertEq(fees0_mid, 30);
        assertEq(fees0_high, 100);
    }

    function testFeeGrowthAccumulation() public {
        PoolId poolId = key.toId();
        BalanceDelta delta = toBalanceDelta(1000, 1500);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 10000;

        feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);
        (uint256 growth0_1, uint256 growth1_1) = feeCalculator.getGlobalFeeGrowth(poolId);

        feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);
        (uint256 growth0_2, uint256 growth1_2) = feeCalculator.getGlobalFeeGrowth(poolId);

        assertGt(growth0_2, growth0_1);
        assertGt(growth1_2, growth1_1);
    }

    function testCalculatePositionFees() public {
        uint256 tokenId = 1;
        uint128 liquidity = 5000;

        BalanceDelta delta = toBalanceDelta(10000, 15000);
        feeCalculator.calculateSwapFees(key, delta, 3000, 10000);

        (uint256 tokensOwed0, uint256 tokensOwed1) = feeCalculator.calculatePositionFees(key, LP1, tokenId, liquidity);

        assertGt(tokensOwed0, 0);
        assertGt(tokensOwed1, 0);
    }

    function testCalculatePositionFeesZeroLiquidity() public view {
        uint256 tokenId = 1;
        uint128 liquidity = 0;

        (uint256 tokensOwed0, uint256 tokensOwed1) = feeCalculator.calculatePositionFees(key, LP1, tokenId, liquidity);

        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
    }

    function testUpdatePositionFeeCheckpoint() public {
        uint256 tokenId = 1;

        BalanceDelta delta = toBalanceDelta(10000, 15000);
        feeCalculator.calculateSwapFees(key, delta, 3000, 10000);

        feeCalculator.updatePositionFeeCheckpoint(key, LP1, tokenId);

        (uint256 feeGrowth0, uint256 feeGrowth1) = feeCalculator.getPositionFeeCheckpoint(key, LP1, tokenId);
        assertGt(feeGrowth0, 0);
        assertGt(feeGrowth1, 0);
    }

    function testCalculateJITFeeShare() public view {
        uint256 totalFees0 = 1000;
        uint256 totalFees1 = 1500;
        uint128 lpLiquidity = 3000;
        uint128 totalLiquidity = 10000;

        (uint256 lpFees0, uint256 lpFees1) =
            feeCalculator.calculateJITFeeShare(totalFees0, totalFees1, lpLiquidity, totalLiquidity);

        assertEq(lpFees0, 300);
        assertEq(lpFees1, 450);
    }

    function testCalculateJITFeeShareZeroLiquidity() public view {
        uint256 totalFees0 = 1000;
        uint256 totalFees1 = 1500;
        uint128 lpLiquidity = 3000;
        uint128 totalLiquidity = 0;

        (uint256 lpFees0, uint256 lpFees1) =
            feeCalculator.calculateJITFeeShare(totalFees0, totalFees1, lpLiquidity, totalLiquidity);

        assertEq(lpFees0, 0);
        assertEq(lpFees1, 0);
    }

    function testCalculateJITFeeShareFullLiquidity() public view {
        uint256 totalFees0 = 1000;
        uint256 totalFees1 = 1500;
        uint128 lpLiquidity = 10000;
        uint128 totalLiquidity = 10000;

        (uint256 lpFees0, uint256 lpFees1) =
            feeCalculator.calculateJITFeeShare(totalFees0, totalFees1, lpLiquidity, totalLiquidity);

        assertEq(lpFees0, 1000);
        assertEq(lpFees1, 1500);
    }

    function testLargeSwapFees() public {
        BalanceDelta delta = toBalanceDelta(1000000 ether, 2000000 ether);
        uint24 feeTier = 3000;
        uint128 totalLiquidity = 100000 ether;

        (uint256 fees0, uint256 fees1) = feeCalculator.calculateSwapFees(key, delta, feeTier, totalLiquidity);

        assertGt(fees0, 0);
        assertGt(fees1, 0);
        assertGt(fees1, fees0);
    }

    function testProportionalFeeDistribution() public view {
        uint256 totalFees0 = 10000;
        uint256 totalFees1 = 15000;
        uint128 totalLiquidity = 100000;

        (uint256 lp1Fees0, uint256 lp1Fees1) =
            feeCalculator.calculateJITFeeShare(totalFees0, totalFees1, 30000, totalLiquidity);

        (uint256 lp2Fees0, uint256 lp2Fees1) =
            feeCalculator.calculateJITFeeShare(totalFees0, totalFees1, 70000, totalLiquidity);

        assertEq(lp1Fees0 + lp2Fees0, totalFees0);
        assertEq(lp1Fees1 + lp2Fees1, totalFees1);
    }
}
