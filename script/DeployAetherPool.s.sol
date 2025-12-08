// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-utils/HookMiner.sol";

import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";
import {LPPositionManager} from "../src/LPPositionManager.sol";
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {HookSwapRouter} from "../src/HookSwapRouter.sol";
import {Token} from "../src/Token.sol";

/**
 * @title DeployAetherPool
 * @notice Deploys AetherPool JIT liquidity system following Uniswap V4 pattern
 * @dev Uses HookMiner to find valid hook address and updatable contracts
 */
contract DeployAetherPool is Script {
    // CREATE2 Deployer (same address on all chains)
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    IPoolManager constant POOLMANAGER = IPoolManager(address(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408)); // Base Sepolia

    function run() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        console.log("=== AetherPool Deployment ===");
        console.log("Pool Manager:", address(POOLMANAGER));
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        // ===== Step 1: Deploy Independent Contracts =====
        console.log("\n--- Step 1: Independent Contracts ---");

        FHEConfigManager configManager = new FHEConfigManager();
        console.log("FHEConfigManager:", address(configManager));

        FeeCalculator feeCalculator = new FeeCalculator();
        console.log("FeeCalculator:", address(feeCalculator));

        ProfitManager profitManager = new ProfitManager(address(configManager));
        console.log("ProfitManager:", address(profitManager));

        LPPositionManager positionManager = new LPPositionManager(
            address(POOLMANAGER),
            "https://aquamarine-famous-penguin-727.mypinata.cloud/ipfs/bafkreifxpa42qjmydsxifmcmtm4a5vmr6z2id7ae4chugoywvk2i6lfn6m"
        );
        console.log("LPPositionManager:", address(positionManager));

        DynamicFeeManager feeManager = new DynamicFeeManager(msg.sender);
        console.log("DynamicFeeManager:", address(feeManager));

        JITCoordinator jitCoordinator = new JITCoordinator(
            POOLMANAGER,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
        );
        console.log("JITCoordinator:", address(jitCoordinator));

        // ===== Step 2: Mine for Valid Hook Address =====
        console.log("\n--- Step 2: Mining for Hook Address ---");

        bytes memory constructorArgs = abi.encode(
            POOLMANAGER,
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator),
            address(feeCalculator)
        );

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ZKJITLiquidityHook).creationCode, constructorArgs);

        console.log("Hook Address Found:", hookAddress);
        console.log("Salt:", uint256(salt));

        // ===== Step 3: Deploy Hook =====
        console.log("\n--- Step 3: Deploying Hook ---");

        ZKJITLiquidityHook hook = new ZKJITLiquidityHook{salt: salt}(
            POOLMANAGER,
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator),
            address(feeCalculator)
        );

        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("Hook deployed:", address(hook));

        // ===== Step 4: Update Hook Addresses =====
        console.log("\n--- Step 4: Updating Hook References ---");

        positionManager.updateHook(address(hook));
        console.log("Updated LPPositionManager.hook");

        feeManager.updateHook(address(hook));
        console.log("Updated DynamicFeeManager.hook");

        jitCoordinator.updateHook(address(hook));
        console.log("Updated JITCoordinator.hook");

        // ===== Step 5: Deploy Token Pair =====
        console.log("\n--- Step 5: Deploying Tokens ---");

        Token fyntera = new Token("Fyntera", "FYN");
        console.log("Fyntera (FYN):", address(fyntera));

        Token quarita = new Token("Quarita", "QRT");
        console.log("Quarita (QRT):", address(quarita));

        (address token0, address token1) = address(fyntera) < address(quarita)
            ? (address(fyntera), address(quarita))
            : (address(quarita), address(fyntera));

        console.log("Token0:", token0);
        console.log("Token1:", token1);

        // ===== Step 6: Deploy Swap Router =====
        console.log("\n--- Step 6: Deploying Swap Router ---");

        HookSwapRouter swapRouter = new HookSwapRouter(POOLMANAGER);
        console.log("HookSwapRouter:", address(swapRouter));

        vm.stopBroadcast();
    }
}

// source .env

// forge script script/DeployAetherPool.s.sol:DeployAetherPool \
//     --rpc-url $BASE_SEPOLIA_RPC_URL \
//     --private-key $PRIVATE_KEY \    --broadcast \
//     -vvvv

// # Get hook permissions directly
// cast call 0x292A9Dd792237a61AAb1BFFCb1CE4EBf94BaE0c8 \
//   "getHookPermissions()(bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)" \
//   --rpc-url $BASE_SEPOLIA_RPC_URL

// jq --version
// brew install jq ===> if not installed

// # Create directory first
// mkdir -p extractedABIs

// # Extract the ABIs
// jq '.abi' out/DynamicFeeManager.sol/DynamicFeeManager.json > extractedABIs/DynamicFeeManager.json
// jq '.abi' out/FeeCalculator.sol/FeeCalculator.json > extractedABIs/FeeCalculator.json
// jq '.abi' out/FHEConfigManager.sol/FHEConfigManager.json > extractedABIs/FHEConfigManager.json
// jq '.abi' out/HookSwapRouter.sol/HookSwapRouter.json > extractedABIs/HookSwapRouter.json
// jq '.abi' out/JITCoordinator.sol/JITCoordinator.json > extractedABIs/JITCoordinator.json
// jq '.abi' out/LPPositionManager.sol/LPPositionManager.json > extractedABIs/LPPositionManager.json
// jq '.abi' out/ProfitManager.sol/ProfitManager.json > extractedABIs/ProfitManager.json
// jq '.abi' out/Token.sol/Token.json > extractedABIs/Token.json
// jq '.abi' out/ZKJITLiquidityHook.sol/ZKJITLiquidityHook.json > extractedABIs/ZKJITLiquidityHook.json
// jq '.abi' out/SlippageLib.sol/SlippageLib.json > extractedABIs/SlippageLib.json
