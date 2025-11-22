# Testing Strategy for Payment Aggregation System

## Overview

This guide covers how to test the payment aggregation system across different scenarios based on the number of chains involved.

---

## Quick Summary: Speed Comparison

| Scenario | Chains | Traditional | With InstantAggregator | Speedup |
|----------|--------|-------------|----------------------|---------|
| Single chain | 1 | 10 seconds | 10 seconds | Same |
| Two chains | 2 | 3-5 minutes | 15-20 seconds | **10x faster** |
| Seven chains | 7 | 10-15 minutes | 20-30 seconds | **30x faster** |

---

## Scenario 1: User Has All USDC on ONE Chain

### Test Setup
```typescript
User balances:
├─ Arbitrum: 500 USDC ✅
└─ All other chains: 0 USDC

Target: Pay 500 USDC to merchant on Base
```

### Expected Behavior
**Agent should SKIP aggregation and use simple OFT transfer**

### Test Steps

1. **Deploy contracts:**
   ```bash
   # On Arbitrum
   - SourceChainInitiator
   - USDCBalanceFetcher

   # On Base
   - PaymentAggregator (or skip, use direct OFT)
   - OFT token
   ```

2. **Agent flow:**
   ```typescript
   // 1. Scan balances
   const balances = await scanner.scanBalances(userAddress, ALL_CHAINS);
   // Result: [{chain: 'ARBITRUM', balance: 500e6}]

   // 2. Detect single chain
   const nonZeroChains = balances.filter(b => b.balance > 0);
   if (nonZeroChains.length === 1) {
       // Simple OFT transfer
       await oftBridge.send({
           dstEid: baseEid,
           to: merchantAddress,
           amountLD: 500e6,
           ...
       });

       console.log('Simple transfer used - NO aggregation needed');
       return;
   }
   ```

3. **Expected timeline:**
   ```
   t=0s:   Agent detects single chain
   t=0s:   Call OFT.send() on Arbitrum
   t=10s:  LayerZero delivers to Base
   t=10s:  Merchant receives 500 USDC ✅

   Total: 10 seconds
   ```

4. **Test assertions:**
   ```javascript
   // After settlement
   assert(merchantBalance === 500e6);
   assert(timeElapsed < 15); // seconds
   assert(noAggregationUsed === true);
   ```

---

## Scenario 2: User Has USDC on TWO Chains

### Test Setup
```typescript
User balances:
├─ Arbitrum: 300 USDC
├─ Base: 200 USDC
└─ All others: 0 USDC

Target: Pay 500 USDC to merchant on Base
```

### Expected Behavior
**Use InstantAggregator with parallel lock confirmations**

### Test Steps

1. **Deploy contracts:**
   ```bash
   # Arbitrum
   npx hardhat deploy --tags SourceChainInitiator --network arbitrumSepolia

   # Base (destination)
   npx hardhat deploy --tags InstantAggregator --network baseSepolia
   npx hardhat deploy --tags OFT --network baseSepolia

   # Configure peers
   npx hardhat run scripts/configurePeers.ts
   ```

2. **Agent flow:**
   ```typescript
   // 1. Scan balances
   const balances = [
       { chain: 'ARBITRUM', balance: 300e6 },
       { chain: 'BASE', balance: 200e6 }
   ];

   // 2. Create aggregation plan
   const plan = {
       requestId: generateId(),
       sources: [
           { chain: 'ARBITRUM', amount: 300e6 },
           { chain: 'BASE', amount: 200e6 }
       ],
       targetAmount: 500e6,
       minimumThreshold: 90 // 450 USDC minimum
   };

   // 3. Initiate aggregation on Base
   const tx = await instantAggregator.initiateInstantAggregation(
       merchantAddress,
       500e6,
       90,
       baseEid, // refund chain
       [arbitrumEid, baseEid],
       [300e6, 200e6],
       { value: ethers.parseEther('0.01') } // refund gas
   );

   // 4. Send locks in PARALLEL
   await Promise.all([
       // Arbitrum
       sourceInitiator_arbitrum.sendToAggregator(
           plan.requestId,
           300e6,
           baseEid,
           options
       ),

       // Base (local)
       sourceInitiator_base.sendToAggregator(
           plan.requestId,
           200e6,
           baseEid,
           options
       )
   ]);

   // 5. Monitor for InstantSettlement event
   await waitForEvent(instantAggregator, 'InstantSettlement');
   ```

