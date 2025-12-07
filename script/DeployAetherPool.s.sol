// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {LPPositionManager} from "../src/LPPositionManager.sol";
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {HookSwapRouter} from "../src/HookSwapRouter.sol";
import {Token} from "../src/Token.sol";

contract DeployAetherPool is Script {
    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG) | uint160(Hooks.BEFORE_SWAP_FLAG)
        | uint160(Hooks.AFTER_SWAP_FLAG) | uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);
        console.log("Pool Manager:", poolManager);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy support contracts first
        console.log("\n=== Deploying Support Contracts ===");

        FHEConfigManager configManager = new FHEConfigManager();
        console.log("FHEConfigManager deployed at:", address(configManager));

        FeeCalculator feeCalculator = new FeeCalculator();
        console.log("FeeCalculator deployed at:", address(feeCalculator));

        // 2. Find hook address with correct flags using CREATE2
        console.log("\n=== Finding Hook Address with Flags ===");
        bytes32 salt = _findSalt(
            deployer,
            type(ZKJITLiquidityHook).creationCode,
            FLAGS,
            poolManager,
            address(0), // Will be filled with actual addresses
            address(configManager),
            address(0), // feeManager
            address(0), // profitManager
            address(0), // jitCoordinator
            address(feeCalculator)
        );

        address hookAddress = _computeHookAddress(
            deployer,
            salt,
            type(ZKJITLiquidityHook).creationCode,
            poolManager,
            address(0),
            address(configManager),
            address(0),
            address(0),
            address(0),
            address(feeCalculator)
        );

        console.log("Predicted Hook Address:", hookAddress);
        console.log("Hook Flags:", uint160(hookAddress));
        require(uint160(hookAddress) & FLAGS == FLAGS, "Invalid hook address flags");

        // 3. Deploy contracts that need hook address
        console.log("\n=== Deploying Hook-Dependent Contracts ===");

        LPPositionManager positionManager =
            new LPPositionManager(hookAddress, poolManager, "https://metadata.aetherpool.io/lp/{id}.json");
        console.log("LPPositionManager deployed at:", address(positionManager));

        DynamicFeeManager feeManager = new DynamicFeeManager(hookAddress, deployer);
        console.log("DynamicFeeManager deployed at:", address(feeManager));

        ProfitManager profitManager = new ProfitManager(address(configManager));
        console.log("ProfitManager deployed at:", address(profitManager));

        JITCoordinator jitCoordinator = new JITCoordinator(
            IPoolManager(poolManager),
            hookAddress,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
        );
        console.log("JITCoordinator deployed at:", address(jitCoordinator));

        // 4. Deploy the hook with correct salt
        console.log("\n=== Deploying Hook ===");
        ZKJITLiquidityHook hook = new ZKJITLiquidityHook{salt: salt}(
            IPoolManager(poolManager),
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator),
            address(feeCalculator)
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("Hook deployed at:", address(hook));

        // 5. Deploy tokens (Fyntera and Quarita)
        console.log("\n=== Deploying Tokens ===");
        Token fyntera = new Token("Fyntera", "FYN");
        console.log("Fyntera (FYN) deployed at:", address(fyntera));

        Token quarita = new Token("Quarita", "QRT");
        console.log("Quarita (QRT) deployed at:", address(quarita));

        // 6. Deploy swap router
        console.log("\n=== Deploying Swap Router ===");
        HookSwapRouter swapRouter = new HookSwapRouter(IPoolManager(poolManager));
        console.log("HookSwapRouter deployed at:", address(swapRouter));

        vm.stopBroadcast();

        // Log final deployment summary
        console.log("\n=== AetherPool Deployment Summary ===");
        console.log("Hook:              ", address(hook));
        console.log("Position Manager:  ", address(positionManager));
        console.log("Config Manager:    ", address(configManager));
        console.log("Fee Manager:       ", address(feeManager));
        console.log("Fee Calculator:    ", address(feeCalculator));
        console.log("Profit Manager:    ", address(profitManager));
        console.log("JIT Coordinator:   ", address(jitCoordinator));
        console.log("Fyntera (FYN):     ", address(fyntera));
        console.log("Quarita (QRT):     ", address(quarita));
        console.log("Swap Router:       ", address(swapRouter));

        console.log("\n=== Next Steps ===");
        console.log("1. Initialize FYN/QRT pool using the hook");
        console.log("2. Verify contracts on BaseScan");
        console.log("3. Update frontend with deployed addresses");
    }

    /**
     * @notice Find a salt that produces a hook address with correct flags
     */
    function _findSalt(
        address deployer,
        bytes memory creationCode,
        uint160 flags,
        address poolManager,
        address positionManager,
        address configManager,
        address feeManager,
        address profitManager,
        address jitCoordinator,
        address feeCalculator
    ) internal pure returns (bytes32) {
        bytes32 salt;
        for (uint256 i = 0; i < 10000; i++) {
            salt = bytes32(i);
            address predicted = _computeHookAddress(
                deployer,
                salt,
                creationCode,
                poolManager,
                positionManager,
                configManager,
                feeManager,
                profitManager,
                jitCoordinator,
                feeCalculator
            );

            if (uint160(predicted) & flags == flags) {
                console.log("Found salt:", i);
                return salt;
            }
        }
        revert("Could not find valid salt");
    }

    /**
     * @notice Compute CREATE2 address for hook deployment
     */
    function _computeHookAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode,
        address poolManager,
        address positionManager,
        address configManager,
        address feeManager,
        address profitManager,
        address jitCoordinator,
        address feeCalculator
    ) internal pure returns (address) {
        bytes memory bytecode = abi.encodePacked(
            creationCode,
            abi.encode(
                poolManager, positionManager, configManager, feeManager, profitManager, jitCoordinator, feeCalculator
            )
        );

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode)));

        return address(uint160(uint256(hash)));
    }
}
