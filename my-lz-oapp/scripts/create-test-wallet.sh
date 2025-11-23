#!/bin/bash

# Create a new test wallet for testing PayMe contracts
# This wallet will be used to test payment flows

echo "======================================"
echo "  Creating New Test Wallet"
echo "======================================"
echo ""

# Generate new wallet
echo "Generating new wallet..."
WALLET_INFO=$(cast wallet new)

echo "$WALLET_INFO"
echo ""

# Extract address and private key
ADDRESS=$(echo "$WALLET_INFO" | grep "Address:" | awk '{print $2}')
PRIVATE_KEY=$(echo "$WALLET_INFO" | grep "Private key:" | awk '{print $3}')

echo "======================================"
echo "  Wallet Created Successfully!"
echo "======================================"
echo ""
echo "Address: $ADDRESS"
echo "Private Key: $PRIVATE_KEY"
echo ""

echo "======================================"
echo "  Add to .env file:"
echo "======================================"
echo "TEST_WALLET_ADDRESS=$ADDRESS"
echo "TEST_WALLET_PRIVATE_KEY=$PRIVATE_KEY"
echo ""

echo "======================================"
echo "  Next Steps:"
echo "======================================"
echo "1. Save the private key securely (never commit to git)"
echo "2. Get testnet ETH from Base Sepolia faucet:"
echo "   https://www.coinbase.com/faucets/base-ethereum-goerli-faucet"
echo "   Address to fund: $ADDRESS"
echo ""
echo "3. Get testnet USDC from Circle faucet:"
echo "   https://faucet.circle.com/"
echo "   Select: Base Sepolia"
echo "   Address to fund: $ADDRESS"
echo "   Amount: Request 1-10 USDC"
echo ""
echo "4. After receiving funds, run the payment test:"
echo "   forge script script/TestPaymentFlow.s.sol --rpc-url \$BASE_SEPOLIA_RPC --broadcast"
echo ""
