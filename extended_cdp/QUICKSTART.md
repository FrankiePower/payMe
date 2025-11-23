# Quick Start Guide - Version 1.1.0

Get up and running with the fixed blockchain operations module in 5 minutes!

---

## 🚀 Installation (2 minutes)

```bash
# 1. Install dependencies
npm install

# 2. Create environment file
cp env.example .env

# 3. Edit .env with your CDP credentials
# Get credentials from: https://portal.cdp.coinbase.com
```

Your `.env` should look like:
```bash
CDP_API_KEY_ID=your_api_key_id_here
CDP_API_KEY_SECRET=your_api_key_secret_here

# Optional: Add custom RPC URLs for better reliability
RPC_URL_BASE=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
```

---

## 📝 Basic Usage (3 minutes)

### 1. Initialize the Module

```typescript
import { CdpClient } from "@coinbase/cdp-sdk";
import { BlockchainOperations } from "./src/blockchain.js";
import { getCdpCredentials, getCustomRpcUrls } from "./src/config.js";

// Load credentials (validates automatically)
const credentials = getCdpCredentials();
const cdp = new CdpClient(credentials);

// Create blockchain operations
const blockchain = new BlockchainOperations(cdp.openApiClient, {
  rpcUrls: getCustomRpcUrls(), // Optional: custom RPCs
});

// Create an account
const account = await cdp.evm.createAccount({ name: "MyWallet" });
console.log(`Address: ${account.address}`);
```

### 2. Read Token Information

```typescript
import { formatUnits } from "viem";

// Read USDC info on Base
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

const info = await blockchain.getTokenInfo(USDC, "base");
console.log(`Token: ${info.name} (${info.symbol})`);

const balance = await blockchain.getERC20Balance(
  USDC,
  account.address,
  "base"
);
console.log(`Balance: ${formatUnits(balance, 6)} USDC`);
```

### 3. Transfer Tokens

```typescript
import { parseUnits } from "viem";

// Get testnet funds first (for testnets)
await account.requestFaucet({
  network: "base-sepolia",
  token: "eth",
});

// Transfer ETH
const result = await blockchain.transferNative({
  from: account.address,
  to: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
  amountInEth: "0.001",
  network: "base-sepolia",
});

console.log(`Transaction: ${result.transactionHash}`);
```

### 4. Approve & Check Allowances

```typescript
const UNISWAP_ROUTER = "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24";

// Approve USDC for Uniswap
await blockchain.approveERC20({
  from: account.address,
  spender: UNISWAP_ROUTER,
  tokenAddress: USDC,
  amount: parseUnits("1000", 6),
  network: "base",
});

// Check allowance
const allowance = await blockchain.checkAllowance({
  owner: account.address,
  spender: UNISWAP_ROUTER,
  tokenAddress: USDC,
  network: "base",
});

console.log(`Allowance: ${formatUnits(allowance, 6)} USDC`);
```

---

## 🎯 What's Fixed in v1.1.0?

All these features now work correctly:

✅ **Read Operations**
```typescript
// These all work now!
await blockchain.readContract({...});
await blockchain.getTokenInfo(tokenAddress, network);
await blockchain.getERC20Balance(token, account, network);
await blockchain.checkAllowance({...});
```

✅ **ENS Registration** (Production-Ready)
```typescript
// Full commit-reveal pattern (~60 seconds)
await blockchain.registerENSName({
  owner: account.address,
  name: "myname",
  durationInYears: 1,
  network: "ethereum-sepolia",
});
```

✅ **Correct Chain IDs**
```typescript
// Each network now uses the correct chain ID
// - ethereum: 1
// - base: 8453
// - ethereum-sepolia: 11155111
// - base-sepolia: 84532
```

✅ **Better Error Messages**
```typescript
try {
  await blockchain.transferNative({...});
} catch (error) {
  // Now shows helpful errors like:
  // "Insufficient balance for transaction on base-sepolia"
  // "CDP API rate limit exceeded. Please wait..."
  // "Transaction nonce error - pending transactions detected"
}
```

