# AetherPool Deployment Guide

## Overview

Deploy 6 modular contracts in specific order due to dependencies. Total gas: ~6M across all contracts.

---

## Prerequisites

```bash
# Required tools
forge --version
cast --version

# Environment setup
export POOL_MANAGER_ADDRESS=0x...    # Uniswap v4 PoolManager
export DEPLOYER_ADDRESS=0x...        # Your address
export RPC_URL=https://...           # RPC endpoint
export ETHERSCAN_API_KEY=...         # For verification
```

---

## Deployment Order

### Step 1: Deploy Support Contracts

```solidity
// 1. LPPositionManager (~2M gas)
LPPositionManager positionManager = new LPPositionManager(
    address(hook),        // Hook address
    POOL_MANAGER_ADDRESS,
    "https://metadata.aetherpool.io/lp/{id}.json"  // Metadata URI
);

// 2. FHEConfigManager (~1.5M gas)
FHEConfigManager configManager = new FHEConfigManager();

// 3. DynamicFeeManager (~800K gas)
DynamicFeeManager feeManager = new DynamicFeeManager(
    address(hook),     // Hook address
    DEPLOYER_ADDRESS   // Owner
);

// 4. FeeCalculator (~500K gas)
FeeCalculator feeCalculator = new FeeCalculator();

// 5. ProfitManager (~700K gas)
ProfitManager profitManager = new ProfitManager(
    address(configManager)
);

// 6. JITCoordinator (~1.2M gas)
JITCoordinator jitCoordinator = new JITCoordinator(
    POOL_MANAGER_ADDRESS,
    address(hook),
    address(positionManager),
    address(configManager),
    address(profitManager),
    address(feeCalculator)
);
```

### Step 2: Deploy Main Hook

```solidity
// 7. ZKJITLiquidityHook (~1.5M gas)
ZKJITLiquidityHook hook = new ZKJITLiquidityHook(
    POOL_MANAGER_ADDRESS,
    address(positionManager),
    address(configManager),
    address(feeManager),
    address(profitManager),
    address(jitCoordinator),
    address(feeCalculator)
);
```

---

## Foundry Deployment Script

Save as `script/DeployAetherPool.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {LPPositionManager} from "../src/LPPositionManager.sol";
import {FHEConfigManager} from "../src/FHEConfigManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {ProfitManager} from "../src/ProfitManager.sol";
import {JITCoordinator} from "../src/JITCoordinator.sol";
import {ZKJITLiquidityHook} from "../src/ZKJITLiquidityHook.sol";

contract DeployAetherPool is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address deployer = msg.sender;

        vm.startBroadcast();

        // Deploy support contracts
        FHEConfigManager configManager = new FHEConfigManager();
        FeeCalculator feeCalculator = new FeeCalculator();
        
        // Deploy hook first to get address
        bytes memory hookBytecode = type(ZKJITLiquidityHook).creationCode;
        address predictedHook = computeCreate2Address(
            keccak256(abi.encodePacked(hookBytecode)),
            0
        );

        LPPositionManager positionManager = new LPPositionManager(
            predictedHook,
            poolManager,
            "https://metadata.aetherpool.io/lp/{id}.json"
        );
        
        DynamicFeeManager feeManager = new DynamicFeeManager(
            predictedHook,
            deployer
        );
        
        ProfitManager profitManager = new ProfitManager(
            address(configManager)
        );
        
        JITCoordinator jitCoordinator = new JITCoordinator(
            IPoolManager(poolManager),
            predictedHook,
            address(positionManager),
            address(configManager),
            address(profitManager),
            address(feeCalculator)
        );

        // Deploy hook with all dependencies
        ZKJITLiquidityHook hook = new ZKJITLiquidityHook{salt: bytes32(0)}(
            IPoolManager(poolManager),
            address(positionManager),
            address(configManager),
            address(feeManager),
            address(profitManager),
            address(jitCoordinator),
            address(feeCalculator)
        );

        require(address(hook) == predictedHook, "Hook address mismatch");

        vm.stopBroadcast();

        // Log deployment
        console.log("=== AetherPool Deployment ===");
        console.log("Hook:              ", address(hook));
        console.log("Position Manager:  ", address(positionManager));
        console.log("Config Manager:    ", address(configManager));
        console.log("Fee Manager:       ", address(feeManager));
        console.log("Fee Calculator:    ", address(feeCalculator));
        console.log("Profit Manager:    ", address(profitManager));
        console.log("JIT Coordinator:   ", address(jitCoordinator));
    }
}
```

---

## Deployment Commands

### Testnet Deployment

```bash
# Dry run (no actual deployment)
forge script script/DeployAetherPool.s.sol:DeployAetherPool \
    --rpc-url $RPC_URL

# Deploy and verify
forge script script/DeployAetherPool.s.sol:DeployAetherPool \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    -vvvv

# Save deployment addresses
forge script script/DeployAetherPool.s.sol:DeployAetherPool \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    > deployments/testnet.txt
```

### Mainnet Deployment

```bash
# Extra safety checks
forge script script/DeployAetherPool.s.sol:DeployAetherPool \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    --slow \
    --legacy \
    -vvvv
```

---

## Post-Deployment Setup

### 1. Initialize Fee Parameters (Optional)

