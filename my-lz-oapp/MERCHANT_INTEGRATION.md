# 💳 PayMe Merchant Integration Guide

Complete guide for merchants to accept instant cross-chain USDC payments.

---

## 🎯 Overview

**PayMe** enables merchants to receive USDC payments aggregated from multiple chains in ~2 minutes, compared to 10-15 minutes with traditional methods.

### How It Works

```
Customer has USDC on ETH Sepolia
         ↓
Customer initiates payment on Base Sepolia
         ↓
Circle CCTP burns USDC on ETH Sepolia
         ↓
Circle CCTP mints USDC on Base Sepolia (2 min)
         ↓
Merchant receives USDC on Base Sepolia ✅
```

---

## 📋 Prerequisites

1. **Merchant Wallet** (receives USDC payments)
2. **Agent Wallet** (creates payment requests - can be same as merchant wallet)
3. **0.01 ETH** on Base Sepolia (for gas fees)
4. **Node.js & npm** installed

---

## 🚀 Quick Start

### 1. Install Dependencies

```bash
npm install ethers dotenv
```

### 2. Setup Environment

Create `.env` file:

```bash
# Agent wallet (creates payment requests)
AGENT_PRIVATE_KEY=0x...

# Merchant wallet (receives USDC)
MERCHANT_ADDRESS=0x...

# RPC URLs
BASE_SEPOLIA_RPC=https://sepolia.base.org

# Contract addresses
INSTANT_AGGREGATOR=0x69C0eb2a68877b57c756976130099885dcf73d33
```

### 3. Create Payment Request

```javascript
const { ethers } = require('ethers');
require('dotenv').config();

// Import InstantAggregator ABI
const instantAggregatorABI = require('./abis/InstantAggregator.json');

async function createPaymentRequest() {
    // Connect to Base Sepolia
    const provider = new ethers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC);
    const agent = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);

    // Connect to InstantAggregator contract
    const aggregator = new ethers.Contract(
        process.env.INSTANT_AGGREGATOR,
        instantAggregatorABI,
        agent
    );

    // Payment details
    const merchantAddress = process.env.MERCHANT_ADDRESS;
    const targetAmount = ethers.parseUnits('100', 6); // 100 USDC (6 decimals)
    const refundChain = 40161; // ETH Sepolia (for refunds if payment fails)
    const sourceChains = [40161]; // ETH Sepolia
    const expectedAmounts = [ethers.parseUnits('100', 6)]; // 100 USDC from ETH

    // Create payment request
    console.log('Creating payment request...');
    const tx = await aggregator.initiateInstantAggregation(
        merchantAddress,
        targetAmount,
        refundChain,
        sourceChains,
        expectedAmounts,
        { value: ethers.parseEther('0.01') } // 0.01 ETH for refund gas
    );

    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();

    // Get requestId from event
    const event = receipt.logs.find(
        log => log.topics[0] === aggregator.interface.getEvent('InstantAggregationInitiated').topicHash
    );
    const requestId = event.topics[1];

    console.log('✅ Payment request created!');
    console.log('Request ID:', requestId);
    console.log('Share this with customer to complete payment');

    return requestId;
}

createPaymentRequest()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
```

### 4. Monitor Payment Status

```javascript
async function checkPaymentStatus(requestId) {
    const provider = new ethers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC);
    const aggregator = new ethers.Contract(
        process.env.INSTANT_AGGREGATOR,
        instantAggregatorABI,
        provider
    );

    const request = await aggregator.getRequest(requestId);

    console.log('Payment Status:', {
        requestId: request.requestId,
        merchant: request.merchant,
        targetAmount: ethers.formatUnits(request.targetAmount, 6) + ' USDC',
        totalLocked: ethers.formatUnits(request.totalLocked, 6) + ' USDC',
        status: ['PENDING', 'SETTLED', 'REFUNDING', 'REFUNDED'][request.status],
        settled: request.usdcSettledAmount > 0n,
        settledAmount: ethers.formatUnits(request.usdcSettledAmount, 6) + ' USDC'
    });

    return request;
}
```

### 5. Listen for Payment Events

