/**
 * Aeon x402 Payment Header Generator
 *
 * Creates X-PAYMENT headers specifically for Aeon's x402 QR Code Payment API
 * https://aeon-xyz.readme.io/docs/x402-qr-code-payment
 *
 * Usage:
 *   npm install @coinbase/cdp-sdk
 *   npx ts-node aeon-x402-client.ts
 */

import { CdpClient } from "@coinbase/cdp-sdk";
import crypto from "crypto";

// =============================================================================
// TYPES - Based on Aeon's API
// =============================================================================

/**
 * The 402 response from Aeon's API (inside "accepts" array)
 */
interface Aeon402Response {
  maxAmountRequired: string;      // e.g., "550000" (atomic units)
  payTo: `0x${string}`;           // Recipient address
  asset: `0x${string}`;           // Token contract (USDC)
  network: string;                // "base"
  scheme: string;                 // "exact"
  maxTimeoutSeconds: number;      // e.g., 60
  resource: string;               // API endpoint
  description?: string;
  extra?: {
    orderNo: string;
    name: string;
    version: string;
  };
}

/**
 * Full 402 response structure from Aeon
 */
interface AeonPaymentRequired {
  code: string;
  msg: string;
  traceId: string;
  x402Version: string;
  error: string;
  accepts: Aeon402Response[];
}

/**
 * Authorization structure for X-PAYMENT payload
 */
interface AeonAuthorization {
  from: `0x${string}`;      // Payer wallet address
  to: `0x${string}`;        // Recipient (payTo from 402)
  value: string;            // Amount in atomic units
  validAfter: string;       // Unix timestamp (start)
  validBefore: string;      // Unix timestamp (expiration)
  nonce: `0x${string}`;     // Unique 32-byte nonce
}

/**
 * X-PAYMENT header payload structure for Aeon
 */
interface AeonXPaymentPayload {
  x402Version: number;
  scheme: string;
  network: string;
  payload: {
    signature: `0x${string}`;
    authorization: AeonAuthorization;
  };
}

// =============================================================================
// CONSTANTS
// =============================================================================

const AEON_SANDBOX_URL = "https://ai-api-sbx.aeon.xyz";
const AEON_PROD_URL = "https://ai-api.aeon.xyz";

// USDC on Base (6 decimals)
const USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// Chain IDs
const CHAIN_IDS: Record<string, number> = {
  "base": 8453,
  "base-mainnet": 8453,
  "ethereum": 1,
};

// =============================================================================
// EIP-712 TYPES FOR AEON
// =============================================================================

/**
 * EIP-712 types for Aeon's transfer authorization
 * This follows EIP-3009 (transferWithAuthorization) pattern
 */
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

/**
 * Generate a random 32-byte nonce
 */
function generateNonce(): `0x${string}` {
  const bytes = crypto.randomBytes(32);
  return `0x${bytes.toString("hex")}` as `0x${string}`;
}

/**
 * Encode payload to base64 for X-PAYMENT header
 */
function encodePayload(payload: AeonXPaymentPayload): string {
  return Buffer.from(JSON.stringify(payload)).toString("base64");
}

/**
 * Decode base64 X-PAYMENT header (for debugging)
 */
function decodePayload(base64: string): AeonXPaymentPayload {
  return JSON.parse(Buffer.from(base64, "base64").toString("utf-8"));
}

// =============================================================================
// MAIN CLIENT CLASS
// =============================================================================

class AeonX402Client {
  private cdp: typeof CdpClient;
  private walletAddress: `0x${string}` | null = null;
  private baseUrl: string;

  constructor(sandbox: boolean = true) {
    this.cdp = CdpClient;
    this.baseUrl = sandbox ? AEON_SANDBOX_URL : AEON_PROD_URL;
  }

  /**
   * Initialize with a new or existing wallet
   */
  async init(accountName: string = "aeon-x402-wallet"): Promise<`0x${string}`> {
    const account = await this.cdp.evm.createAccount({ name: accountName });
    this.walletAddress = account.address as `0x${string}`;
    return this.walletAddress;
  }

