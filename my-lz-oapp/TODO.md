# payme Cross-Chain Payment System - TODO

## Project Vision
A universal cross-chain payment system where merchants give a single payment address (e.g., `pay.franky.eth`) and receive USDC from ANY chain, automatically routed to their preferred chain(s) based on balance optimization.

---

## Hackathon Target Bounties

### Primary Targets
- **LayerZero ($20k)** - Best Omnichain Implementation
  - ✅ Use horizontal composability for multi-step cross-chain payments
  - ✅ Extend OApp with custom cross-chain logic
  - ✅ Implement lzRead for balance analysis
  - ✅ Provide feedback form submission

- **Circle ($10k)** - CCTP Integration
  - ✅ Use Circle CCTP for actual USDC bridging
  - ✅ Multi-chain USDC transfers

### Secondary Targets
- **Coinbase CDP** - Server Wallets for agent orchestration (optional)
- **ENS** - Universal payment addresses (stretch goal)

---

## Phase 1: Core Cross-Chain Orchestration (THIS SESSION)

### 1.1 Smart Contract Architecture ✅
- [x] Review GenericUSDCAnalyzer (already exists)
- [ ] Create PaymentReceiver OApp (horizontal composability)
- [ ] Create PaymentComposer contract (receives composed messages)
- [ ] Deploy contracts to testnets (Sepolia, Base Sepolia, Arbitrum Sepolia)

### 1.2 Horizontal Composability Flow
```
Step 1: User sends USDC from Chain A → PaymentReceiver on Chain B
Step 2: PaymentReceiver.lzReceive() checks merchant balances via lzRead
Step 3: PaymentReceiver.lzReceive() calls endpoint.sendCompose()
Step 4: PaymentComposer.lzCompose() executes optimal USDC distribution via CCTP
```

**Key Contracts:**
- [ ] `PaymentReceiver.sol` - Main OApp that receives payments
- [ ] `PaymentComposer.sol` - Composer that executes CCTP bridging
- [ ] `MerchantRegistry.sol` - Stores merchant preferences (chains, thresholds)

### 1.3 Circle CCTP Integration
- [x] Basic CCTP service exists (backend/src/services/circle.ts)
- [ ] Enhance for contract-based calls (not just backend API)
- [ ] Create Solidity CCTP integration in PaymentComposer
- [ ] Test USDC burn/mint flow across chains

### 1.4 Backend Orchestration Service
- [ ] Create unified payment API endpoint: `POST /api/v2/pay`
- [ ] Integrate with LayerZero contracts
- [ ] Add merchant registry management
- [ ] Build balance analysis service using GenericUSDCAnalyzer

---

## Phase 2: ENS Integration (NEXT SESSION)

### 2.1 ENS Resolution
- [ ] Integrate ENS SDK for name resolution
- [ ] Support `pay.franky.eth` → multi-chain addresses
- [ ] Store merchant preferences in ENS text records

### 2.2 Merchant Configuration
- [ ] ENS text record schema:
  - `payme.chains` - Preferred chains (e.g., "BASE,ARB,POLYGON")
  - `payme.thresholds` - Minimum balances (e.g., "1000,500,500")
  - `payme.default` - Default chain (e.g., "BASE")

---

## Phase 3: Agent Integration (TEAMMATE'S WORK)

### 3.1 Agent Architecture (Placeholder)
- [ ] Agent wallet setup (CDP Server Wallets or similar)
- [ ] Autonomous payment routing logic
- [ ] x402 integration (if applicable)

---

## Phase 4: Testing & Demo

### 4.1 Integration Tests
- [ ] End-to-end payment flow test
- [ ] Multi-chain balance reading test
- [ ] CCTP bridging test
- [ ] Horizontal composability test

### 4.2 Demo Preparation
- [ ] Deploy all contracts to testnets
- [ ] Fund test wallets with USDC
- [ ] Create demo video script
- [ ] Prepare presentation slides

### 4.3 Hackathon Submission
- [ ] LayerZero feedback form
- [ ] GitHub repository cleanup
- [ ] README with clear setup instructions
- [ ] Demo video (max 3 min)

---

## Technical Stack

### Smart Contracts
- Solidity ^0.8.22
- Foundry for development
- LayerZero V2 OApp framework
- Circle CCTP contracts

### Backend
- TypeScript + Express.js
- ethers.js v6
- Circle SDK
- LayerZero SDK

### Chains (Testnet)
- Ethereum Sepolia
- Base Sepolia
- Arbitrum Sepolia
- Polygon Mumbai/Amoy

---

## Key Design Decisions

### Why Horizontal Composability?
- **Step 1 (lzReceive):** Critical operation - receive payment confirmation
- **Step 2 (lzCompose):** Non-critical operation - optimal routing via CCTP
- If Step 2 fails, payment is still received, just not optimally routed
- Avoids atomicity issues with vertical composability

### Payment Flow
1. Payer sends USDC to `PaymentReceiver` on any chain
2. `PaymentReceiver` calls `GenericUSDCAnalyzer.analyzeBalances()` via lzRead
3. Get merchant's current balances across all chains
4. Calculate optimal dispatch plan
5. Send composed message to `PaymentComposer`
6. `PaymentComposer` executes CCTP transfers to rebalance merchant's USDC

---

## Resources

- [LayerZero V2 Docs](https://docs.layerzero.network/)
- [Horizontal Composability Guide](https://docs.layerzero.network/v2/developers/evm/oapp/composing-messages)
- [Circle CCTP Docs](https://developers.circle.com/stablecoins/docs/cctp-getting-started)
- [GenericUSDCAnalyzer Contract](./examples/payme/smartcontract/src/GenericUSDCAnalyzer.sol)

---

## Current Focus
🎯 **Phase 1.2: Implement Horizontal Composability with LayerZero + Circle CCTP**