```bash
cast send $FEE_MANAGER_ADDRESS \
    "updateFeeParameters(uint24,uint24,uint24)" \
    3000 1500 6000 \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL
```

### 2. Verify All Contracts

```bash
# Verify hook
forge verify-contract $HOOK_ADDRESS \
    src/ZKJITLiquidityHook.sol:ZKJITLiquidityHook \
    --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address)" \
        $POOL_MANAGER $POSITION_MANAGER $CONFIG_MANAGER $FEE_MANAGER \
        $PROFIT_MANAGER $JIT_COORDINATOR $FEE_CALCULATOR) \
    --etherscan-api-key $ETHERSCAN_API_KEY

# Verify each module...
```

### 3. Test Deployment

```bash
# Run integration test against deployed contracts
forge test --match-contract IntegrationTest \
    --fork-url $RPC_URL \
    -vvv
```

---

## Configuration

### Set Dynamic Fee Parameters

```solidity
// Adjust fee tiers (owner only)
feeManager.updateFeeParameters(
    3000,  // baseFee (0.3%)
    1500,  // highGasFee (0.15%)
    6000   // lowGasFee (0.6%)
);

// Adjust thresholds (owner only)
feeManager.updateThresholds(
    110,  // highGasThreshold (110%)
    90    // lowGasThreshold (90%)
);
```

### Transfer Ownership

```solidity
// Transfer fee manager ownership
feeManager.transferOwnership(newOwner);
```

---

## Verification Checklist

Post-deployment verification:

- [ ] All contracts deployed successfully
- [ ] Hook address matches predicted address
- [ ] All modules have correct hook reference
- [ ] Fee parameters initialized correctly
- [ ] Ownership transferred if needed
- [ ] All contracts verified on Etherscan
- [ ] Integration tests pass on deployed contracts
- [ ] Monitor first few transactions

---

## Gas Costs

Typical deployment costs (base fee = 20 gwei):

| Contract | Gas | Cost (20 gwei) |
|----------|-----|----------------|
| LPPositionManager | 2,000,000 | 0.04 ETH |
| FHEConfigManager | 1,500,000 | 0.03 ETH |
| DynamicFeeManager | 800,000 | 0.016 ETH |
| FeeCalculator | 500,000 | 0.01 ETH |
| ProfitManager | 700,000 | 0.014 ETH |
| JITCoordinator | 1,200,000 | 0.024 ETH |
| ZKJITLiquidityHook | 1,500,000 | 0.03 ETH |
| **Total** | **~6,200,000** | **~0.124 ETH** |

---

## Troubleshooting

### Contract Size Too Large
```bash
# Check sizes
forge build --sizes

# If any contract > 24KB:
# 1. Enable optimizer in foundry.toml
# 2. Increase optimizer runs
# 3. Consider splitting large contracts
```

### Hook Address Mismatch
```bash
# Ensure CREATE2 salt is consistent
# Check hook bytecode hasn't changed
# Verify constructor arguments match
```

### Transaction Reverts
```bash
# Debug with -vvvv flag
forge script ... -vvvv

# Check:
# - Pool manager address is correct
# - All module addresses are valid
# - Gas limit is sufficient
```

### Verification Fails
```bash
# Retry with --watch flag
forge verify-contract --watch ...

# If still fails:
# 1. Check Etherscan API key
# 2. Wait a few minutes and retry
# 3. Manually verify on Etherscan UI
```

---

## Upgrade Process

To upgrade a module:

```bash
# 1. Deploy new version
NewModule newModule = new NewModule(...);

# 2. Update hook reference (requires hook upgrade)
hook.updateModuleAddress(address(newModule));

# 3. Verify functionality
forge test --fork-url $RPC_URL
```

---

## Monitoring

### Track Deployments

Create `deployments/mainnet.json`:

```json
{
  "network": "mainnet",
  "chainId": 1,
  "timestamp": "2024-11-30T10:00:00Z",
  "deployer": "0x...",
  "contracts": {
    "hook": "0x...",
    "positionManager": "0x...",
    "configManager": "0x...",
    "feeManager": "0x...",
    "feeCalculator": "0x...",
    "profitManager": "0x...",
    "jitCoordinator": "0x..."
  }
}
```

### Monitor First Swaps

```bash
# Watch events
cast logs --address $HOOK_ADDRESS \
    --rpc-url $RPC_URL \
    --from-block latest

# Check JIT operations
cast call $JIT_COORDINATOR \
    "getNextSwapId()(uint256)" \
    --rpc-url $RPC_URL
```

---

## Security Notes

- **Never commit private keys** to version control
- **Test on testnet first** before mainnet
- **Audit all contracts** before production
- **Monitor gas prices** for deployment timing
- **Use hardware wallet** for mainnet deployment
- **Set up multisig** for ownership
- **Have emergency procedures** ready

---

## Support

For deployment issues:
- GitHub Issues: https://github.com/aetherpool/protocol
- Discord: https://discord.gg/aetherpool
- Email: dev@aetherpool.io

---

## Next Steps

After deployment:
1. Add liquidity to test pool
2. Configure LP settings with FHE
3. Execute test swaps
4. Monitor JIT operations
5. Set up frontend integration
6. Prepare documentation for LPs