```javascript
async function listenForPayments() {
    const provider = new ethers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC);
    const aggregator = new ethers.Contract(
        process.env.INSTANT_AGGREGATOR,
        instantAggregatorABI,
        provider
    );

    console.log('👂 Listening for payment settlements...');

    // Listen for instant settlements
    aggregator.on('InstantSettlement', (requestId, merchant, amount, timestamp, event) => {
        console.log('\n💰 Payment Received!');
        console.log('Request ID:', requestId);
        console.log('Merchant:', merchant);
        console.log('Amount:', ethers.formatUnits(amount, 6), 'USDC');
        console.log('Time:', new Date(Number(timestamp) * 1000).toISOString());
        console.log('Transaction:', event.log.transactionHash);

        // Trigger order fulfillment
        fulfillOrder(requestId, merchant, amount);
    });

    // Listen for lock confirmations
    aggregator.on('LockConfirmed', (requestId, chainEid, amount, totalLocked) => {
        console.log('\n🔒 Payment Locked:');
        console.log('Request ID:', requestId);
        console.log('From Chain:', chainEid);
        console.log('Amount:', ethers.formatUnits(amount, 6), 'USDC');
        console.log('Total Locked:', ethers.formatUnits(totalLocked, 6), 'USDC');
    });
}

async function fulfillOrder(requestId, merchant, amount) {
    // Your order fulfillment logic here
    console.log('Fulfilling order for request:', requestId);

    // Example: Update database, send confirmation email, ship product, etc.
}

listenForPayments();
```

---

## 📊 Complete Example: Payment Flow

```javascript
const { ethers } = require('ethers');
require('dotenv').config();

const instantAggregatorABI = require('./abis/InstantAggregator.json');

class PayMeMerchant {
    constructor(privateKey, merchantAddress, rpcUrl, aggregatorAddress) {
        this.provider = new ethers.JsonRpcProvider(rpcUrl);
        this.agent = new ethers.Wallet(privateKey, this.provider);
        this.merchantAddress = merchantAddress;
        this.aggregator = new ethers.Contract(
            aggregatorAddress,
            instantAggregatorABI,
            this.agent
        );
    }

    // Create payment request
    async createPayment(amountUSDC, sourceChains = [40161]) {
        const targetAmount = ethers.parseUnits(amountUSDC.toString(), 6);
        const expectedAmounts = sourceChains.map(() => targetAmount);

        console.log(`💳 Creating payment request for ${amountUSDC} USDC...`);

        const tx = await this.aggregator.initiateInstantAggregation(
            this.merchantAddress,
            targetAmount,
            40161, // refund chain
            sourceChains,
            expectedAmounts,
            { value: ethers.parseEther('0.01') }
        );

        const receipt = await tx.wait();
        const event = receipt.logs.find(
            log => log.topics[0] === this.aggregator.interface.getEvent('InstantAggregationInitiated').topicHash
        );
        const requestId = event.topics[1];

        console.log('✅ Payment request created');
        console.log('Request ID:', requestId);
        console.log('TX:', receipt.hash);

        return {
            requestId,
            txHash: receipt.hash,
            amount: amountUSDC,
            merchant: this.merchantAddress
        };
    }

    // Get payment status
    async getStatus(requestId) {
        const request = await this.aggregator.getRequest(requestId);
        const statuses = ['PENDING', 'SETTLED', 'REFUNDING', 'REFUNDED'];

        return {
            requestId: request.requestId,
            merchant: request.merchant,
            user: request.user,
            targetAmount: Number(ethers.formatUnits(request.targetAmount, 6)),
            totalLocked: Number(ethers.formatUnits(request.totalLocked, 6)),
            settledAmount: Number(ethers.formatUnits(request.usdcSettledAmount, 6)),
            status: statuses[request.status],
            isSettled: request.usdcSettledAmount > 0n,
            deadline: new Date(Number(request.deadline) * 1000)
        };
    }

    // Check if payment is complete
    async isPaymentComplete(requestId) {
        const status = await this.getStatus(requestId);
        return status.isSettled;
    }

    // Wait for payment settlement
    async waitForPayment(requestId, timeoutMs = 300000) {
        console.log(`⏳ Waiting for payment settlement...`);

        const startTime = Date.now();

        while (Date.now() - startTime < timeoutMs) {
            const isComplete = await this.isPaymentComplete(requestId);

            if (isComplete) {
                const status = await this.getStatus(requestId);
                console.log(`✅ Payment received: ${status.settledAmount} USDC`);
                return status;
            }

            // Check every 5 seconds
            await new Promise(resolve => setTimeout(resolve, 5000));
        }

        throw new Error('Payment timeout');
    }

    // Listen for real-time settlements
    startListening(onPayment) {
        console.log('👂 Listening for payments...');

        this.aggregator.on('InstantSettlement', async (requestId, merchant, amount, timestamp) => {
            if (merchant.toLowerCase() === this.merchantAddress.toLowerCase()) {
                const payment = {
                    requestId,
                    merchant,
                    amount: Number(ethers.formatUnits(amount, 6)),
                    timestamp: new Date(Number(timestamp) * 1000)
                };

                console.log('\n💰 Payment Received!', payment);

                if (onPayment) {
                    await onPayment(payment);
                }
            }
        });
    }
}

// Usage Example
async function main() {
    const merchant = new PayMeMerchant(
        process.env.AGENT_PRIVATE_KEY,
        process.env.MERCHANT_ADDRESS,
        process.env.BASE_SEPOLIA_RPC,
        process.env.INSTANT_AGGREGATOR
    );

    // Create payment request
    const payment = await merchant.createPayment(100); // 100 USDC

    console.log('\nShare this Request ID with customer:');
    console.log(payment.requestId);

    // Wait for payment
    const result = await merchant.waitForPayment(payment.requestId);
    console.log('\n🎉 Payment Complete!', result);

    // Or listen for real-time payments
    merchant.startListening(async (payment) => {
        console.log('Processing order for payment:', payment.requestId);
        // Your fulfillment logic here
    });
}

// Run
main().catch(console.error);
```

