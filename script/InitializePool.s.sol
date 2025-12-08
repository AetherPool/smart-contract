// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/**
 * @title InitializePool
 * @notice Initialize QRT/FYN pool at 1:1 price with dynamic fees
 */
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant HOOK = 0x292A9Dd792237a61AAb1BFFCb1CE4EBf94BaE0c8;

    address constant QUARITA = 0x0034c3506F653E3a1FAC31a5c295351532296D61; // QRT
    address constant FYNTERA = 0xB202EC1CB8d4b85f643cd9b007208aaEe3D1E209; // FYN

    address constant TOKEN0 = QUARITA;
    address constant TOKEN1 = FYNTERA;

    // SQRT_PRICE_1_1 = sqrt(1) * 2^96 = 79228162514264337593543950336
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() public {
        console.log("=== Pool Initialization ===");
        console.log("Pool Manager:", POOL_MANAGER);
        console.log("Hook:", HOOK);
        console.log("");
        console.log("Token0 (QRT):", TOKEN0);
        console.log("Token1 (FYN):", TOKEN1);
        console.log("");

        // Verify token order
        require(TOKEN0 < TOKEN1, "Token order incorrect: token0 must be lower address");
        console.log("Token order verified");

        vm.startBroadcast();

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // 0x800000 = dynamic fee
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        console.log("");
        console.log("Pool Key Configuration:");
        console.log("  Fee:", uint24(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        console.log("  Tick Spacing:", uint24(60));
        console.log("  Initial Price: 1:1 (SQRT_PRICE_1_1)");
        console.log("");

        // Initialize pool at 1:1 price
        IPoolManager(POOL_MANAGER).initialize(poolKey, SQRT_PRICE_1_1);

        // Calculate and log pool ID
        PoolId poolIdRaw = PoolIdLibrary.toId(poolKey);
        bytes32 poolId = PoolId.unwrap(poolIdRaw);

        console.log("Pool initialized successfully!");
        console.log("");
        console.log("Pool ID:", uint256(poolId));
        console.log("Pool ID (hex):", vm.toString(poolId));

        vm.stopBroadcast();

        console.log("");
        console.log(
            "\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550"
        );
        console.log("                    NEXT STEPS                             ");
        console.log(
            "\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550"
        );
        console.log("");
        console.log("1. Verify Pool Initialization");
        console.log("   Check on BaseScan that initialize() succeeded");
        console.log("");
        console.log("2. Mint Test Tokens");
        console.log("   Run: forge script script/MintTestTokens.s.sol --broadcast");
        console.log("");
        console.log("3. Add Liquidity");
        console.log("   - Add base passive liquidity (full range)");
        console.log("   - Configure JIT LP strategies");
        console.log("   - Add JIT liquidity (concentrated range)");
        console.log("");
        console.log("4. Test Swaps");
        console.log("   Use the HookSwapRouter to perform test swaps");
        console.log(
            "\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550"
        );
    }
}

// forge script script/InitializePool.s.sol:InitializePool \
//     --rpc-url $BASE_SEPOLIA_RPC_URL \
//     --private-key $PRIVATE_KEY \
//     --broadcast \
//     -vvvv
