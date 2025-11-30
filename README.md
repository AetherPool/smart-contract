# AetherPool

**Privacy-Preserving Multi-LP Just-In-Time Liquidity Protocol for Uniswap v4**

AetherPool enables multiple liquidity providers to coordinate Just-In-Time (JIT) liquidity operations while maintaining complete strategy privacy through Fully Homomorphic Encryption (FHE). Built with a modular architecture for production-grade reliability and upgradability.

## Key Innovations

### 🔒 Privacy-First Strategy Protection
All LP parameters (thresholds, hedge ratios) encrypted using Fhenix FHE. JIT participation decisions made on encrypted data—competitors cannot observe or copy successful strategies.

### 👥 Multi-LP Coordination
Automatically identifies LPs with overlapping positions, calculates proportional contributions, and distributes fees fairly among participants.

### ⚡ Gas-Responsive Dynamic Fees
- **High Gas (>110% avg)**: 0.15% - incentivize trading during congestion
- **Normal Gas**: 0.30% - base fee
- **Low Gas (<90% avg)**: 0.60% - maximize LP returns

### 🛡️ Automated Risk Management
Independent per-token profit tracking with configurable auto-hedge thresholds. Each token (token0, token1) triggers hedging independently when reaching its encrypted threshold.

## Quick Start

### Installation
```bash
forge install
```

### Run Tests
```bash
# All tests
forge test -vvv

# Specific features
forge test --match-test testMultiLPJIT -vvv
forge test --match-test testAutoHedging -vvv
```

### Deploy
```bash
forge script script/DeployAetherPool.s.sol:DeployAetherPool \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify
```

## Usage Example

### Configure LP Strategy
```solidity
// Set encrypted parameters
hook.configureLPSettings(
    poolKey,
    encryptedMinSwapSize,      // Minimum swap to trigger JIT
    encryptedHedgePercentage0,  // Token0 hedge threshold (0-100%)
    encryptedHedgePercentage1,  // Token1 hedge threshold (0-100%)
    true                        // Enable auto-hedging
);
```

### Deposit Liquidity
```solidity
// Automatic liquidity calculation from token amounts
(uint256 tokenId, uint128 liquidity, uint256 amt0, uint256 amt1) = 
    hook.depositLiquidityWithAmounts(
        poolKey,
        tickLower,
        tickUpper,
        amount0Desired,
        amount1Desired,
        true  // Enable JIT participation
    );
```

### Withdraw Liquidity
```solidity
(uint256 amount0, uint256 amount1) = hook.withdrawLiquidity(
    poolKey,
    tokenId,
    liquidityDelta
);
```

## Architecture

Modular design with 6 focused contracts + 1 utility library:

```
Hook (Orchestrator)
├── LPPositionManager (ERC1155 positions)
├── FHEConfigManager (Encrypted strategies)
├── DynamicFeeManager (Gas-based fees)
├── ProfitManager (Profit tracking)
├── JITCoordinator (Multi-LP orchestration)
└── FeeCalculator (Uniswap V3 math)
```

**Benefits**: 25% gas savings, isolated upgrades, focused audits, parallel development.

## Key Features

### Privacy-Preserving JIT
- Encrypted participation thresholds
- Private hedge percentages
- Zero-knowledge evaluation
- Strategy confidentiality

### Multi-LP Operations
- Automatic LP discovery
- Proportional contributions
- Fair fee distribution
- Coordinated execution

### Independent Token Hedging
```solidity
// Example: Different risk per token
hedgePercentage0 = 20%  // Conservative token0
hedgePercentage1 = 50%  // Aggressive token1

// After earning: 200 token0, 100 token1
// Token0: 200/1000 = 20% ✅ TRIGGERS
// Token1: 100/2000 = 5%  ❌ Below threshold
// Result: Hedge only token0
```

## Documentation

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Module details, data flow, testing strategy
- **[DEPLOYMENT.md](./DEPLOYMENT.md)** - Deployment guide, configuration, troubleshooting

## Benefits

**For LPs**:
- Complete strategy privacy
- Automatic JIT coordination
- Independent token risk management
- Gas-optimized fees

**For Traders**:
- Better execution through JIT liquidity
- Lower fees during high gas
- Reduced price impact

**For Developers**:
- Modular architecture
- Comprehensive tests
- Easy to extend

## Technology Stack

- **Uniswap v4**: Decentralized exchange infrastructure
- **Fhenix Protocol**: Fully Homomorphic Encryption
- **Foundry**: Development framework

## Security

- Access control on all modules
- FHE encryption via Fhenix
- ERC1155 position validation
- Uniswap V4 battle-tested math

## License

MIT License

## Built For

Uniswap v4 Hook Incubator

---

**Get Started**: Deploy in 5 minutes · Configure in 2 lines · Earn JIT fees automatically

*Privacy-preserving DeFi infrastructure for next-generation liquidity provision*