3. **Expected timeline:**
   ```
   t=0s:   Agent initiates aggregation
   t=0s:   Agent sends 2 lock messages in parallel
   t=2s:   Base lock confirms (local) → 200/500
   t=10s:  Arbitrum lock confirms (cross-chain) → 500/500 ✅
   t=10s:  InstantAggregator mints 500 OFT to merchant
   t=10s:  Merchant has payment! ✅

   Background (async):
   t=15s:  Arbitrum USDC arrives
   t=15s:  Pool resolves 500 OFT → 500 native USDC

   Total user-facing time: 10 seconds
   Total resolution time: 15 seconds
   ```

4. **Test assertions:**
   ```javascript
   const request = await instantAggregator.getRequest(requestId);

   assert(request.totalLocked === 500e6);
   assert(request.oftMintedAmount === 500e6);
   assert(request.status === SettlementStatus.SETTLED_OFT);
   assert(timeToSettlement < 15); // seconds

   // Merchant balance
   const merchantOFTBalance = await oftToken.balanceOf(merchantAddress);
   assert(merchantOFTBalance === 500e6);
   ```

---

## Scenario 3: User Has USDC on SEVEN Chains

### Test Setup
```typescript
User balances:
├─ Arbitrum: 100 USDC
├─ Base: 50 USDC
├─ Optimism: 80 USDC
├─ Polygon: 70 USDC
├─ Avalanche: 60 USDC
├─ BSC: 90 USDC
└─ Sepolia: 50 USDC
Total: 500 USDC

Target: Pay 500 USDC to merchant on Base
Minimum acceptable: 450 USDC (90%)
```

### Expected Behavior
**Use InstantAggregator with incremental settlement**

### Test Steps

1. **Deploy on all 7 chains:**
   ```bash
   # Script to deploy on all chains
   for chain in arbitrum base optimism polygon avalanche bsc sepolia; do
       npx hardhat deploy --tags SourceChainInitiator --network ${chain}Sepolia
   done

   # Deploy aggregator on Base
   npx hardhat deploy --tags InstantAggregator --network baseSepolia
   ```

2. **Agent flow:**
   ```typescript
   // 1. Scan balances on 7 chains
   const balances = await scanner.scanBalances(userAddress, [
       arbitrumEid, baseEid, optimismEid, polygonEid,
       avalancheEid, bscEid, sepoliaEid
   ]);

   // 2. Create plan (use all 7 chains)
   const plan = {
       sources: balances.map(b => ({
           chainEid: b.chainEid,
           amount: b.balance
       })),
       targetAmount: 500e6,
       minimumThreshold: 90
   };

   // 3. Initiate aggregation
   await instantAggregator.initiateInstantAggregation(...);

   // 4. Send locks from ALL 7 chains in PARALLEL
   const lockPromises = plan.sources.map(source => {
       const initiator = getSourceInitiator(source.chainEid);
       return initiator.sendToAggregator(
           requestId,
           source.amount,
           baseEid,
           options
       );
   });

   // Start all at once
   const startTime = Date.now();
   await Promise.all(lockPromises);

   // 5. Monitor incremental progress
   instantAggregator.on('LockConfirmed', (requestId, chain, amount, total) => {
       console.log(`Lock from ${chain}: ${amount}, Total: ${total}/500`);
   });

   // 6. Wait for instant settlement
   instantAggregator.once('InstantSettlement', (requestId, merchant, amount, elapsed) => {
       console.log(`INSTANT SETTLEMENT: ${amount} USDC in ${elapsed}s`);
   });
   ```