---

## 🔧 Common Patterns

### Pattern 1: Check Balance Before Transfer

```typescript
const balance = await blockchain.getERC20Balance(token, account, network);
const required = parseUnits("100", 6);

if (balance >= required) {
  await blockchain.transferERC20({...});
} else {
  console.log("Insufficient balance");
}
```

### Pattern 2: Approve Only If Needed

```typescript
const currentAllowance = await blockchain.checkAllowance({...});
const required = parseUnits("1000", 6);

if (currentAllowance < required) {
  await blockchain.approveERC20({...});
}
```

### Pattern 3: Custom RPC for Production

```typescript
// In .env
RPC_URL_BASE=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_URL_ETHEREUM=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

// Automatically loaded
const blockchain = new BlockchainOperations(cdp.openApiClient, {
  rpcUrls: getCustomRpcUrls(),
});
```

---

## 🧪 Test Everything

Run the comprehensive example:

```bash
npm start
```

This will test:
- ✅ Read operations
- ✅ Token transfers
- ✅ Approvals & allowances
- ✅ Error handling
- ✅ Chain ID mapping

---

## 📚 Next Steps

1. **Read the Full Documentation**: [README.md](README.md)
2. **Check What Changed**: [CHANGELOG.md](CHANGELOG.md)
3. **See Detailed Fixes**: [FIXES_SUMMARY.md](FIXES_SUMMARY.md)
4. **Explore the Code**: [src/blockchain.ts](src/blockchain.ts)
5. **Cross-Chain Payments**: [src/cre-x402.ts](src/cre-x402.ts)

---

## 💡 Pro Tips

### Tip 1: Use Idempotency Keys
```typescript
await blockchain.transferNative({
  // ... other params
  idempotencyKey: `transfer-${Date.now()}`,
});
```

### Tip 2: Format Amounts Properly
```typescript
// Always use parseUnits for inputs
const amount = parseUnits("1.5", 6); // 1500000n

// Always use formatUnits for display
const display = formatUnits(amount, 6); // "1.5"
```

### Tip 3: Handle Errors Gracefully
```typescript
try {
  const result = await blockchain.transferERC20({...});
  console.log(`Success: ${result.transactionHash}`);
} catch (error) {
  if (error.message.includes("Insufficient balance")) {
    // Handle insufficient funds
  } else if (error.message.includes("rate limit")) {
    // Wait and retry
  } else {
    // Other error
  }
}
```

### Tip 4: Cache Token Info
```typescript
// Cache decimals to avoid repeated reads
const decimalsCache = new Map<string, number>();

async function getDecimals(token: string, network: string) {
  const key = `${token}-${network}`;
  if (!decimalsCache.has(key)) {
    const info = await blockchain.getTokenInfo(token, network);
    decimalsCache.set(key, info.decimals);
  }
  return decimalsCache.get(key)!;
}
```

---

## 🆘 Troubleshooting

### Issue: "Missing required environment variables"
**Solution**: Ensure your `.env` file has `CDP_API_KEY_ID` and `CDP_API_KEY_SECRET`

### Issue: "Failed to read contract"
**Solution**: 
- Check network name is correct
- Verify contract address
- Add custom RPC URL if using default RPCs

### Issue: "Insufficient balance"
**Solution**: 
- For testnets: Use `account.requestFaucet()`
- For mainnet: Ensure account has funds

### Issue: "ENS registration failed"
**Solution**: 
- Ensure you have enough ETH for the registration fee
- Wait 60 seconds between commit and register
- Check name is available first

---

## 🎉 You're Ready!

You now have a fully functional blockchain operations module with:
- ✅ Working read operations
- ✅ Production-ready ENS registration
- ✅ Proper chain ID handling
- ✅ Comprehensive error handling
- ✅ Custom RPC support

Happy building! 🚀

