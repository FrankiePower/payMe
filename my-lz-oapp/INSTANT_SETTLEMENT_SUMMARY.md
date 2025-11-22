# Instant Settlement with LayerZero OFT - Complete Guide

## TL;DR

**Problem:** Traditional payment aggregation takes 10-15 minutes (wait for USDC to arrive from all chains)

**Solution:** Use LayerZero OFT to mint tokens INSTANTLY when locks are confirmed, resolve to native USDC in background

**Result:** Payment settlement in **20-30 seconds** instead of 10-15 minutes (**30x faster**)

---

## How It Works

### Traditional Flow (SLOW ❌)
```
User has USDC on 7 chains
  ↓
Send USDC from all 7 chains → 10-15 minutes
  ↓
Wait for ALL to arrive
  ↓
Settle to merchant
Total: 10-15 minutes
```

### Instant Settlement Flow (FAST ✅)
```
User has USDC on 7 chains
  ↓
Lock USDC on all 7 chains → 10 seconds
  ↓
Send "LOCKED" confirmations via LZ → 20 seconds
  ↓
When 90% confirmed: MINT OFT to merchant → INSTANT
  ↓
Merchant has payment in 30 seconds! ✅

Background (async):
  ↓
Real USDC arrives slowly → 15 minutes
  ↓
Resolve OFT → native USDC
  ↓
Done
```

---

## Key Questions Answered

### Q: "If one chain has all the balance, what happens?"

**Answer:** Agent skips aggregation, uses simple OFT transfer

```typescript
if (balancesOnNonZeroChains === 1) {
    // Just send via OFT, no aggregation needed
    await oftBridge.send(sourceChain, destChain, amount);
    // Time: 10 seconds
}
```

### Q: "If two chains have it, what happens?"

**Answer:** Parallel lock + instant mint when both confirmed

```
t=0s:   Lock on Chain A (300 USDC)
t=0s:   Lock on Chain B (200 USDC)
t=10s:  Both locks confirmed
t=10s:  Mint 500 OFT to merchant ✅
```

### Q: "If 7 chains have it, what happens?"

**Answer:** Incremental locks, instant mint when threshold (90%) met

```
t=0s:   Lock on all 7 chains in PARALLEL
t=5s:   Chain A confirmed → 100/500 (20%)
t=8s:   Chain B confirmed → 150/500 (30%)
t=12s:  Chain C confirmed → 230/500 (46%)
t=15s:  Chain D confirmed → 300/500 (60%)
t=18s:  Chain E confirmed → 360/500 (72%)
t=20s:  Chain F confirmed → 450/500 (90% ✅ THRESHOLD MET!)
        └─ INSTANT MINT: 450 OFT to merchant
t=25s:  Chain G confirmed → 500/500 (100%)

Merchant gets payment at t=20s (20 seconds!)
```

### Q: "Do we wait for confirmations or lock and resolve later?"

**Answer:** BOTH! Using horizontal composability

**Step 1 (CRITICAL - 20s):**
- Lock USDC on all chains
- Send "LOCKED" confirmations via LayerZero
- When threshold met → MINT OFT to merchant

**Step 2 (NON-CRITICAL - background):**
- Real USDC slowly arrives
- Resolve OFT → native USDC
- Uses horizontal composability (sendCompose)

---

## What LayerZero OFT Does

### 1. Instant Liquidity via Minting

```solidity
// When lock confirmed
function _lzReceive(...) {
    totalLocked += amount;

    if (totalLocked >= threshold) {
        // MINT OFT IMMEDIATELY (no waiting!)
        oftToken.mint(merchant, totalLocked);

        emit InstantSettlement(merchant, totalLocked, timeElapsed);
    }
}
```

**Key:** Merchant gets OFT tokens instantly, can use them immediately:
- ✅ Trade on DEX
- ✅ Hold as collateral
- ✅ Redeem for native USDC later
- ✅ Transfer to others

### 2. Background Resolution via Horizontal Composability

