# Smart Contract Interface Reference

## Quick Contract Addresses (Testnet)

### Sepolia
```
LayerZero Endpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f
USDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
CCTP TokenMessenger: 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5
Circle Domain: 0
LZ EID: 40161
```

### Base Sepolia
```
LayerZero Endpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f
USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
CCTP TokenMessenger: 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5
Circle Domain: 6
LZ EID: 40245
```

### Arbitrum Sepolia
```
LayerZero Endpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f
USDC: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
CCTP TokenMessenger: 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5
Circle Domain: 3
LZ EID: 40231
```

---

## MerchantRegistry Interface

### Register a Merchant
```solidity
function registerMerchant(
    bytes32 merchantId,           // keccak256("merchant.eth") or address
    address[] calldata wallets,   // One wallet per chain
    uint32[] calldata chainEids,  // LayerZero endpoint IDs
    uint256[] calldata minThresholds,  // Minimum USDC per chain (6 decimals)
    uint8 defaultChainIndex       // Index of default chain
) external
```

**Example:**
```solidity
bytes32 merchantId = keccak256("pay.franky.eth");

address[] memory wallets = new address[](2);
wallets[0] = 0x1234...;  // Sepolia wallet
wallets[1] = 0x5678...;  // Base wallet

uint32[] memory chains = new uint32[](2);
chains[0] = 40161;  // Sepolia
chains[1] = 40245;  // Base

uint256[] memory thresholds = new uint256[](2);
thresholds[0] = 1000 * 1e6;  // 1000 USDC
thresholds[1] = 500 * 1e6;   // 500 USDC

registry.registerMerchant(merchantId, wallets, chains, thresholds, 0);
```

### Get Merchant Config
```solidity
function getMerchantConfig(bytes32 merchantId)
    external view
    returns (MerchantConfig memory)

struct MerchantConfig {
    address[] wallets;
    uint32[] chainEids;
    uint256[] minThresholds;
    uint8 defaultChainIndex;
    bool isActive;
}
```

---

## PaymentReceiver Interface (OApp)

### Pay Merchant (Same Chain)
```solidity
function payMerchant(
    bytes32 merchantId,
    uint256 amount  // USDC amount (6 decimals)
) external
```

**Example:**
```bash
# 1. Approve USDC
cast send $USDC "approve(address,uint256)" $PAYMENT_RECEIVER 100000000

# 2. Pay
cast send $PAYMENT_RECEIVER "payMerchant(bytes32,uint256)" \
  $(cast --format-bytes32-string "pay.franky.eth") \
  100000000  # 100 USDC
```

### Pay Merchant (Cross-Chain)
```solidity
function payMerchantCrossChain(
    bytes32 merchantId,
    uint256 amount,
    uint32 dstEid,          // Destination chain endpoint ID
    bytes calldata extraOptions  // LayerZero options
) external payable
```

**Example:**
```javascript
// 1. Build options
const options = Options.newOptions()
    .addExecutorLzReceiveOption(200000, 0)      // lzReceive gas
    .addExecutorLzComposeOption(0, 300000, 0);  // lzCompose gas

// 2. Quote fee
const fee = await receiver.quotePayment(
    merchantId,
    ethers.parseUnits("100", 6),  // 100 USDC
    40245,  // Base Sepolia
    options,
    false
);

// 3. Send payment
await usdc.approve(receiver.address, ethers.parseUnits("100", 6));
await receiver.payMerchantCrossChain(
    merchantId,
    ethers.parseUnits("100", 6),
    40245,
    options,
    { value: fee.nativeFee }
);
```

### Quote Payment Fee
```solidity
function quotePayment(
    bytes32 merchantId,
    uint256 amount,
    uint32 dstEid,
    bytes calldata extraOptions,
    bool payInLzToken
) external view returns (MessagingFee memory)

struct MessagingFee {
    uint256 nativeFee;  // Fee in native gas token (ETH)
    uint256 lzTokenFee; // Fee in LZ token (if applicable)
}
```

### Set Payment Composer
```solidity
function setPaymentComposer(address _composer) external onlyOwner
```

### Set Peer (for Cross-Chain)
```solidity
function setPeer(
    uint32 eid,        // Remote chain endpoint ID
    bytes32 peer       // Remote PaymentReceiver address as bytes32
) external onlyOwner
```

**Example:**
```bash
# On Sepolia, set Base as peer
cast send $SEPOLIA_RECEIVER "setPeer(uint32,bytes32)" \
  40245 \
  $(cast --to-bytes32 $BASE_RECEIVER)
```

---

## PaymentComposer Interface (IOAppComposer)

### Configure CCTP
```solidity
function setCCTPTokenMessenger(address _tokenMessenger) external onlyOwner
```

**Example:**
```bash
cast send $COMPOSER "setCCTPTokenMessenger(address)" \
  0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5
```

### Map Chain Domains
```solidity
function setCircleDomain(uint32 eid, uint32 domainId) external onlyOwner
```

