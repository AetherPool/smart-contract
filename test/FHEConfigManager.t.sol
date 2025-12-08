// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";

contract FHEConfigManagerTest is Test, Deployers, CoFheTest {
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

    event LPConfigSet(bytes32 indexed poolId, address indexed lp, bool isActive);
    event LPConfigUpdated(bytes32 indexed poolId, address indexed lp, bool autoHedgeEnabled);
    event LPDeactivated(bytes32 indexed poolId, address indexed lp);

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

        vm.prank(HOOK);
        feeManager = new DynamicFeeManager(OWNER);

        profitManager = new ProfitManager(address(configManager));
        feeCalculator = new FeeCalculator();
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

    function testLPConfiguration() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(40, LP1);

        vm.expectEmit(true, true, true, true);
        emit LPConfigSet(keccak256(abi.encode(key)), LP1, true);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        assertTrue(configManager.isActive(key, LP1));
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));
    }

    function testMultipleLPConfigurations() public {
        vm.startPrank(LP1);
        InEuint128 memory enc1MinSwap = createInEuint128(2000, LP1);
        InEuint32 memory enc1Hedge0 = createInEuint32(75, LP1);
        InEuint32 memory enc1Hedge1 = createInEuint32(70, LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, true);
        vm.stopPrank();

        vm.startPrank(LP2);
        InEuint128 memory enc2MinSwap = createInEuint128(1000, LP2);
        InEuint32 memory enc2Hedge0 = createInEuint32(50, LP2);
        InEuint32 memory enc2Hedge1 = createInEuint32(45, LP2);
        configManager.configureLPSettings(key, enc2MinSwap, enc2Hedge0, enc2Hedge1, true);
        vm.stopPrank();

        vm.startPrank(LP3);
        InEuint128 memory enc3MinSwap = createInEuint128(500, LP3);
        InEuint32 memory enc3Hedge0 = createInEuint32(25, LP3);
        InEuint32 memory enc3Hedge1 = createInEuint32(20, LP3);
        configManager.configureLPSettings(key, enc3MinSwap, enc3Hedge0, enc3Hedge1, false);
        vm.stopPrank();

        assertTrue(configManager.isActive(key, LP1));
        assertTrue(configManager.isActive(key, LP2));
        assertTrue(configManager.isActive(key, LP3));
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP2));
        assertFalse(configManager.hasAutoHedgeEnabled(key, LP3));
    }

    function testUpdateAutoHedge() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));

        vm.expectEmit(true, true, true, true);
        emit LPConfigUpdated(keccak256(abi.encode(key)), LP1, false);
        configManager.updateAutoHedge(key, false);

        assertFalse(configManager.hasAutoHedgeEnabled(key, LP1));

        configManager.updateAutoHedge(key, true);
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));

        vm.stopPrank();
    }

    function testDeactivateLP() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        assertTrue(configManager.isActive(key, LP1));

        vm.expectEmit(true, true, true, true);
        emit LPDeactivated(keccak256(abi.encode(key)), LP1);
        configManager.deactivateLP(key);

        assertFalse(configManager.isActive(key, LP1));
        vm.stopPrank();
    }

    function testReactivateLP() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        configManager.deactivateLP(key);
        assertFalse(configManager.isActive(key, LP1));

        vm.warp(block.timestamp + 10);

        vm.expectEmit(true, true, true, true);
        emit LPConfigSet(keccak256(abi.encode(key)), LP1, true);
        configManager.reactivateLP(key);

        assertTrue(configManager.isActive(key, LP1));
        vm.stopPrank();
    }

    function testFHEPrivacyPreservation() public {
        vm.startPrank(LP1);
        InEuint128 memory secretMinSwap = createInEuint128(5000, LP1);
        InEuint32 memory secretHedge0 = createInEuint32(80, LP1);
        InEuint32 memory secretHedge1 = createInEuint32(75, LP1);
        configManager.configureLPSettings(key, secretMinSwap, secretHedge0, secretHedge1, true);
        vm.stopPrank();

        vm.startPrank(LP2);
        InEuint128 memory secretMinSwap2 = createInEuint128(1000, LP2);
        InEuint32 memory secretHedge0_2 = createInEuint32(40, LP2);
        InEuint32 memory secretHedge1_2 = createInEuint32(35, LP2);
        configManager.configureLPSettings(key, secretMinSwap2, secretHedge0_2, secretHedge1_2, false);
        vm.stopPrank();

        assertTrue(configManager.isActive(key, LP1));
        assertTrue(configManager.isActive(key, LP2));
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));
        assertFalse(configManager.hasAutoHedgeEnabled(key, LP2));
    }

    function testThresholdEvaluation() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(2000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        vm.prank(LP1);
        configManager.deactivateLP(key);

        vm.warp(block.timestamp + 10);

        vm.prank(LP1);
        configManager.reactivateLP(key);

        configManager.decryptMinSwapSize(key, LP1);
        vm.warp(block.timestamp + 10);

        bool meets1500 = configManager.meetsThreshold(key, LP1, 1500);
        bool meets2500 = configManager.meetsThreshold(key, LP1, 2500);

        assertFalse(meets1500);
        assertTrue(meets2500);
    }

    function testGetLPConfig() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1500, LP1);
        InEuint32 memory encHedge0 = createInEuint32(60, LP1);
        InEuint32 memory encHedge1 = createInEuint32(55, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        FHEConfigManager.LPConfig memory config = configManager.getLPConfig(key, LP1);

        assertTrue(config.isActive);
        assertTrue(config.autoHedgeEnabled);
    }

    function testUnauthorizedDecryption() public {
        vm.startPrank(LP1);
        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);
        vm.stopPrank();

        vm.prank(USER);
        vm.expectRevert(FHEConfigManager.DecryptionNotReady.selector);
        configManager.getHedgePercentage(key, LP1);
    }

    function testInvalidOperations() public {
        vm.prank(LP1);
        vm.expectRevert(FHEConfigManager.InvalidConfiguration.selector);
        configManager.updateAutoHedge(key, true);

        vm.prank(LP2);
        vm.expectRevert(FHEConfigManager.DecryptionNotReady.selector);
        configManager.reactivateLP(key);
    }

    function testConfigurationOverwrite() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap1 = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0_1 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1_1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap1, encHedge0_1, encHedge1_1, true);

        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));

        InEuint128 memory encMinSwap2 = createInEuint128(2000, LP1);
        InEuint32 memory encHedge0_2 = createInEuint32(75, LP1);
        InEuint32 memory encHedge1_2 = createInEuint32(70, LP1);
        configManager.configureLPSettings(key, encMinSwap2, encHedge0_2, encHedge1_2, false);

        assertFalse(configManager.hasAutoHedgeEnabled(key, LP1));

        vm.stopPrank();
    }

    function testHedgePercentageRetrieval() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(60, LP1);
        InEuint32 memory encHedge1 = createInEuint32(55, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        configManager.decryptHedgePercentage(key, LP1);
        vm.warp(block.timestamp + 10);

        (uint256 hedge0, uint256 hedge1) = configManager.getHedgePercentage(key, LP1);

        assertEq(hedge0, 60);
        assertEq(hedge1, 55);
    }

    function testMultiplePoolConfigurations() public {
        PoolKey memory key2;
        (key2,) = initPool(
            Currency.wrap(address(0x8888)),
            Currency.wrap(address(0x9999)),
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        vm.startPrank(LP1);

        InEuint128 memory enc1MinSwap = createInEuint128(1000, LP1);
        InEuint32 memory enc1Hedge0 = createInEuint32(50, LP1);
        InEuint32 memory enc1Hedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, enc1MinSwap, enc1Hedge0, enc1Hedge1, true);

        InEuint128 memory enc2MinSwap = createInEuint128(2000, LP1);
        InEuint32 memory enc2Hedge0 = createInEuint32(70, LP1);
        InEuint32 memory enc2Hedge1 = createInEuint32(65, LP1);
        configManager.configureLPSettings(key2, enc2MinSwap, enc2Hedge0, enc2Hedge1, false);

        vm.stopPrank();

        assertTrue(configManager.isActive(key, LP1));
        assertTrue(configManager.isActive(key2, LP1));
        assertTrue(configManager.hasAutoHedgeEnabled(key, LP1));
        assertFalse(configManager.hasAutoHedgeEnabled(key2, LP1));
    }

    function testInactiveLPBehavior() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        configManager.deactivateLP(key);

        vm.stopPrank();

        bool meetsThreshold = configManager.meetsThreshold(key, LP1, 5000);
        assertFalse(meetsThreshold);
    }

    function testDepositedAmountsTracking() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(45, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 1000, 2000);

        (uint256 amount0, uint256 amount1) = configManager.getDepositedAmounts(key, LP1);
        assertEq(amount0, 1000);
        assertEq(amount1, 2000);
    }

    function testShouldAutoHedge() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(40, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 1000, 1000);
        configManager.decryptHedgePercentage(key, LP1);
        vm.warp(block.timestamp + 10);

        bool shouldHedge = configManager.shouldAutoHedge(key, LP1, 600, 300);
        assertTrue(shouldHedge);

        shouldHedge = configManager.shouldAutoHedge(key, LP1, 400, 300);
        assertFalse(shouldHedge);
    }

    function testGetHedgeTriggers() public {
        vm.startPrank(LP1);

        InEuint128 memory encMinSwap = createInEuint128(1000, LP1);
        InEuint32 memory encHedge0 = createInEuint32(50, LP1);
        InEuint32 memory encHedge1 = createInEuint32(40, LP1);
        configManager.configureLPSettings(key, encMinSwap, encHedge0, encHedge1, true);

        vm.stopPrank();

        configManager.updateDepositedAmounts(key, LP1, 1000, 1000);
        configManager.decryptHedgePercentage(key, LP1);
        vm.warp(block.timestamp + 10);

        (bool token0Triggered, bool token1Triggered) = configManager.getHedgeTriggers(key, LP1, 600, 300);

        assertTrue(token0Triggered);
        assertFalse(token1Triggered);

        (token0Triggered, token1Triggered) = configManager.getHedgeTriggers(key, LP1, 600, 500);

        assertTrue(token0Triggered);
        assertTrue(token1Triggered);
    }
}
