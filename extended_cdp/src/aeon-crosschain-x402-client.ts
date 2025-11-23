/**
 * PayMe + Aeon x402 Unified Payment Client
 *
 * Flow:
 * 1. Receive 402 payment request from Aeon
 * 2. Check USDC balance on requested chain (Base)
 * 3. If insufficient → Initiate cross-chain aggregation via PayMe
 * 4. Poll every 5s until balance is sufficient
 * 5. Create X-PAYMENT header and submit to Aeon
 *
 * Dependencies:
 *   npm install @coinbase/cdp-sdk ethers dotenv
 */

import { CdpClient } from "@coinbase/cdp-sdk";
import { ethers } from "ethers";
import crypto from "crypto";

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
  // Aeon API
  AEON_SANDBOX_URL: "https://ai-api-sbx.aeon.xyz",
  AEON_PROD_URL: "https://ai-api.aeon.xyz",

  // RPC URLs
  BASE_SEPOLIA_RPC: "https://sepolia.base.org",
  ETH_SEPOLIA_RPC: "https://sepolia.ethereum.org",

  // Contract Addresses
  INSTANT_AGGREGATOR: "0x69C0eb2a68877b57c756976130099885dcf73d33",
  SOURCE_CHAIN_INITIATOR: "0x17A64FAaf1Db8f1AFDe207D16Df7aA5F23D5deF5",

  // USDC Addresses
  USDC: {
    "base": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "base-sepolia": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "eth-sepolia": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  } as Record<string, string>,

  // Chain EIDs (LayerZero)
  CHAIN_EIDS: {
    "eth-sepolia": 40161,
    "base-sepolia": 40245,
    "arb-sepolia": 40231,
  } as Record<string, number>,

  // Chain IDs (EVM)
  CHAIN_IDS: {
    "base": 8453,
    "base-sepolia": 84532,
    "eth-sepolia": 11155111,
  } as Record<string, number>,

  // Polling
  BALANCE_CHECK_INTERVAL_MS: 5000,
  MAX_WAIT_TIME_MS: 300000, // 5 minutes
};

// =============================================================================
// TYPES
// =============================================================================

// Aeon Types
interface Aeon402Response {
  maxAmountRequired: string;
  payTo: `0x${string}`;
  asset: `0x${string}`;
  network: string;
  scheme: string;
  maxTimeoutSeconds: number;
  resource: string;
  description?: string;
  extra?: {
    orderNo: string;
    name: string;
    version: string;
  };
}

interface AeonPaymentRequired {
  code: string;
  msg: string;
  traceId: string;
  x402Version: string;
  error: string;
  accepts: Aeon402Response[];
}

interface AeonAuthorization {
  from: `0x${string}`;
  to: `0x${string}`;
  value: string;
  validAfter: string;
  validBefore: string;
  nonce: `0x${string}`;
}

interface AeonXPaymentPayload {
  x402Version: number;
  scheme: string;
  network: string;
  payload: {
    signature: `0x${string}`;
    authorization: AeonAuthorization;
  };
}

// PayMe Types
interface PaymentRequest {
  requestId: string;
  merchant: string;
  targetAmount: bigint;
  totalLocked: bigint;
  settledAmount: bigint;
  status: "PENDING" | "SETTLED" | "REFUNDING" | "REFUNDED";
  deadline: Date;
  isSettled: boolean;
}

// =============================================================================
// ABIs (Minimal)
// =============================================================================

const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

const INSTANT_AGGREGATOR_ABI = [
  "function initiateInstantAggregation(address merchant, uint256 targetAmount, uint32 refundChain, uint32[] sourceChains, uint256[] expectedAmounts) payable returns (bytes32)",
  "function getRequest(bytes32 requestId) view returns (tuple(bytes32 requestId, address user, address merchant, uint256 targetAmount, uint256 totalLocked, uint32 destinationChain, uint32 refundChain, uint256 deadline, uint256 refundGasDeposit, uint8 status, bool exists, uint256 usdcSettledAmount))",
  "event InstantAggregationInitiated(bytes32 indexed requestId, address indexed user, address indexed merchant, uint256 targetAmount)",
  "event InstantSettlement(bytes32 indexed requestId, address indexed merchant, uint256 amount, uint256 timestamp)",
];