  /**
   * Set an existing wallet address
   */
  setWallet(address: `0x${string}`): void {
    this.walletAddress = address;
  }

  /**
   * Get the wallet address
   */
  getWallet(): `0x${string}` | null {
    return this.walletAddress;
  }

  /**
   * Create the X-PAYMENT header for Aeon's API
   */
  async createXPaymentHeader(
    paymentInfo: Aeon402Response,
    amount?: string // Optional: pay different amount (must be <= maxAmountRequired)
  ): Promise<string> {
    if (!this.walletAddress) {
      throw new Error("Wallet not initialized. Call init() or setWallet() first.");
    }

    const paymentAmount = amount || paymentInfo.maxAmountRequired;
    const now = Math.floor(Date.now() / 1000);
    const validAfter = now;
    const validBefore = now + paymentInfo.maxTimeoutSeconds;
    const nonce = generateNonce();
    const chainId = CHAIN_IDS[paymentInfo.network] || 8453;

    // Create the authorization object
    const authorization: AeonAuthorization = {
      from: this.walletAddress,
      to: paymentInfo.payTo,
      value: paymentAmount,
      validAfter: validAfter.toString(),
      validBefore: validBefore.toString(),
      nonce: nonce,
    };

    // Create EIP-712 typed data for signing
    // This follows EIP-3009 pattern for USDC transferWithAuthorization
    const typedData = {
      domain: {
        name: "USD Coin",  // USDC token name
        version: "2",      // USDC version
        chainId: chainId,
        verifyingContract: paymentInfo.asset, // USDC contract
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
    const { signature } = await this.cdp.signEvmTypedData(this.walletAddress, typedData);

    // Build the X-PAYMENT payload
    const payload: AeonXPaymentPayload = {
      x402Version: 1,
      scheme: paymentInfo.scheme,
      network: paymentInfo.network,
      payload: {
        signature: signature as `0x${string}`,
        authorization: authorization,
      },
    };

    return encodePayload(payload);
  }

  /**
   * Step 1: Get payment information from Aeon
   */
  async getPaymentInfo(
    appId: string,
    qrCode: string
  ): Promise<AeonPaymentRequired> {
    if (!this.walletAddress) {
      throw new Error("Wallet not initialized. Call init() or setWallet() first.");
    }

    const url = new URL(`${this.baseUrl}/open/ai/402/payment`);
    url.searchParams.set("appId", appId);
    url.searchParams.set("qrCode", qrCode);
    url.searchParams.set("address", this.walletAddress);

    const response = await fetch(url.toString());
    const data = await response.json();

    return data as AeonPaymentRequired;
  }

  /**
   * Step 2: Submit payment with X-PAYMENT header
   */
  async submitPayment(
    appId: string,
    qrCode: string,
    xPaymentHeader: string
  ): Promise<any> {
    if (!this.walletAddress) {
      throw new Error("Wallet not initialized. Call init() or setWallet() first.");
    }

    const url = new URL(`${this.baseUrl}/open/ai/402/payment`);
    url.searchParams.set("appId", appId);
    url.searchParams.set("qrCode", qrCode);
    url.searchParams.set("address", this.walletAddress);

    const response = await fetch(url.toString(), {
      headers: {
        "X-PAYMENT": xPaymentHeader,
      },
    });

    const xPaymentResponse = response.headers.get("X-Payment-Response");
    const body = await response.json();

    return {
      status: response.status,
      body,
      xPaymentResponse: xPaymentResponse
        ? decodePayload(xPaymentResponse)
        : null,
    };
  }

  /**
   * Complete flow: Get payment info → Create header → Submit payment
   */
  async pay(appId: string, qrCode: string): Promise<any> {
    console.log("Step 1: Getting payment information...");
    const paymentRequired = await this.getPaymentInfo(appId, qrCode);

    if (paymentRequired.code !== "402" || !paymentRequired.accepts?.length) {
      throw new Error(`Unexpected response: ${paymentRequired.msg}`);
    }

    const paymentInfo = paymentRequired.accepts[0];
    console.log(`  Amount: ${paymentInfo.maxAmountRequired} (atomic units)`);
    console.log(`  Pay To: ${paymentInfo.payTo}`);
    console.log(`  Network: ${paymentInfo.network}`);
    console.log(`  Timeout: ${paymentInfo.maxTimeoutSeconds}s`);

    console.log("\nStep 2: Creating X-PAYMENT header...");
    const xPaymentHeader = await this.createXPaymentHeader(paymentInfo);
    console.log(`  Header created (${xPaymentHeader.length} chars)`);

    console.log("\nStep 3: Submitting payment...");
    const result = await this.submitPayment(appId, qrCode, xPaymentHeader);

    if (result.body.code === "0") {
      console.log("✅ Payment successful!");
      console.log(`  Order: ${result.body.model?.num}`);
      console.log(`  USD Amount: $${result.body.model?.usdAmount}`);
      console.log(`  Status: ${result.body.model?.status}`);
    } else {
      console.log("❌ Payment failed:", result.body.msg);
    }

    return result;
  }
}

// =============================================================================
// STANDALONE FUNCTIONS
// =============================================================================

/**
 * Quick function to create X-PAYMENT header without class instantiation
 */
async function createAeonXPaymentHeader(
  walletAddress: `0x${string}`,
  paymentInfo: Aeon402Response
): Promise<string> {
  const client = new AeonX402Client();
  client.setWallet(walletAddress);
  return client.createXPaymentHeader(paymentInfo);
}

// =============================================================================
// DEMO
// =============================================================================

async function demo() {
  console.log("🚀 Aeon x402 Payment Header Generator\n");

  const client = new AeonX402Client(true); // true = sandbox
  const walletAddress = await client.init("aeon-demo-wallet");

  console.log(`📍 Wallet Address: ${walletAddress}\n`);

  // Simulate 402 response from Aeon
  const mock402Response: Aeon402Response = {
    maxAmountRequired: "550000", // 0.55 USDC
    payTo: "0x302bb114079532dfa07f2dffae320d04be9d903b" as `0x${string}`,
    asset: USDC_BASE as `0x${string}`,
    network: "base",
    scheme: "exact",
    maxTimeoutSeconds: 60,
    resource: "https://ai-api.aeon.xyz/open/ai/402/payment",
    extra: {
      orderNo: "400017533497667631733",
      name: "USD Coin",
      version: "2",
    },
  };

  console.log("📝 402 Response (from Aeon):");
  console.log(JSON.stringify(mock402Response, null, 2));

  // Create X-PAYMENT header
  console.log("\n🔐 Creating X-PAYMENT header...");
  const xPaymentHeader = await client.createXPaymentHeader(mock402Response);

  console.log("\n=== X-PAYMENT Header (base64) ===");
  console.log(xPaymentHeader);

  // Decode to show structure
  const decoded = decodePayload(xPaymentHeader);
  console.log("\n=== Decoded Structure ===");
  console.log(JSON.stringify(decoded, null, 2));

  // Show usage
  console.log("\n💻 Usage with Aeon API:");
  console.log(`
curl --location '${AEON_SANDBOX_URL}/open/ai/402/payment?appId=YOUR_APP_ID&qrCode=YOUR_QR&address=${walletAddress}' \\
  --header 'X-PAYMENT: ${xPaymentHeader.slice(0, 50)}...'
`);

  // Full flow example
  console.log("\n📡 Full Flow Example (code):");
  console.log(`
const client = new AeonX402Client(true); // sandbox
await client.init();

// Complete payment flow
const result = await client.pay("YOUR_APP_ID", "QR_CODE_STRING");
console.log(result);
`);
}

// =============================================================================
// EXPORTS
// =============================================================================

export {
  AeonX402Client,
  createAeonXPaymentHeader,
  encodePayload,
  decodePayload,
  generateNonce,
  Aeon402Response,
  AeonPaymentRequired,
  AeonXPaymentPayload,
  AeonAuthorization,
  AEON_PAYMENT_TYPES,
  AEON_SANDBOX_URL,
  AEON_PROD_URL,
};

// Run demo
demo().catch(console.error);