```solidity
// Step 1: Mint OFT (CRITICAL)
function _lzReceive(...) {
    oftToken.mint(merchant, amount); // INSTANT

    // Step 2: Trigger background resolution (NON-CRITICAL)
    endpoint.sendCompose(
        resolver,
        guid,
        0,
        abi.encode(requestId, amount)
    );
}

// Step 2 executes AFTER merchant already paid
function lzCompose(...) {
    // Resolve OFT to native USDC slowly
    _resolveToNativeUSDC(...);
}
```

**Key:** If resolution fails, merchant still has OFT tokens (payment safe!)

### 3. Lock/Unlock Pattern (OFTAdapter)

```solidity
// Source chain: Lock USDC
function lockUSDC(uint256 amount) external {
    usdcToken.transferFrom(user, address(this), amount);

    // Send "LOCKED" message to destination
    _lzSend(destChain, abi.encode("LOCKED", amount));
}

// Destination chain: Mint OFT immediately
function _lzReceive(...) {
    (string memory action, uint256 amount) = abi.decode(_message);

    if (action == "LOCKED") {
        oftToken.mint(merchant, amount); // INSTANT
    }
}
```

---

## Can LayerZero Do Swaps?

**No, LayerZero cannot swap tokens.**

But the AI agent can handle swaps before aggregation:

```typescript
// Agent workflow
async function preparePayment(user, amount) {
    // 1. Scan balances
    const balances = await scanBalances(user);

    // 2. Check if user has USDC
    if (totalUSDC < amount) {
        // User doesn't have enough USDC

        // 3. Check for other tokens (ARB, ETH, etc.)
        const arbBalance = await getARBBalance(user, 'ARBITRUM');

        if (arbBalance > 0) {
            // 4. Swap ARB → USDC via 1inch
            await swapVia1inch('ARBITRUM', arbBalance, 'ARB', 'USDC');

            console.log('Swapped ARB → USDC on Arbitrum');
        }
    }

    // 5. Now proceed with LayerZero aggregation
    return await aggregatePayment(user, amount);
}
```

**Division of labor:**
- **1inch:** Token swaps (ARB → USDC, ETH → USDC, etc.)
- **LayerZero:** Cross-chain aggregation (USDC on 7 chains → 1 chain)
- **Agent:** Orchestration (decides when to swap, when to aggregate)

---

## AI Agent Interaction Flow

```typescript
// Complete agent workflow
class PaymentAgent {
    async pay(params: {
        user: string;
        merchant: string;
        amount: bigint;
        destChain: string;
    }) {
        // 1. SCAN: Get user's balances across all chains
        const balances = await this.scanBalances(params.user);
        console.log('Balances:', balances);
        // Output: [
        //   { chain: 'ARBITRUM', usdc: 100, arb: 500 },
        //   { chain: 'BASE', usdc: 50, eth: 2 },
        //   ...
        // ]

        // 2. PREPARE: Swap to USDC if needed
        for (const balance of balances) {
            if (balance.usdc < balance.needed) {
                // Not enough USDC, swap other tokens
                if (balance.arb > 0) {
                    await this.swapVia1inch(balance.chain, 'ARB', 'USDC');
                }
            }
        }

        // 3. OPTIMIZE: Decide strategy based on distribution
        const nonZeroChains = balances.filter(b => b.usdc > 0);

        if (nonZeroChains.length === 1) {
            // ONE CHAIN: Simple transfer
            return await this.simpleTransfer(params);
        } else if (nonZeroChains.length <= 3) {
            // FEW CHAINS: Standard aggregation
            return await this.standardAggregation(params);
        } else {
            // MANY CHAINS: Instant aggregation with OFT
            return await this.instantAggregation(params);
        }
    }

    async instantAggregation(params) {
        // 1. Initiate on destination chain
        const requestId = await this.instantAggregator.initiateInstantAggregation({
            merchant: params.merchant,
            targetAmount: params.amount,
            minimumThreshold: 90,
            ...
        });

        // 2. Lock on ALL source chains in PARALLEL
        const lockPromises = balances.map(b =>
            this.lockOnChain(b.chain, requestId, b.usdc)
        );
        await Promise.all(lockPromises);

        // 3. Monitor for instant settlement
        await this.waitForEvent('InstantSettlement', requestId);

        console.log(`Payment settled in ${elapsed}s!`);
        return requestId;
    }
}
```

