#!/bin/bash

# Quick check of test wallet balances

source .env

echo "======================================"
echo "  Test Wallet Status"
echo "======================================"
echo ""
echo "Address: $TEST_WALLET_ADDRESS"
echo ""

echo "=== Base Sepolia Balances ==="
ETH_BALANCE=$(cast balance $TEST_WALLET_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --ether 2>/dev/null || echo "Error")
echo "ETH: $ETH_BALANCE"

USDC_RAW=$(cast call $USDC_BASE_SEPOLIA "balanceOf(address)(uint256)" $TEST_WALLET_ADDRESS --rpc-url $BASE_SEPOLIA_RPC 2>/dev/null || echo "0")
USDC_BALANCE=$(echo "scale=2; $USDC_RAW / 1000000" | bc 2>/dev/null || echo "0")
echo "USDC: $USDC_BALANCE (raw: $USDC_RAW)"
echo ""

if [ "$USDC_RAW" = "0" ]; then
    echo "⚠️  No USDC detected!"
    echo ""
    echo "Get USDC from Circle faucet:"
    echo "  1. Visit: https://faucet.circle.com/"
    echo "  2. Select: Base Sepolia"
    echo "  3. Enter address: $TEST_WALLET_ADDRESS"
    echo "  4. Request 1-10 USDC"
    echo ""
fi

if [ "$ETH_BALANCE" = "0.000000000000000000" ] || [ "$ETH_BALANCE" = "Error" ]; then
    echo "⚠️  No ETH detected!"
    echo ""
    echo "Get ETH from Base faucet:"
    echo "  1. Visit: https://www.coinbase.com/faucets/base-ethereum-goerli-faucet"
    echo "  2. Enter address: $TEST_WALLET_ADDRESS"
    echo "  3. Complete captcha and request ETH"
    echo ""
fi

if [ "$USDC_RAW" != "0" ] && [ "$ETH_BALANCE" != "0.000000000000000000" ]; then
    echo "✅ Test wallet funded and ready!"
    echo ""
    echo "Run payment flow test:"
    echo "  forge script script/TestPaymentFlow.s.sol:TestPaymentFlow \\"
    echo "    --rpc-url \$BASE_SEPOLIA_RPC --broadcast -vv"
    echo ""
fi
