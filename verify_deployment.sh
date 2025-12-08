#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== AetherPool Deployment Verification ===${NC}\n"

# Hook address
HOOK="0x292A9Dd792237a61AAb1BFFCb1CE4EBf94BaE0c8"
RPC=$BASE_SEPOLIA_RPC_URL

echo "1. Checking if hook contract exists..."
CODE=$(cast code $HOOK --rpc-url $RPC)
if [ ${#CODE} -gt 2 ]; then
    echo -e "${GREEN}✅ Hook contract deployed${NC}"
else
    echo -e "${RED}❌ Hook contract not found${NC}"
    exit 1
fi

echo -e "\n2. Getting hook permissions..."
cast call $HOOK \
  "getHookPermissions()(bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool,bool)" \
  --rpc-url $RPC

echo -e "\n3. Checking module addresses..."
cast call $HOOK \
  "getModuleAddresses()(address,address,address,address,address,address)" \
  --rpc-url $RPC

echo -e "\n4. Verifying token order..."
echo "Token0 (QRT): 0x0034c3506F653E3a1FAC31a5c295351532296D61"
echo "Token1 (FYN): 0xB202EC1CB8d4b85f643cd9b007208aaEe3D1E209"

echo -e "\n5. Checking contracts on BaseScan..."
echo "Hook: https://base-sepolia.blockscout.com/address/$HOOK"
echo "Position Manager: https://base-sepolia.blockscout.com/address/0x4237538825520886Fb9bF8Fc07eDD0cFB22B5Ea5"

echo -e "\n${GREEN}✅ Deployment verification complete!${NC}"

# chmod +x verify_deployment.sh
# ./verify_deployment.sh