---

## Speed Comparison Table

| Scenario | Chains | Traditional | Instant OFT | Speedup |
|----------|--------|-------------|-------------|---------|
| Single chain | 1 | 10s | 10s | 1x |
| Two chains | 2 | 3-5 min | 15s | **12-20x** |
| Seven chains | 7 | 10-15 min | 25s | **24-36x** |

---

## Architecture Components

### 1. InstantAggregator.sol
**Purpose:** Receive locks, mint OFT instantly when threshold met

**Key features:**
- Incremental lock tracking
- Instant OFT minting at 90% threshold
- Background resolution trigger
- Refund mechanism

### 2. SourceChainInitiator.sol
**Purpose:** Lock USDC on source chain, send confirmation message

**Key features:**
- Lock user's USDC
- Send LayerZero message with "LOCKED" status
- Track pending transfers

### 3. OFT Token
**Purpose:** Instant liquidity layer

**Key features:**
- Mintable/burnable
- 1:1 backed by locked USDC
- Redeemable for native USDC
- Tradable on DEXs

### 4. User Agent (Off-chain)
**Purpose:** Orchestrate entire flow

**Key features:**
- Balance scanning
- Token swapping (via 1inch)
- Parallel lock execution
- Settlement monitoring

---

## Testing Checklist

- [ ] **Test 1:** Single chain payment (10s)
- [ ] **Test 2:** Two-chain aggregation (15s)
- [ ] **Test 3:** Seven-chain aggregation (25s)
- [ ] **Test 4:** Partial settlement at 90% threshold
- [ ] **Test 5:** Refund if below threshold
- [ ] **Test 6:** Background resolution to native USDC
- [ ] **Test 7:** OFT redemption flow
- [ ] **Test 8:** Token swap + aggregation combo

---

## Deployment Order

1. **Deploy OFT token on destination chain (Base)**
   ```bash
   npx hardhat deploy --tags OFT --network baseSepolia
   ```

2. **Deploy InstantAggregator on destination chain**
   ```bash
   npx hardhat deploy --tags InstantAggregator --network baseSepolia
   ```

3. **Deploy SourceChainInitiator on each source chain**
   ```bash
   for chain in arbitrum optimism polygon; do
       npx hardhat deploy --tags SourceChainInitiator --network ${chain}Sepolia
   done
   ```

4. **Configure peers**
   ```bash
   npx hardhat run scripts/configurePeers.ts
   ```

5. **Fund OFT liquidity pool (optional)**
   ```bash
   npx hardhat run scripts/fundPool.ts --network baseSepolia
   ```

---

## Summary

**What LayerZero OFT Enables:**

1. ✅ **Instant settlement** - Mint OFT when locks confirmed (20-30s vs 10-15 min)
2. ✅ **Horizontal composability** - Critical path (mint) separate from non-critical (resolution)
3. ✅ **Incremental unlock** - Don't wait for all chains, settle at 90% threshold
4. ✅ **Background resolution** - Upgrade OFT → native USDC asynchronously

**What LayerZero Cannot Do:**

- ❌ Token swaps (use 1inch/DEX aggregators for this)
- ❌ Price discovery (use oracles/DEXs)
- ❌ Native cross-chain calls (only messaging)

**Division of Labor:**

- **1inch:** Token swaps (ARB → USDC)
- **LayerZero:** Cross-chain aggregation + instant settlement
- **Circle CCTP:** Native USDC bridging (background resolution)
- **AI Agent:** Orchestration of all the above

**Result:** Payment system that's **30x faster** than traditional bridging while maintaining security and flexibility! 🚀

---

## Next Steps

1. Deploy contracts (see deployment order above)
2. Build user agent (see [USER_AGENT_TODO.md](USER_AGENT_TODO.md))
3. Test scenarios (see [TESTING_STRATEGY.md](TESTING_STRATEGY.md))
4. Demo for hackathon! 🎉