**Example:**
```bash
# Map Sepolia
cast send $COMPOSER "setCircleDomain(uint32,uint32)" 40161 0

# Map Base Sepolia
cast send $COMPOSER "setCircleDomain(uint32,uint32)" 40245 6

# Map Arbitrum Sepolia
cast send $COMPOSER "setCircleDomain(uint32,uint32)" 40231 3
```

### Compose Handler (Internal)
```solidity
function lzCompose(
    address _oApp,
    bytes32 _guid,
    bytes calldata _message,
    address _executor,
    bytes calldata _extraData
) external payable override
```
*This is called automatically by LayerZero Endpoint - not called directly*

---

## Events

### PaymentReceiver Events

```solidity
event PaymentReceived(
    bytes32 indexed merchantId,
    address indexed payer,
    uint256 amount,
    uint32 sourceChain,
    bytes32 guid
);

event ComposedForRouting(
    bytes32 indexed merchantId,
    uint256 amount,
    bytes32 guid
);
```

### PaymentComposer Events

```solidity
event OptimalRoutingExecuted(
    bytes32 indexed merchantId,
    uint256 totalAmount,
    uint256[] dispatchPlan,
    uint32[] targetChains
);

event CCTPTransferInitiated(
    bytes32 indexed merchantId,
    uint32 destinationDomain,
    address recipient,
    uint256 amount,
    uint64 nonce
);
```

---

## LayerZero Options Builder

### Gas Limits

```solidity
import { Options } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/Options.sol";

// Basic cross-chain message
bytes memory options = Options.newOptions()
    .addExecutorLzReceiveOption(200000, 0);

// With horizontal composability
bytes memory options = Options.newOptions()
    .addExecutorLzReceiveOption(200000, 0)      // Gas for lzReceive
    .addExecutorLzComposeOption(0, 300000, 0);  // Gas for lzCompose (index 0)
```

### Recommended Gas Limits

| Function | Gas Limit | Notes |
|----------|-----------|-------|
| PaymentReceiver.lzReceive() | 200,000 | Minimal logic, just receive payment |
| PaymentComposer.lzCompose() | 300,000 | CCTP calls + routing logic |
| With lzRead (analyzer) | 500,000+ | Additional gas for cross-chain reads |

---

## Circle CCTP Interface

### Burn USDC (Source Chain)
```solidity
interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}
```

**Used by PaymentComposer:**
```solidity
bytes32 mintRecipient = bytes32(uint256(uint160(recipientAddress)));
uint64 nonce = cctpTokenMessenger.depositForBurn(
    amount,
    destinationDomain,
    mintRecipient,
    address(usdc)
);
```

### Mint USDC (Destination Chain)
```solidity
interface IMessageTransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success);
}
```

*Note: Minting is automatic after Circle attestation*

---

## Helper Functions

### Convert Address ↔ Bytes32
```solidity
// Address to bytes32 (for LayerZero setPeer)
bytes32 peerAddress = bytes32(uint256(uint160(address)));

// Bytes32 to address (for decoding)
address addr = address(uint160(uint256(bytes32Value)));
```

### Calculate Merchant ID
```solidity
// From ENS name
bytes32 merchantId = keccak256("pay.franky.eth");

// From address
bytes32 merchantId = bytes32(uint256(uint160(merchantAddress)));
```

### USDC Amount Formatting
```solidity
// USDC has 6 decimals
uint256 amount = 100 * 1e6;  // 100 USDC
uint256 amount = 1000000;    // 1 USDC
```

---

## Testing Checklist

- [ ] Deploy MerchantRegistry
- [ ] Deploy PaymentReceiver
- [ ] Deploy PaymentComposer
- [ ] Set PaymentComposer in PaymentReceiver
- [ ] Set CCTP TokenMessenger in PaymentComposer
- [ ] Map Circle domains in PaymentComposer
- [ ] Set peers for cross-chain (both directions)
- [ ] Register test merchant
- [ ] Test same-chain payment
- [ ] Test cross-chain payment
- [ ] Verify CCTP bridging
- [ ] Check events emitted

---

## Common Cast Commands

```bash
# Deploy MerchantRegistry
forge create src/MerchantRegistry.sol:MerchantRegistry \
  --rpc-url $RPC \
  --private-key $PK

# Deploy PaymentReceiver
forge create src/PaymentReceiver.sol:PaymentReceiver \
  --rpc-url $RPC \
  --private-key $PK \
  --constructor-args $ENDPOINT $OWNER $USDC $REGISTRY

# Deploy PaymentComposer
forge create src/PaymentComposer.sol:PaymentComposer \
  --rpc-url $RPC \
  --private-key $PK \
  --constructor-args $ENDPOINT $RECEIVER $USDC $REGISTRY $OWNER

# Set composer
cast send $RECEIVER "setPaymentComposer(address)" $COMPOSER \
  --rpc-url $RPC --private-key $PK

# Get merchant config
cast call $REGISTRY "getMerchantConfig(bytes32)" $MERCHANT_ID \
  --rpc-url $RPC

# Check payment event
cast logs --address $RECEIVER \
  "PaymentReceived(bytes32,address,uint256,uint32,bytes32)" \
  --rpc-url $RPC
```

---

**Quick Reference for payme Cross-Chain Payment System**