---

## 🔧 Advanced Features

### Custom Payment Amounts Per Chain

```javascript
// Accept 50 USDC from ETH and 50 USDC from Arbitrum
const sourceChains = [40161, 40231]; // ETH, ARB
const expectedAmounts = [
    ethers.parseUnits('50', 6),  // 50 USDC from ETH
    ethers.parseUnits('50', 6)   // 50 USDC from ARB
];
const targetAmount = ethers.parseUnits('100', 6); // Total: 100 USDC
```

### Payment Deadline Handling

```javascript
// Payment expires in 3 minutes (180 seconds)
const status = await merchant.getStatus(requestId);
const now = Date.now();
const deadline = status.deadline.getTime();

if (now > deadline && !status.isSettled) {
    console.log('⚠️ Payment expired - refund initiated');
}
```

### Batch Payment Processing

```javascript
async function processBatch(requestIds) {
    const results = await Promise.all(
        requestIds.map(id => merchant.getStatus(id))
    );

    const settled = results.filter(r => r.isSettled);
    console.log(`✅ ${settled.length}/${requestIds.length} payments settled`);

    return settled;
}
```

---

## 🔗 Contract Addresses

### Base Sepolia (Testnet)
- **InstantAggregator**: `0x69C0eb2a68877b57c756976130099885dcf73d33`
- [View on BaseScan](https://sepolia.basescan.org/address/0x69C0eb2a68877b57c756976130099885dcf73d33)

### ETH Sepolia (Testnet)
- **SourceChainInitiator**: `0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5`
- [View on Etherscan](https://sepolia.etherscan.io/address/0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5)

---

## 📚 API Reference

### `initiateInstantAggregation()`

Creates a new payment request.

**Parameters:**
- `merchant` (address): Merchant wallet receiving USDC
- `targetAmount` (uint256): Total USDC amount (6 decimals)
- `refundChain` (uint32): Chain EID for refunds if payment fails
- `sourceChains` (uint32[]): Array of source chain EIDs
- `expectedAmounts` (uint256[]): Expected USDC from each chain

**Returns:** `bytes32 requestId`

**Requires:** 0.01 ETH sent with transaction (for refund gas)

---

### `getRequest()`

Get payment request details.

**Parameters:**
- `requestId` (bytes32): Payment request ID

**Returns:**
```solidity
struct {
    bytes32 requestId;
    address user;
    address merchant;
    uint256 targetAmount;
    uint256 totalLocked;
    uint32 destinationChain;
    uint32 refundChain;
    uint256 deadline;
    uint256 refundGasDeposit;
    SettlementStatus status; // 0=PENDING, 1=SETTLED, 2=REFUNDING, 3=REFUNDED
    bool exists;
    uint256 usdcSettledAmount;
}
```

---

## 🐛 Troubleshooting

### Payment Not Settling

1. **Check USDC was sent** from source chain
2. **Verify Circle CCTP** attestation (takes 1-2 minutes)
3. **Check total locked** matches target amount
4. **Ensure deadline** hasn't expired

```javascript
const status = await merchant.getStatus(requestId);
console.log('Locked:', status.totalLocked, 'Target:', status.targetAmount);
```

### Transaction Reverts

- **"Insufficient refund gas"**: Send at least 0.01 ETH with transaction
- **"Invalid merchant"**: Check merchant address is not zero address
- **"Length mismatch"**: sourceChains and expectedAmounts arrays must match

---

## 💬 Support

- **GitHub**: [PayMe Issues](https://github.com/YourRepo/payMe/issues)
- **Discord**: [Join Community](#)
- **Docs**: [Full Documentation](#)

---

## ⚡ Next Steps

1. ✅ Create your first payment request
2. ✅ Test with testnet USDC
3. ✅ Integrate event listeners
4. ✅ Deploy to production

**Ready to accept instant cross-chain payments!** 🚀