3. **Expected timeline (with network variance):**
   ```
   t=0s:   Agent sends 7 lock messages in parallel

   Locks arrive incrementally:
   t=2s:   Base (local) → 50/500 (10%)
   t=5s:   Arbitrum → 150/500 (30%)
   t=8s:   Optimism → 230/500 (46%)
   t=12s:  BSC → 320/500 (64%)
   t=15s:  Polygon → 390/500 (78%)
   t=18s:  Avalanche → 450/500 (90% THRESHOLD! ✅)
           └─ INSTANT SETTLEMENT TRIGGERS
           └─ Mint 450 OFT to merchant
   t=22s:  Sepolia → 500/500 (100%)

   Merchant receives payment at t=18s (18 seconds!) ✅

   Background resolution:
   t=30s:  All USDC arrives in pool
   t=30s:  Pool has 500 USDC
   t=31s:  Auto-upgrade: 450 OFT → 500 native USDC (if configured)
   ```

4. **Test assertions:**
   ```javascript
   // Check incremental locks
   const lockedAmounts = await Promise.all(
       CHAIN_EIDS.map(eid =>
           instantAggregator.getLockedAmount(requestId, eid)
       )
   );
   assert(lockedAmounts.reduce((a,b) => a+b, 0n) >= 450e6);

   // Check instant settlement
   const request = await instantAggregator.getRequest(requestId);
   assert(request.oftMintedAmount >= 450e6);
   assert(request.status === SettlementStatus.SETTLED_OFT);

   // Check timing
   const events = await instantAggregator.queryFilter('InstantSettlement');
   const settlementEvent = events[0];
   assert(settlementEvent.args.timeElapsed < 30); // Under 30 seconds

   // Check merchant balance
   const merchantBalance = await oftToken.balanceOf(merchantAddress);
   assert(merchantBalance >= 450e6);
   ```

---

## Key Testing Scenarios

### Test Case 1: All Chains Succeed (Happy Path)
```typescript
describe('7-chain aggregation - all succeed', () => {
    it('should settle at 100% in under 30 seconds', async () => {
        const startTime = Date.now();

        // Execute aggregation
        await executeAggregation(plan);

        // Wait for settlement
        await waitForSettlement(requestId);

        const elapsed = Date.now() - startTime;

        expect(elapsed).to.be.lessThan(30000); // 30 seconds
        expect(merchantBalance).to.equal(500e6);
    });
});
```

### Test Case 2: One Chain Fails (90% Settlement)
```typescript
describe('7-chain aggregation - one fails', () => {
    it('should settle at 90% threshold', async () => {
        // Simulate Sepolia failure (50 USDC missing)
        await simulateChainFailure('sepolia');

        // Execute aggregation
        await executeAggregation(plan);

        // Wait for timeout (3 minutes)
        await time.increase(180);

        // Should still settle with 450 USDC
        const request = await instantAggregator.getRequest(requestId);
        expect(request.oftMintedAmount).to.equal(450e6);
        expect(request.status).to.equal(SettlementStatus.SETTLED_OFT);
    });
});
```

### Test Case 3: Below Threshold (Refund)
```typescript
describe('7-chain aggregation - refund scenario', () => {
    it('should refund if below 90% threshold', async () => {
        // Simulate 3 chains failing (only 350 USDC arrives)
        await simulateChainFailure(['sepolia', 'polygon', 'arbitrum']);

        // Execute aggregation
        await executeAggregation(plan);

        // Wait for timeout
        await time.increase(180);

        // Should refund
        const request = await instantAggregator.getRequest(requestId);
        expect(request.status).to.equal(SettlementStatus.REFUNDING);

        // User should receive refund on Base
        const userBalance = await usdcToken.balanceOf(userAddress);
        expect(userBalance).to.be.greaterThanOrEqual(350e6);
    });
});
```

---

## Performance Benchmarks

### Target Metrics

| Metric | Target | Critical Path |
|--------|--------|---------------|
| 1-chain settlement | < 15s | OFT send |
| 2-chain settlement | < 20s | Parallel locks |
| 7-chain settlement | < 30s | Incremental locks, instant mint at 90% |
| Background resolution | < 5 min | USDC arrives, pool redemption |
| Refund processing | < 30s | Cross-chain refund |

### Test Monitoring

