# PayMe CCTP Deployment

## 🚀 Deployed Contracts

### Base Sepolia (Destination Chain - EID: 40245)
- **CctpBridger**: `0x843322039C69690A575Fac5F1885290D1ebfd548`
- **InstantAggregator**: `0x69C0eb2a68877b57c756976130099885dcf73d33` ✅
  - Configured with Uniswap Router & USDC

### ETH Sepolia (Source Chain - EID: 40161)
- **CctpBridger**: `0x56B3c656F20b45A5e656c375C3fEB6Ed4f886689`
- **SourceChainInitiator**: `0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5`

**Deployer**: `0x5C8A5483bCDB51F858a9cF4a647dF6D34fdDf81c`

---

## 📋 Next Steps

### 1. Configure SourceChainInitiator (ETH Sepolia)

```bash
# Register InstantAggregator on Base
cast send 0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5 \
  "registerAggregator(uint32,address)" \
  40245 \
  0x69C0eb2a68877b57c756976130099885dcf73d33 \
  --rpc-url $ETH_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY

# Register CCTP domain for Base (domain 6)
cast send 0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5 \
  "registerCCTPDomain(uint32,uint32)" \
  40245 \
  6 \
  --rpc-url $ETH_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

### 2. Test End-to-End Flow

```bash
# Run the test script
./scripts/test-e2e.sh
```

---

## 🔗 Contract Links

### Base Sepolia
- [InstantAggregator](https://sepolia.basescan.org/address/0x69C0eb2a68877b57c756976130099885dcf73d33)
- [CctpBridger](https://sepolia.basescan.org/address/0x843322039C69690A575Fac5F1885290D1ebfd548)

### ETH Sepolia
- [SourceChainInitiator](https://sepolia.etherscan.io/address/0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5)
- [CctpBridger](https://sepolia.etherscan.io/address/0x56B3c656F20b45A5e656c375C3fEB6Ed4f886689)

---

## 📊 Architecture

```
User (ETH Sepolia)
    ↓
SourceChainInitiator (0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5)
    ↓
CctpBridger (0x56B3c656F20b45A5e656c375C3fEB6Ed4f886689)
    ↓
Circle CCTP (burn USDC on ETH Sepolia)
    ↓
Circle CCTP (mint USDC on Base Sepolia)
    ↓
InstantAggregator (0x69C0eb2a68877b57c756976130099885dcf73d33)
    ↓
Merchant (receives USDC)
```
