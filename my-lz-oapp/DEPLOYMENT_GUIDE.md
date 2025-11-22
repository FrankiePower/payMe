# payme Cross-Chain Payment System - Deployment Guide

## Architecture Overview

### Horizontal Composability Flow
```
┌─────────────────────────────────────────────────────────────┐
│ STEP 0: User Pays Merchant from Any Chain                  │
│ "Send 100 USDC to pay.franky.eth from Base"                │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ STEP 1 (CRITICAL - lzReceive):                             │
│ PaymentReceiver receives payment & emits PaymentReceived   │
│ ✅ Payment is SAFE - even if Step 2 fails                  │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼ endpoint.sendCompose()
┌─────────────────────────────────────────────────────────────┐
│ STEP 2 (NON-CRITICAL - lzCompose):                         │
│ PaymentComposer optimally routes USDC via CCTP             │
│ - Checks merchant's balances across chains                 │
│ - Distributes USDC to fill deficits or equally             │
│ - Executes Circle CCTP bridging                            │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ RESULT: Merchant receives USDC on optimal chain(s)         │
│ Balance optimized across all chains automatically          │
└─────────────────────────────────────────────────────────────┘
```

---

## Contracts to Deploy

### 1. MerchantRegistry
- **Purpose:** Stores merchant payment preferences
- **Deploy Once:** Per chain where PaymentReceiver is deployed
- **Constructor Args:** None (just owner)

### 2. PaymentReceiver (OApp)
- **Purpose:** Receives cross-chain payments
- **Deploy Once:** Per chain
- **Constructor Args:**
  - `_endpoint`: LayerZero endpoint address
  - `_owner`: Contract owner
  - `_usdc`: USDC token address on this chain
  - `_merchantRegistry`: MerchantRegistry address

### 3. PaymentComposer (IOAppComposer)
- **Purpose:** Executes optimal routing via CCTP
- **Deploy Once:** Per chain
- **Constructor Args:**
  - `_endpoint`: LayerZero endpoint address
  - `_paymentReceiver`: PaymentReceiver address
  - `_usdc`: USDC token address
  - `_merchantRegistry`: MerchantRegistry address
  - `_owner`: Contract owner

### 4. GenericUSDCAnalyzer (Optional - Advanced)
- **Purpose:** Cross-chain balance analysis via lzRead
- **Already Exists:** In payme/smartcontract/src/
- **Use Case:** For advanced optimal routing

---

## Deployment Order

### Phase 1: Core Infrastructure

1. **Deploy MerchantRegistry**
   ```solidity
   MerchantRegistry registry = new MerchantRegistry();
   ```

2. **Deploy PaymentReceiver**
   ```solidity
   PaymentReceiver receiver = new PaymentReceiver(
       LAYERZERO_ENDPOINT, // 0x6EDCE65403992e310A62460808c4b910D972f10f (Sepolia)
       msg.sender,          // owner
       USDC_ADDRESS,        // USDC token on this chain
       address(registry)
   );
   ```

3. **Deploy PaymentComposer**
   ```solidity
   PaymentComposer composer = new PaymentComposer(
       LAYERZERO_ENDPOINT,
       address(receiver),
       USDC_ADDRESS,
       address(registry),
       msg.sender
   );
   ```

4. **Configure PaymentReceiver**
   ```solidity
   receiver.setPaymentComposer(address(composer));
   ```

5. **Configure PaymentComposer**
   ```solidity
   // Set Circle CCTP TokenMessenger
   composer.setCCTPTokenMessenger(CCTP_TOKEN_MESSENGER);

   // Map LayerZero EIDs to Circle domains
   composer.setCircleDomain(40161, 0);  // Sepolia → Circle Sepolia (domain 0)
   composer.setCircleDomain(40245, 6);  // Base Sepolia → Circle Base (domain 6)
   composer.setCircleDomain(40231, 3);  // Arbitrum Sepolia → Circle Arbitrum (domain 3)
   ```

### Phase 2: LayerZero Configuration