```typescript
// Monitor performance
const performanceMonitor = {
    startTime: 0,
    lockTimes: [],
    settlementTime: 0,

    start() {
        this.startTime = Date.now();
    },

    recordLock(chain, amount, total) {
        const elapsed = Date.now() - this.startTime;
        this.lockTimes.push({ chain, amount, total, elapsed });
        console.log(`[${elapsed}ms] Lock from ${chain}: ${amount}, Total: ${total}`);
    },

    recordSettlement(amount) {
        this.settlementTime = Date.now() - this.startTime;
        console.log(`[${this.settlementTime}ms] SETTLED: ${amount} USDC`);
    },

    report() {
        console.log('\n=== Performance Report ===');
        console.log(`Total time to settlement: ${this.settlementTime}ms`);
        console.log(`Average lock time: ${this.avgLockTime()}ms`);
        console.log(`Slowest chain: ${this.slowestChain()}`);
    },

    avgLockTime() {
        return this.lockTimes.reduce((sum, l) => sum + l.elapsed, 0) / this.lockTimes.length;
    },

    slowestChain() {
        return this.lockTimes.sort((a, b) => b.elapsed - a.elapsed)[0].chain;
    }
};
```

---

## End-to-End Test Script

```typescript
// test/e2e/instant-aggregation.test.ts
import { expect } from 'chai';
import { ethers } from 'hardhat';

describe('E2E: Instant Aggregation', () => {
    let agent: PaymentAgent;
    let instantAggregator: InstantAggregator;
    let user: Signer;
    let merchant: Signer;

    before(async () => {
        // Deploy all contracts
        await deployAllChains();

        // Initialize agent
        agent = new PaymentAgent();
    });

    describe('Scenario: 7-chain aggregation', () => {
        it('should aggregate 500 USDC from 7 chains in under 30s', async () => {
            // Setup: Fund user on 7 chains
            await fundUser(user, {
                arbitrum: 100e6,
                base: 50e6,
                optimism: 80e6,
                polygon: 70e6,
                avalanche: 60e6,
                bsc: 90e6,
                sepolia: 50e6
            });

            const monitor = new PerformanceMonitor();
            monitor.start();

            // Execute payment
            const requestId = await agent.payMerchant({
                userAddress: await user.getAddress(),
                merchantAddress: await merchant.getAddress(),
                amount: '500',
                destinationChain: 'BASE_SEPOLIA',
                minimumThreshold: 90
            });

            // Listen for events
            instantAggregator.on('LockConfirmed', (...args) => {
                monitor.recordLock(...args);
            });

            instantAggregator.on('InstantSettlement', (...args) => {
                monitor.recordSettlement(...args);
            });

            // Wait for settlement
            await waitForSettlement(requestId, 60000); // 60s timeout

            monitor.report();

            // Assertions
            const elapsed = monitor.settlementTime;
            expect(elapsed).to.be.lessThan(30000); // Under 30 seconds

            const merchantBalance = await oftToken.balanceOf(
                await merchant.getAddress()
            );
            expect(merchantBalance).to.be.greaterThanOrEqual(450e6);
        });
    });
});
```

---

## Troubleshooting

### Issue: Settlement takes longer than 30s

**Possible causes:**
1. RPC rate limiting
2. LayerZero DVN delays
3. Gas price too low
4. Network congestion

**Solutions:**
```typescript
// Use premium RPC endpoints
const providers = {
    arbitrum: new ethers.JsonRpcProvider('https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY'),
    // ... use Alchemy/Infura for all chains
};

// Increase gas settings
const options = Options.newOptions()
    .addExecutorLzReceiveOption(500000, 0) // More gas
    .toHex();

// Monitor LayerZero delivery
await lzScan.waitForDelivery(guid, { timeout: 60000 });
```

### Issue: Locks not confirming

**Check:**
1. Peer configuration (setPeer on all contracts)
2. LayerZero endpoint addresses
3. USDC approvals
4. Gas fees paid

```bash
# Check peer config
npx hardhat verify-peers --network baseSepolia

# Check LayerZero message status
curl "https://api-testnet.layerzero-scan.com/tx/${guid}"
```

---

## Summary

| Scenario | Speed | Complexity | Gas Cost |
|----------|-------|------------|----------|
| 1 chain | 10s | Low | ~$1 |
| 2 chains | 15s | Medium | ~$3 |
| 7 chains | 25s | High | ~$8 |

**Key innovation:** InstantAggregator provides **30x speed improvement** for multi-chain aggregation vs traditional sequential bridging!

Test all scenarios to validate performance targets. 🚀
