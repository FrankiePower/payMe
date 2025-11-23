#!/bin/bash

set -e

echo "🚀 Deploying PayMe to Base Sepolia"
echo "=================================="
echo ""

# Load environment
source .env

# Base Sepolia addresses
BASE_SEPOLIA_ENDPOINT="0x6EDCE65403992e310A62460808c4b910D972f10f"
BASE_SEPOLIA_MESSAGE_TRANSMITTER="0x7865fAfC2db2093669d92c0F33AeEF291086BEFD"
BASE_SEPOLIA_USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
BASE_SEPOLIA_SWAP_ROUTER="0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4"

# Get deployer address
DEPLOYER=$(cast wallet address $PRIVATE_KEY)
echo "Deployer: $DEPLOYER"
echo ""

# Check balance
BALANCE=$(cast balance $DEPLOYER --rpc-url $BASE_SEPOLIA_RPC)
echo "Balance: $BALANCE wei"
echo ""

# Deploy InstantAggregator
echo "1️⃣  Deploying InstantAggregator..."
INSTANT_AGGREGATOR=$(forge create \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    contracts/InstantAggregator.sol:InstantAggregator \
    --constructor-args "$BASE_SEPOLIA_ENDPOINT" "$BASE_SEPOLIA_MESSAGE_TRANSMITTER" "$DEPLOYER" \
    --json | jq -r '.deployedTo')

echo "✅ InstantAggregator: $INSTANT_AGGREGATOR"
echo ""

# Configure InstantAggregator
echo "2️⃣  Configuring InstantAggregator..."
cast send $INSTANT_AGGREGATOR \
    "setSwapConfig(address,address)" \
    "$BASE_SEPOLIA_SWAP_ROUTER" \
    "$BASE_SEPOLIA_USDC" \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY"

echo "✅ InstantAggregator configured"
echo ""

echo "================================"
echo "✅ Deployment Complete!"
echo "================================"
echo ""
echo "📝 Deployed Addresses:"
echo "InstantAggregator (Base Sepolia): $INSTANT_AGGREGATOR"
echo ""

# Save to file
cat > deploy-base.log << EOF
INSTANT_AGGREGATOR_BASE=$INSTANT_AGGREGATOR
DEPLOYER=$DEPLOYER
TIMESTAMP=$(date)
EOF

echo "💾 Saved to deploy-base.log"
