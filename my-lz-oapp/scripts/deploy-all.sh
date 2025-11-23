#!/bin/bash

# PayMe Deployment Script
# Deploys all contracts in the correct order

set -e

echo "🚀 PayMe Contract Deployment"
echo "================================"
echo ""

# Configuration
PRIVATE_KEY="${PRIVATE_KEY:-0x08026df060a235f7171e7abd6af2de02b98730f6f697855a344d1f65e2df3887}"

# Sepolia Testnet Addresses
ETH_SEPOLIA_RPC="https://rpc.sepolia.org"
BASE_SEPOLIA_RPC="https://sepolia.base.org"

# LayerZero Endpoints (Testnet)
ETH_SEPOLIA_ENDPOINT="0x6EDCE65403992e310A62460808c4b910D972f10f"
BASE_SEPOLIA_ENDPOINT="0x6EDCE65403992e310A62460808c4b910D972f10f"

# Circle CCTP Addresses (Testnet)
ETH_SEPOLIA_USDC="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
ETH_SEPOLIA_TOKEN_MESSENGER="0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5"
ETH_SEPOLIA_MESSAGE_TRANSMITTER="0x7865fAfC2db2093669d92c0F33AeEF291086BEFD"

BASE_SEPOLIA_USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
BASE_SEPOLIA_TOKEN_MESSENGER="0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5"
BASE_SEPOLIA_MESSAGE_TRANSMITTER="0x7865fAfC2db2093669d92c0F33AeEF291086BEFD"

echo "📋 Deployment Plan:"
echo "1. Deploy CctpBridger on Ethereum Sepolia"
echo "2. Deploy SourceChainInitiator on Ethereum Sepolia"
echo "3. Deploy InstantAggregator on Base Sepolia"
echo "4. Configure contracts"
echo ""

# Step 1: Deploy CctpBridger on Ethereum Sepolia
echo "1️⃣  Deploying CctpBridger on Ethereum Sepolia..."
CCTP_BRIDGER=$(forge create \
    --rpc-url "$ETH_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    contracts/CctpBridger.sol:CctpBridger \
    --constructor-args "$ETH_SEPOLIA_TOKEN_MESSENGER" "$ETH_SEPOLIA_USDC" \
    --json | jq -r '.deployedTo')

echo "✅ CctpBridger deployed at: $CCTP_BRIDGER"
echo ""

# Step 2: Deploy SourceChainInitiator on Ethereum Sepolia
echo "2️⃣  Deploying SourceChainInitiator on Ethereum Sepolia..."
OWNER_ADDRESS=$(cast wallet address "$PRIVATE_KEY")
SOURCE_CHAIN_INITIATOR=$(forge create \
    --rpc-url "$ETH_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    contracts/SourceChainInitiator.sol:SourceChainInitiator \
    --constructor-args "$ETH_SEPOLIA_ENDPOINT" "$ETH_SEPOLIA_USDC" "$CCTP_BRIDGER" "$OWNER_ADDRESS" \
    --json | jq -r '.deployedTo')

echo "✅ SourceChainInitiator deployed at: $SOURCE_CHAIN_INITIATOR"
echo ""

# Step 3: Deploy InstantAggregator on Base Sepolia
echo "3️⃣  Deploying InstantAggregator on Base Sepolia..."
INSTANT_AGGREGATOR=$(forge create \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    contracts/InstantAggregator.sol:InstantAggregator \
    --constructor-args "$BASE_SEPOLIA_ENDPOINT" "$BASE_SEPOLIA_MESSAGE_TRANSMITTER" "$OWNER_ADDRESS" \
    --json | jq -r '.deployedTo')

echo "✅ InstantAggregator deployed at: $INSTANT_AGGREGATOR"
echo ""

# Step 4: Configure InstantAggregator
echo "4️⃣  Configuring InstantAggregator..."
# Set USDC token address (using cast as placeholder - replace with actual contract call)
echo "⚠️  Manual step: Call setSwapConfig on InstantAggregator"
echo "   Address: $INSTANT_AGGREGATOR"
echo "   swapRouter: 0x0 (optional)"
echo "   usdcToken: $BASE_SEPOLIA_USDC"
echo ""

# Step 5: Configure SourceChainInitiator
echo "5️⃣  Configuring SourceChainInitiator..."
echo "⚠️  Manual steps:"
echo "   1. Register aggregator: call registerAggregator(40245, $INSTANT_AGGREGATOR)"
echo "   2. Register CCTP domain: call registerCCTPDomain(40245, 6)"
echo ""

echo "================================"
echo "✅ Deployment Complete!"
echo "================================"
echo ""
echo "📝 Deployed Addresses:"
echo "CctpBridger (ETH Sepolia):        $CCTP_BRIDGER"
echo "SourceChainInitiator (ETH Sepolia): $SOURCE_CHAIN_INITIATOR"
echo "InstantAggregator (BASE Sepolia):   $INSTANT_AGGREGATOR"
echo ""
echo "💾 Saving addresses to deploy.log..."
cat > deploy.log << EOF
CCTP_BRIDGER=$CCTP_BRIDGER
SOURCE_CHAIN_INITIATOR=$SOURCE_CHAIN_INITIATOR
INSTANT_AGGREGATOR=$INSTANT_AGGREGATOR
EOF

echo "✅ Addresses saved to deploy.log"
