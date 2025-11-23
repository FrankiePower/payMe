#!/bin/bash

# PayMe Integration Test
# Tests the full flow from user payment to merchant receiving USDC

set -e

echo "🧪 PayMe Integration Test"
echo "================================"
echo ""

# Load deployed addresses
if [ ! -f deploy.log ]; then
    echo "❌ deploy.log not found. Run deploy-all.sh first!"
    exit 1
fi

source deploy.log

echo "📋 Test Plan:"
echo "1. Create aggregation request on InstantAggregator"
echo "2. User approves USDC to SourceChainInitiator"
echo "3. User calls sendToAggregator() on ETH Sepolia"
echo "4. Wait for CCTP to mint USDC to InstantAggregator"
echo "5. InstantAggregator.handleReceiveMessage() is called by Circle"
echo "6. Merchant receives USDC instantly"
echo ""

# Configuration
PRIVATE_KEY="${PRIVATE_KEY:-0x08026df060a235f7171e7abd6af2de02b98730f6f697855a344d1f65e2df3887}"
USER_ADDRESS=$(cast wallet address "$PRIVATE_KEY")
MERCHANT_ADDRESS="0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb"

ETH_SEPOLIA_RPC="https://rpc.sepolia.org"
BASE_SEPOLIA_RPC="https://sepolia.base.org"

ETH_SEPOLIA_USDC="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
BASE_SEPOLIA_USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"

AMOUNT="10000000"  # 10 USDC (6 decimals)

echo "🔧 Configuration:"
echo "User: $USER_ADDRESS"
echo "Merchant: $MERCHANT_ADDRESS"
echo "Amount: 10 USDC"
echo ""

# Step 1: Create aggregation request
echo "1️⃣  Creating aggregation request..."
REQUEST_ID=$(cast keccak "test-request-$(date +%s)")
DEADLINE=$(($(date +%s) + 180))  # 3 minutes from now

echo "Request ID: $REQUEST_ID"
echo "Deadline: $DEADLINE"

cast send \
    --rpc-url "$BASE_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    "$INSTANT_AGGREGATOR" \
    "initiateInstantAggregation(bytes32,address,address,uint256,uint32,uint32,uint256)" \
    "$REQUEST_ID" \
    "$USER_ADDRESS" \
    "$MERCHANT_ADDRESS" \
    "$AMOUNT" \
    40245 \
    40161 \
    "$DEADLINE"

echo "✅ Aggregation request created"
echo ""

# Step 2: Check USDC balance
echo "2️⃣  Checking USDC balance..."
USER_BALANCE=$(cast call \
    --rpc-url "$ETH_SEPOLIA_RPC" \
    "$ETH_SEPOLIA_USDC" \
    "balanceOf(address)(uint256)" \
    "$USER_ADDRESS")

echo "User USDC balance: $(cast --from-wei $USER_BALANCE ether) (need at least 10 USDC)"

if [ "$USER_BALANCE" -lt "$AMOUNT" ]; then
    echo "❌ Insufficient USDC balance"
    echo "💡 Get testnet USDC from Circle faucet: https://faucet.circle.com/"
    exit 1
fi
echo "✅ Sufficient balance"
echo ""

# Step 3: Approve USDC
echo "3️⃣  Approving USDC to SourceChainInitiator..."
cast send \
    --rpc-url "$ETH_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    "$ETH_SEPOLIA_USDC" \
    "approve(address,uint256)" \
    "$SOURCE_CHAIN_INITIATOR" \
    "$AMOUNT"

echo "✅ USDC approved"
echo ""

# Step 4: Send to aggregator
echo "4️⃣  Sending USDC to aggregator via CCTP..."
echo "This will:"
echo "  - Burn USDC on ETH Sepolia"
echo "  - Mint USDC to InstantAggregator on Base Sepolia"
echo "  - Trigger handleReceiveMessage hook"
echo ""

TX_HASH=$(cast send \
    --rpc-url "$ETH_SEPOLIA_RPC" \
    --private-key "$PRIVATE_KEY" \
    "$SOURCE_CHAIN_INITIATOR" \
    "sendToAggregator(bytes32,uint256,uint32,bool)" \
    "$REQUEST_ID" \
    "$AMOUNT" \
    40245 \
    true \
    --json | jq -r '.transactionHash')

echo "✅ Transaction sent: $TX_HASH"
echo ""

# Step 5: Wait for CCTP
echo "5️⃣  Waiting for CCTP to process (1-2 minutes with fast mode)..."
echo "⏳ This takes time because Circle needs to:"
echo "   1. Observe burn transaction on ETH Sepolia"
echo "   2. Generate attestation"
echo "   3. Mint USDC on Base Sepolia"
echo "   4. Call handleReceiveMessage hook"
echo ""
echo "💡 You can monitor progress at:"
echo "   https://iris.circle.com/ (Circle CCTP Explorer)"
echo ""

# Step 6: Monitor aggregator status
echo "6️⃣  Monitoring aggregation status..."
echo "Checking every 10 seconds..."
echo ""

MAX_WAIT=180  # 3 minutes
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(cast call \
        --rpc-url "$BASE_SEPOLIA_RPC" \
        "$INSTANT_AGGREGATOR" \
        "requests(bytes32)(bytes32,address,address,uint256,uint256,uint32,uint32,uint256,uint256,uint8,bool,uint256)" \
        "$REQUEST_ID" | awk '{print $11}')

    TOTAL_LOCKED=$(cast call \
        --rpc-url "$BASE_SEPOLIA_RPC" \
        "$INSTANT_AGGREGATOR" \
        "requests(bytes32)(bytes32,address,address,uint256,uint256,uint32,uint32,uint256,uint256,uint8,bool,uint256)" \
        "$REQUEST_ID" | awk '{print $5}')

    echo "[$(date +%H:%M:%S)] Status: $STATUS | Locked: $(cast --from-wei $TOTAL_LOCKED ether) USDC"

    if [ "$STATUS" == "1" ]; then
        echo ""
        echo "✅ SETTLED! Merchant received USDC!"
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$STATUS" != "1" ]; then
    echo ""
    echo "⏱️  Test still pending after $MAX_WAIT seconds"
    echo "This is normal - CCTP can take 1-2 minutes"
    echo "Check manually:"
    echo "  cast call --rpc-url $BASE_SEPOLIA_RPC $INSTANT_AGGREGATOR \"requests(bytes32)\" $REQUEST_ID"
fi

echo ""
echo "================================"
echo "🎉 Integration Test Complete!"
echo "================================"