// =============================================================================
// EIP-712 TYPES FOR AEON
// =============================================================================

const AEON_PAYMENT_TYPES = {
  EIP712Domain: [
    { name: "name", type: "string" },
    { name: "version", type: "string" },
    { name: "chainId", type: "uint256" },
    { name: "verifyingContract", type: "address" },
  ],
  TransferWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
};

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

function generateNonce(): `0x${string}` {
  return `0x${crypto.randomBytes(32).toString("hex")}` as `0x${string}`;
}

function encodePayload(payload: AeonXPaymentPayload): string {
  return Buffer.from(JSON.stringify(payload)).toString("base64");
}

function decodePayload(base64: string): AeonXPaymentPayload {
  return JSON.parse(Buffer.from(base64, "base64").toString("utf-8"));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatUSDC(amount: bigint | string, decimals: number = 6): string {
  const value = typeof amount === "string" ? BigInt(amount) : amount;
  return (Number(value) / 10 ** decimals).toFixed(decimals);
}

function parseUSDC(amount: string, decimals: number = 6): bigint {
  return BigInt(Math.floor(parseFloat(amount) * 10 ** decimals));
}

// =============================================================================
// MAIN CLIENT CLASS
// =============================================================================

class PayMeX402Client {
  private cdp: typeof CdpClient;
  private walletAddress: `0x${string}` | null = null;
  private ethersWallet: ethers.Wallet | null = null;
  private providers: Map<string, ethers.JsonRpcProvider> = new Map();
  private sandbox: boolean;

  constructor(sandbox: boolean = true) {
    this.cdp = CdpClient;
    this.sandbox = sandbox;

    // Initialize providers
    this.providers.set(
      "base-sepolia",
      new ethers.JsonRpcProvider(CONFIG.BASE_SEPOLIA_RPC)
    );
    this.providers.set(
      "eth-sepolia",
      new ethers.JsonRpcProvider(CONFIG.ETH_SEPOLIA_RPC)
    );
  }

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  /**
   * Initialize with CDP SDK (creates managed wallet)
   */
  async initWithCDP(accountName: string = "payme-x402-wallet"): Promise<`0x${string}`> {
    const account = await this.cdp.evm.createAccount({ name: accountName });
    this.walletAddress = account.address as `0x${string}`;
    console.log(`✅ CDP Wallet initialized: ${this.walletAddress}`);
    return this.walletAddress;
  }

  /**
   * Initialize with private key (for PayMe contract interactions)
   */
  initWithPrivateKey(privateKey: string, network: string = "base-sepolia"): `0x${string}` {
    const provider = this.providers.get(network);
    if (!provider) throw new Error(`Unknown network: ${network}`);

    this.ethersWallet = new ethers.Wallet(privateKey, provider);
    this.walletAddress = this.ethersWallet.address as `0x${string}`;
    console.log(`✅ Ethers Wallet initialized: ${this.walletAddress}`);
    return this.walletAddress;
  }

  /**
   * Set wallet address manually
   */
  setWallet(address: `0x${string}`): void {
    this.walletAddress = address;
  }

  getWallet(): `0x${string}` | null {
    return this.walletAddress;
  }

  // ===========================================================================
  // BALANCE CHECKING
  // ===========================================================================

  /**
   * Check USDC balance on a specific chain
   */
  async getUSDCBalance(
    network: string,
    address?: `0x${string}`
  ): Promise<{ balance: bigint; formatted: string }> {
    const walletAddress = address || this.walletAddress;
    if (!walletAddress) throw new Error("Wallet not initialized");

    const provider = this.providers.get(network);
    if (!provider) throw new Error(`Unknown network: ${network}`);

    const usdcAddress = CONFIG.USDC[network];
    if (!usdcAddress) throw new Error(`USDC not configured for ${network}`);

    const usdc = new ethers.Contract(usdcAddress, ERC20_ABI, provider);
    const balance = await usdc.balanceOf(walletAddress);

    return {
      balance: balance,
      formatted: formatUSDC(balance),
    };
  }

  /**
   * Check if balance is sufficient for payment
   */
  async hasEnoughBalance(
    network: string,
    requiredAmount: string | bigint
  ): Promise<boolean> {
    const { balance } = await this.getUSDCBalance(network);
    const required = typeof requiredAmount === "string" 
      ? BigInt(requiredAmount) 
      : requiredAmount;
    return balance >= required;
  }

  // ===========================================================================
  // PAYME CROSS-CHAIN AGGREGATION
  // ===========================================================================

  /**
   * Initiate cross-chain USDC aggregation via PayMe
   */
  async initiateAggregation(
    targetAmount: bigint,
    sourceChains: string[] = ["eth-sepolia"],
    merchantAddress?: `0x${string}`
  ): Promise<{ requestId: string; txHash: string }> {
    if (!this.ethersWallet) {
      throw new Error("Ethers wallet not initialized. Call initWithPrivateKey() first.");
    }

    const merchant = merchantAddress || this.walletAddress!;
    const provider = this.providers.get("base-sepolia")!;

    const aggregator = new ethers.Contract(
      CONFIG.INSTANT_AGGREGATOR,
      INSTANT_AGGREGATOR_ABI,
      this.ethersWallet.connect(provider)
    );

    // Convert chain names to EIDs
    const chainEids = sourceChains.map((chain) => {
      const eid = CONFIG.CHAIN_EIDS[chain];
      if (!eid) throw new Error(`Unknown chain: ${chain}`);
      return eid;
    });

    // Split amount evenly across source chains
    const amountPerChain = targetAmount / BigInt(sourceChains.length);
    const expectedAmounts = sourceChains.map(() => amountPerChain);

    console.log(`\n🔄 Initiating cross-chain aggregation...`);
    console.log(`   Target: ${formatUSDC(targetAmount)} USDC`);
    console.log(`   Sources: ${sourceChains.join(", ")}`);
    console.log(`   Merchant: ${merchant}`);

    const tx = await aggregator.initiateInstantAggregation(
      merchant,
      targetAmount,
      CONFIG.CHAIN_EIDS["eth-sepolia"], // refund chain
      chainEids,
      expectedAmounts,
      { value: ethers.parseEther("0.01") } // refund gas deposit
    );

    console.log(`   TX Hash: ${tx.hash}`);
    const receipt = await tx.wait();

    // Extract requestId from event
    const event = receipt.logs.find(
      (log: any) =>
        log.topics[0] ===
        aggregator.interface.getEvent("InstantAggregationInitiated").topicHash
    );

    if (!event) throw new Error("Failed to get requestId from event");

    const requestId = event.topics[1];
    console.log(`✅ Aggregation initiated! Request ID: ${requestId}`);

    return {
      requestId,
      txHash: receipt.hash,
    };
  }

  /**
   * Get PayMe aggregation request status
   */
  async getAggregationStatus(requestId: string): Promise<PaymentRequest> {
    const provider = this.providers.get("base-sepolia")!;
    const aggregator = new ethers.Contract(
      CONFIG.INSTANT_AGGREGATOR,
      INSTANT_AGGREGATOR_ABI,
      provider
    );

    const request = await aggregator.getRequest(requestId);
    const statuses = ["PENDING", "SETTLED", "REFUNDING", "REFUNDED"] as const;

    return {
      requestId: request.requestId,
      merchant: request.merchant,
      targetAmount: request.targetAmount,
      totalLocked: request.totalLocked,
      settledAmount: request.usdcSettledAmount,
      status: statuses[request.status],
      deadline: new Date(Number(request.deadline) * 1000),
      isSettled: request.usdcSettledAmount > 0n,
    };
  }

  // ===========================================================================
  // AEON X-PAYMENT HEADER
  // ===========================================================================

  /**
   * Get payment info from Aeon (Step 1)
   */
  async getAeonPaymentInfo(
    appId: string,
    qrCode: string
  ): Promise<AeonPaymentRequired> {
    if (!this.walletAddress) throw new Error("Wallet not initialized");

    const baseUrl = this.sandbox ? CONFIG.AEON_SANDBOX_URL : CONFIG.AEON_PROD_URL;
    const url = new URL(`${baseUrl}/open/ai/402/payment`);
    url.searchParams.set("appId", appId);
    url.searchParams.set("qrCode", qrCode);
    url.searchParams.set("address", this.walletAddress);

    const response = await fetch(url.toString());
    return (await response.json()) as AeonPaymentRequired;
  }

  /**
   * Create X-PAYMENT header for Aeon
   */
  async createXPaymentHeader(paymentInfo: Aeon402Response): Promise<string> {
    if (!this.walletAddress) throw new Error("Wallet not initialized");

    const now = Math.floor(Date.now() / 1000);
    const chainId = CONFIG.CHAIN_IDS[paymentInfo.network] || 8453;

    const authorization: AeonAuthorization = {
      from: this.walletAddress,
      to: paymentInfo.payTo,
      value: paymentInfo.maxAmountRequired,
      validAfter: now.toString(),
      validBefore: (now + paymentInfo.maxTimeoutSeconds).toString(),
      nonce: generateNonce(),
    };

    // EIP-712 typed data
    const typedData = {
      domain: {
        name: "USD Coin",
        version: "2",
        chainId: chainId,
        verifyingContract: paymentInfo.asset,
      },
      types: AEON_PAYMENT_TYPES,
      primaryType: "TransferWithAuthorization" as const,
      message: {
        from: authorization.from,
        to: authorization.to,
        value: authorization.value,
        validAfter: authorization.validAfter,
        validBefore: authorization.validBefore,
        nonce: authorization.nonce,
      },
    };

    // Sign with CDP SDK
    const { signature } = await this.cdp.signEvmTypedData(
      this.walletAddress,
      typedData
    );

    const payload: AeonXPaymentPayload = {
      x402Version: 1,
      scheme: paymentInfo.scheme,
      network: paymentInfo.network,
      payload: {
        signature: signature as `0x${string}`,
        authorization,
      },
    };

    return encodePayload(payload);
  }

  /**
   * Submit payment to Aeon with X-PAYMENT header
   */
  async submitAeonPayment(
    appId: string,
    qrCode: string,
    xPaymentHeader: string
  ): Promise<any> {
    if (!this.walletAddress) throw new Error("Wallet not initialized");

    const baseUrl = this.sandbox ? CONFIG.AEON_SANDBOX_URL : CONFIG.AEON_PROD_URL;
    const url = new URL(`${baseUrl}/open/ai/402/payment`);
    url.searchParams.set("appId", appId);
    url.searchParams.set("qrCode", qrCode);
    url.searchParams.set("address", this.walletAddress);

    const response = await fetch(url.toString(), {
      headers: { "X-PAYMENT": xPaymentHeader },
    });

    const xPaymentResponse = response.headers.get("X-Payment-Response");
    const body = await response.json();

    return {
      status: response.status,
      body,
      xPaymentResponse: xPaymentResponse ? decodePayload(xPaymentResponse) : null,
    };
  }

  // ===========================================================================
  // UNIFIED PAYMENT FLOW
  // ===========================================================================

  /**
   * Complete payment flow with automatic cross-chain aggregation
   *
   * 1. Get payment info from Aeon (402 response)
   * 2. Check USDC balance on requested chain
   * 3. If insufficient → Initiate PayMe aggregation
   * 4. Poll every 5s until balance is sufficient
   * 5. Create X-PAYMENT header and submit
   */
  async pay(
    appId: string,
    qrCode: string,
    sourceChains: string[] = ["eth-sepolia"]
  ): Promise<any> {
    console.log("\n" + "=".repeat(60));
    console.log("🚀 PayMe + Aeon x402 Unified Payment Flow");
    console.log("=".repeat(60));

    // Step 1: Get payment info from Aeon
    console.log("\n📋 Step 1: Getting payment info from Aeon...");
    const paymentRequired = await this.getAeonPaymentInfo(appId, qrCode);

    if (paymentRequired.code !== "402" || !paymentRequired.accepts?.length) {
      throw new Error(`Unexpected response: ${paymentRequired.msg}`);
    }

    const paymentInfo = paymentRequired.accepts[0];
    const requiredAmount = BigInt(paymentInfo.maxAmountRequired);
    const network = paymentInfo.network;

    console.log(`   Amount Required: ${formatUSDC(requiredAmount)} USDC`);
    console.log(`   Network: ${network}`);
    console.log(`   Pay To: ${paymentInfo.payTo}`);
    console.log(`   Timeout: ${paymentInfo.maxTimeoutSeconds}s`);

    // Step 2: Check current USDC balance
    console.log(`\n💰 Step 2: Checking USDC balance on ${network}...`);
    let { balance, formatted } = await this.getUSDCBalance(network);
    console.log(`   Current Balance: ${formatted} USDC`);
    console.log(`   Required: ${formatUSDC(requiredAmount)} USDC`);

    // Step 3: If insufficient, initiate cross-chain aggregation
    if (balance < requiredAmount) {
      console.log(`\n⚠️  Insufficient balance! Need ${formatUSDC(requiredAmount - balance)} more USDC`);
      console.log(`\n🔄 Step 3: Initiating cross-chain aggregation via PayMe...`);

      if (!this.ethersWallet) {
        throw new Error(
          "Private key required for aggregation. Call initWithPrivateKey() first."
        );
      }

      const amountNeeded = requiredAmount - balance;
      const { requestId, txHash } = await this.initiateAggregation(
        amountNeeded,
        sourceChains
      );

      // Step 4: Poll for balance update
      console.log(`\n⏳ Step 4: Waiting for cross-chain transfer to complete...`);
      console.log(`   Polling every ${CONFIG.BALANCE_CHECK_INTERVAL_MS / 1000}s`);
      console.log(`   Max wait time: ${CONFIG.MAX_WAIT_TIME_MS / 1000}s`);

      const startTime = Date.now();
      let pollCount = 0;

      while (Date.now() - startTime < CONFIG.MAX_WAIT_TIME_MS) {
        pollCount++;
        await sleep(CONFIG.BALANCE_CHECK_INTERVAL_MS);

        const { balance: newBalance, formatted: newFormatted } =
          await this.getUSDCBalance(network);

        const elapsed = Math.floor((Date.now() - startTime) / 1000);
        console.log(
          `   [${elapsed}s] Poll #${pollCount}: Balance = ${newFormatted} USDC`
        );

        if (newBalance >= requiredAmount) {
          console.log(`\n✅ Balance is now sufficient!`);
          balance = newBalance;
          break;
        }

        // Also check aggregation status
        try {
          const aggStatus = await this.getAggregationStatus(requestId);
          console.log(
            `         Aggregation: ${aggStatus.status} | Locked: ${formatUSDC(aggStatus.totalLocked)} USDC`
          );

          if (aggStatus.isSettled) {
            console.log(`   ✅ Settlement confirmed on-chain`);
          }
        } catch {
          // Ignore errors - request might not exist yet
        }
      }

      // Final balance check
      if (balance < requiredAmount) {
        throw new Error(
          `Timeout waiting for balance. Current: ${formatUSDC(balance)}, Required: ${formatUSDC(requiredAmount)}`
        );
      }
    } else {
      console.log(`\n✅ Balance is sufficient! Skipping aggregation.`);
    }

    // Step 5: Create X-PAYMENT header
    console.log(`\n🔐 Step 5: Creating X-PAYMENT header...`);
    const xPaymentHeader = await this.createXPaymentHeader(paymentInfo);
    console.log(`   Header created (${xPaymentHeader.length} chars)`);

    // Step 6: Submit payment to Aeon
    console.log(`\n📤 Step 6: Submitting payment to Aeon...`);
    const result = await this.submitAeonPayment(appId, qrCode, xPaymentHeader);

    if (result.body.code === "0") {
      console.log(`\n` + "=".repeat(60));
      console.log(`🎉 PAYMENT SUCCESSFUL!`);
      console.log("=".repeat(60));
      console.log(`   Order: ${result.body.model?.num}`);
      console.log(`   USD Amount: $${result.body.model?.usdAmount}`);
      console.log(`   Fiat Amount: ${result.body.model?.orderAmount} ${result.body.model?.orderCurrency}`);
      console.log(`   Status: ${result.body.model?.status}`);
    } else {
      console.log(`\n❌ Payment failed: ${result.body.msg}`);
    }

    return result;
  }
}

// =============================================================================
// DEMO / USAGE
// =============================================================================

async function demo() {
  console.log("🚀 PayMe + Aeon x402 Client Demo\n");

  // Initialize client
  const client = new PayMeX402Client(true); // sandbox mode

  // Option 1: CDP wallet (for signing)
  const cdpWallet = await client.initWithCDP("payme-demo");

  // Option 2: Private key (for contract interactions)
  // Uncomment and set your private key:
  // const privateKey = process.env.AGENT_PRIVATE_KEY!;
  // client.initWithPrivateKey(privateKey, "base-sepolia");

  console.log(`\n📍 Wallet: ${client.getWallet()}`);

  // Check balances
  console.log("\n📊 Current Balances:");
  try {
    const baseBal = await client.getUSDCBalance("base-sepolia");
    console.log(`   Base Sepolia: ${baseBal.formatted} USDC`);
  } catch {
    console.log(`   Base Sepolia: Unable to check (RPC may not work in this environment)`);
  }

  // Simulate payment flow
  console.log("\n📝 Example Usage:");
  console.log(`
// Full payment flow with automatic cross-chain aggregation
const result = await client.pay(
  "YOUR_APP_ID",
  "QR_CODE_STRING",
  ["eth-sepolia"]  // source chains for aggregation
);

// Or step by step:

// 1. Get payment info
const paymentInfo = await client.getAeonPaymentInfo(appId, qrCode);

// 2. Check balance
const hasBalance = await client.hasEnoughBalance("base", paymentInfo.accepts[0].maxAmountRequired);

// 3. If needed, aggregate from other chains
if (!hasBalance) {
  await client.initiateAggregation(BigInt(paymentInfo.accepts[0].maxAmountRequired), ["eth-sepolia"]);
  // ... wait for balance ...
}

// 4. Create X-PAYMENT header
const xPayment = await client.createXPaymentHeader(paymentInfo.accepts[0]);

// 5. Submit payment
const result = await client.submitAeonPayment(appId, qrCode, xPayment);
`);

  // Show X-PAYMENT structure
  console.log("\n🔐 X-PAYMENT Header Structure:");
  const mockPaymentInfo: Aeon402Response = {
    maxAmountRequired: "550000",
    payTo: "0x302bb114079532dfa07f2dffae320d04be9d903b" as `0x${string}`,
    asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as `0x${string}`,
    network: "base",
    scheme: "exact",
    maxTimeoutSeconds: 60,
    resource: "https://ai-api.aeon.xyz/open/ai/402/payment",
  };

  const header = await client.createXPaymentHeader(mockPaymentInfo);
  console.log("\nBase64 Header:");
  console.log(header.slice(0, 100) + "...");
  console.log("\nDecoded:");
  console.log(JSON.stringify(decodePayload(header), null, 2));
}

// =============================================================================
// EXPORTS
// =============================================================================

export {
  PayMeX402Client,
  CONFIG,
  Aeon402Response,
  AeonPaymentRequired,
  AeonXPaymentPayload,
  PaymentRequest,
  formatUSDC,
  parseUSDC,
  encodePayload,
  decodePayload,
};

// Run demo
demo().catch(console.error);
