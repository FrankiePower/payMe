#!/bin/bash

# Balance checker for multiple EVM chains
# Usage: ./scripts/check-balances.sh

set -e

# Load environment variables
source .env

# Get deployer address from private key
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

echo "======================================"
echo "Multi-Chain Balance Checker"
echo "======================================"
echo "Deployer Address: $DEPLOYER"
echo ""

# Function to check ETH and USDC balance
check_balance() {
    local chain_name=$1
    local rpc_url=$2
    local usdc_address=$3

    echo "=== $chain_name ==="

    # Check ETH balance
    eth_balance=$(cast balance $DEPLOYER --rpc-url $rpc_url --ether 2>/dev/null || echo "RPC Error")
    echo "  ETH:  $eth_balance"

    # Check USDC balance (if address provided)
    if [ -n "$usdc_address" ] && [ "$usdc_address" != "0x0000000000000000000000000000000000000000" ]; then
        usdc_raw=$(cast call $usdc_address "balanceOf(address)(uint256)" $DEPLOYER --rpc-url $rpc_url 2>/dev/null || echo "0")
        # Convert from 6 decimals (divide by 1,000,000)
        usdc_balance=$(echo "scale=2; $usdc_raw / 1000000" | bc 2>/dev/null || echo "0")
        echo "  USDC: $usdc_balance"
    else
        echo "  USDC: N/A"
    fi
    echo ""
}

# Testnet Chains
echo "╔════════════════════════════════════╗"
echo "║         TESTNET BALANCES           ║"
echo "╔════════════════════════════════════╗"
echo ""

check_balance "Base Sepolia" \
    "$BASE_SEPOLIA_RPC" \
    "$USDC_BASE_SEPOLIA"

check_balance "Arbitrum Sepolia" \
    "$ARB_SEPOLIA_RPC" \
    "$USDC_ARB_SEPOLIA"

check_balance "Optimism Sepolia" \
    "$OPTIMISM_SEPOLIA_RPC" \
    "$USDC_OP_SEPOLIA"

# Mainnet Chains
echo "╔════════════════════════════════════╗"
echo "║         MAINNET BALANCES           ║"
echo "╔════════════════════════════════════╗"
echo ""

# Base Mainnet
check_balance "Base Mainnet" \
    "${BASE_MAINNET_RPC:-https://mainnet.base.org}" \
    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

# Ethereum Mainnet
check_balance "Ethereum Mainnet" \
    "${ETH_MAINNET_RPC:-https://eth.llamarpc.com}" \
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

# Arbitrum Mainnet
check_balance "Arbitrum Mainnet" \
    "${ARB_MAINNET_RPC:-https://arb1.arbitrum.io/rpc}" \
    "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"

# Optimism Mainnet
check_balance "Optimism Mainnet" \
    "${OPTIMISM_MAINNET_RPC:-https://mainnet.optimism.io}" \
    "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"

# Polygon Mainnet (Popular EVM chain)
check_balance "Polygon Mainnet" \
    "${POLYGON_MAINNET_RPC:-https://polygon-rpc.com}" \
    "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

echo "======================================"
echo "Balance check complete!"
echo "======================================"