6. **Set Peers for Cross-Chain Communication**
   ```solidity
   // On Chain A PaymentReceiver, set Chain B as peer
   receiver.setPeer(
       CHAIN_B_EID,                                    // e.g., 40245 for Base Sepolia
       bytes32(uint256(uint160(CHAIN_B_RECEIVER)))     // PaymentReceiver on Chain B
   );
   ```

---

## Testnet Addresses

### LayerZero V2 Endpoints
| Chain          | Endpoint ID | Endpoint Address                           |
|----------------|-------------|--------------------------------------------|
| Sepolia        | 40161       | 0x6EDCE65403992e310A62460808c4b910D972f10f |
| Base Sepolia   | 40245       | 0x6EDCE65403992e310A62460808c4b910D972f10f |
| Arbitrum Sepolia | 40231     | 0x6EDCE65403992e310A62460808c4b910D972f10f |
| Polygon Amoy   | 40267       | 0x6EDCE65403992e310A62460808c4b910D972f10f |

### Circle CCTP Addresses (Testnet)

#### Sepolia (Domain 0)
- USDC: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
- TokenMessenger: `0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5`
- MessageTransmitter: `0x7865fAfC2db2093669d92c0F33AeEF291086BEFD`

#### Base Sepolia (Domain 6)
- USDC: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
- TokenMessenger: `0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5`
- MessageTransmitter: `0x7865fAfC2db2093669d92c0F33AeEF291086BEFD`

#### Arbitrum Sepolia (Domain 3)
- USDC: `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`
- TokenMessenger: `0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5`
- MessageTransmitter: `0xaCF1ceeF35caAc005e15888dDb8A3515C41B4872`

---

## Merchant Registration

### Register a Merchant

```solidity
bytes32 merchantId = keccak256("merchant.eth");

address[] memory wallets = new address[](3);
wallets[0] = 0x...;  // Merchant wallet on Sepolia
wallets[1] = 0x...;  // Merchant wallet on Base
wallets[2] = 0x...;  // Merchant wallet on Arbitrum

uint32[] memory chainEids = new uint32[](3);
chainEids[0] = 40161;  // Sepolia
chainEids[1] = 40245;  // Base Sepolia
chainEids[2] = 40231;  // Arbitrum Sepolia

uint256[] memory minThresholds = new uint256[](3);
minThresholds[0] = 1000 * 1e6;  // 1000 USDC on Sepolia
minThresholds[1] = 500 * 1e6;   // 500 USDC on Base
minThresholds[2] = 500 * 1e6;   // 500 USDC on Arbitrum

registry.registerMerchant(
    merchantId,
    wallets,
    chainEids,
    minThresholds,
    0  // Default chain index (Sepolia)
);
```

---

## Making a Payment

### Same Chain Payment

```solidity
// Payer approves USDC first
IERC20(usdc).approve(address(receiver), 100 * 1e6);

// Pay merchant
bytes32 merchantId = keccak256("merchant.eth");
receiver.payMerchant(merchantId, 100 * 1e6);
```

### Cross-Chain Payment

```solidity
// 1. Approve USDC
IERC20(usdc).approve(address(receiver), 100 * 1e6);

// 2. Quote the LayerZero fee
bytes memory extraOptions = OptionsBuilder
    .newOptions()
    .addExecutorLzReceiveOption(200000, 0)         // Gas for lzReceive
    .addExecutorLzComposeOption(0, 300000, 0);     // Gas for lzCompose

MessagingFee memory fee = receiver.quotePayment(
    merchantId,
    100 * 1e6,
    40245,  // Base Sepolia
    extraOptions,
    false
);

// 3. Send payment
receiver.payMerchantCrossChain{value: fee.nativeFee}(
    merchantId,
    100 * 1e6,
    40245,
    extraOptions
);
```

---

## Testing Flow

### 1. Deploy on Sepolia
```bash
cd examples/payme/smartcontract
forge script script/DeployPaymentSystem.s.sol --rpc-url $SEPOLIA_RPC --broadcast
```

### 2. Deploy on Base Sepolia
```bash
forge script script/DeployPaymentSystem.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

### 3. Configure Peers
```bash
# On Sepolia PaymentReceiver
cast send $SEPOLIA_RECEIVER "setPeer(uint32,bytes32)" 40245 $(cast --to-bytes32 $BASE_RECEIVER)

# On Base PaymentReceiver
cast send $BASE_RECEIVER "setPeer(uint32,bytes32)" 40161 $(cast --to-bytes32 $SEPOLIA_RECEIVER)
```

### 4. Register Test Merchant
```bash
cast send $SEPOLIA_REGISTRY \
  "registerMerchant(bytes32,address[],uint32[],uint256[],uint8)" \
  $MERCHANT_ID \
  "[$WALLET1,$WALLET2]" \
  "[40161,40245]" \
  "[1000000000,500000000]" \
  0
```

### 5. Make Test Payment
```bash
# Approve USDC
cast send $USDC "approve(address,uint256)" $SEPOLIA_RECEIVER 100000000

# Pay merchant cross-chain
cast send $SEPOLIA_RECEIVER \
  "payMerchantCrossChain(bytes32,uint256,uint32,bytes)" \
  $MERCHANT_ID \
  100000000 \
  40245 \
  $OPTIONS \
  --value 0.01ether
```

---

## Horizontal Composability Execution Options

### For PaymentReceiver._lzReceive()
```solidity
Options.newOptions().addExecutorLzReceiveOption(200000, 0);
```
- `200000`: Gas limit for lzReceive execution
- `0`: No native value needed

### For PaymentComposer.lzCompose()
```solidity
Options.newOptions()
    .addExecutorLzReceiveOption(200000, 0)
    .addExecutorLzComposeOption(0, 300000, 0);
```
- Index `0`: First (and only) composed message
- `300000`: Gas limit for lzCompose execution
- `0`: No native value needed

---

## Circle CCTP Bridging

### How It Works

1. **PaymentComposer burns USDC on source chain**
   ```solidity
   cctpTokenMessenger.depositForBurn(
       amount,              // Amount to bridge
       destinationDomain,   // Circle domain ID
       mintRecipient,       // Recipient as bytes32
       address(usdc)        // USDC token address
   );
   ```

2. **Circle attestation service signs the burn**
   - Wait ~15 minutes for attestation
   - Fetch attestation from Circle API

3. **Claim USDC on destination chain** (automated or manual)
   ```solidity
   messageTransmitter.receiveMessage(message, attestation);
   ```

### LayerZero EID → Circle Domain Mapping

| Chain             | LZ EID | Circle Domain |
|-------------------|--------|---------------|
| Sepolia           | 40161  | 0             |
| Base Sepolia      | 40245  | 6             |
| Arbitrum Sepolia  | 40231  | 3             |
| Polygon Amoy      | 40267  | 7             |

---

## Hackathon Submission Checklist

### LayerZero Bounty
- [ ] Horizontal composability implemented (PaymentReceiver + PaymentComposer)
- [ ] OApp extended with custom logic
- [ ] Cross-chain messaging working
- [ ] Working demo video
- [ ] Feedback form submitted

### Circle Bounty
- [ ] CCTP integration in PaymentComposer
- [ ] Multi-chain USDC transfers
- [ ] Testnet transactions confirmed

### Additional
- [ ] GitHub repository with README
- [ ] Deployed contract addresses documented
- [ ] Test scripts provided

---

## Troubleshooting

### lzReceive() fails
- Check gas limits in options
- Verify peer configuration
- Ensure USDC approval

### lzCompose() not called
- Verify PaymentComposer address is set
- Check compose gas limits
- Ensure endpoint.sendCompose() is reached

### CCTP transfer fails
- Verify USDC approval to TokenMessenger
- Check Circle domain mapping
- Confirm recipient address format

---

## Next Steps

1. Deploy to testnets
2. Test payment flow end-to-end
3. Add ENS integration for merchant names
4. Integrate GenericUSDCAnalyzer for true optimal routing
5. Build backend API for easier interaction
6. Create demo frontend or CLI tool

---

**Built with LayerZero V2 + Circle CCTP**
