/**
 * Cross-Chain Resource Execution (CRE) for x402 Payments
 * 
 * This module enables autonomous agents to:
 * 1. Intercept x402 payment requests
 * 2. Check if assets exist on the target chain
 * 3. Bridge assets from other chains if needed (LayerZero/CCIP)
 * 4. Complete the x402 payment after bridging
 * 
 * Based on: https://docs.chain.link/ccip
 */

import { encodeFunctionData, parseUnits, formatUnits, type Address, type Hex } from "viem";
import type { CdpOpenApiClientType } from "@coinbase/cdp-sdk";
import { BlockchainOperations } from "./blockchain.js";
import { ERC20_ABI } from "./abis.js";

// ============================================================================
// TYPES
// ============================================================================

export type SupportedChain = 
  | "ethereum" 
  | "base" 
  | "arbitrum" 
  | "optimism" 
  | "polygon"
  | "ethereum-sepolia" 
  | "base-sepolia";

export interface X402PaymentRequest {
  /** Amount required */
  maxAmountRequired: string;
  /** API endpoint requesting payment */
  resource: string;
  /** Payment recipient address */
  payTo: Address;
  /** Token contract address */
  asset: Address;
  /** Network where payment is required */
  network: SupportedChain;
  /** Optional description */
  description?: string;
}

export interface ChainBalance {
  chain: SupportedChain;
  balance: bigint;
  tokenAddress: Address;
  decimals: number;
}

export interface BridgeRoute {
  fromChain: SupportedChain;
  toChain: SupportedChain;
  amount: bigint;
  estimatedTime: number; // seconds
  estimatedFee: bigint;
  bridgeProtocol: "layerzero" | "ccip";
}

export interface CREConfig {
  /** Wallet address */
  walletAddress: Address;
  /** Supported chains to check */
  supportedChains: SupportedChain[];
  /** Maximum wait time for bridge (seconds) */
  maxBridgeWaitTime: number;
  /** Polling interval (milliseconds) */
  pollInterval: number;
}

// ============================================================================
// LAYERZERO CONTRACT ADDRESSES
// ============================================================================

export const LAYERZERO_ENDPOINTS = {
  ethereum: "0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675",
  "ethereum-sepolia": "0xae92d5aD7583AD66E49A0c67BAd18F6ba52dDDc1",
  base: "0xb6319cC6c8c27A8F5dAF0dD3DF91EA35C4720dd7",
  "base-sepolia": "0x6EDCE65403992e310A62460808c4b910D972f10f",
  arbitrum: "0x3c2269811836af69497E5F486A85D7316753cf62",
  optimism: "0x3c2269811836af69497E5F486A85D7316753cf62",
  polygon: "0x3c2269811836af69497E5F486A85D7316753cf62",
} as const;

// Chainlink CCIP Router addresses
export const CCIP_ROUTERS = {
  ethereum: "0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D",
  "ethereum-sepolia": "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59",
  base: "0x881e3A65B4d4a04dD529061dd0071cf975F58bCD",
  "base-sepolia": "0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93",
  arbitrum: "0x141fa059441E0ca23ce184B6A78bafD2A517DdE8",
  optimism: "0x3206695CaE29952f4b0c22a169725a865bc8Ce0f",
  polygon: "0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe",
} as const;

// ============================================================================
// MAIN CRE CLASS
// ============================================================================

export class CrossChainResourceExecution {
  private blockchain: BlockchainOperations;
  private config: CREConfig;

  constructor(
    private client: CdpOpenApiClientType,
    config: Partial<CREConfig> = {}
  ) {
    this.blockchain = new BlockchainOperations(client);
    
    // Default config
    this.config = {
      walletAddress: config.walletAddress || "0x0000000000000000000000000000000000000000" as Address,
      supportedChains: config.supportedChains || [
        "ethereum",
        "base",
        "arbitrum",
        "optimism",
        "ethereum-sepolia",
        "base-sepolia",
      ],
      maxBridgeWaitTime: config.maxBridgeWaitTime || 180, // 3 minutes
      pollInterval: config.pollInterval || 10000, // 10 seconds
    };
  }

  // ==========================================================================
  // 1. INTERCEPT X402 PAYMENT REQUEST
  // ==========================================================================

  /**
   * Process x402 payment request with automatic cross-chain resource execution
   * 
   * @example
   * ```ts
   * const cre = new CrossChainResourceExecution(cdpClient, {
   *   walletAddress: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e"
   * });
   * 
   * // Intercept 402 response from API
   * const paymentRequest = {
   *   maxAmountRequired: "10",
   *   resource: "/api/premium-data",
   *   payTo: "0xAPI_PROVIDER_ADDRESS",
   *   asset: "0xUSDC_ADDRESS",
   *   network: "base"
   * };
   * 
   * const result = await cre.executePayment(paymentRequest);
   * ```
   */
  async executePayment(
    paymentRequest: X402PaymentRequest
  ): Promise<{ success: boolean; transactionHash?: Hex; error?: string }> {
    console.log(`\n🔍 Processing x402 payment request...`);
    console.log(`   Network: ${paymentRequest.network}`);
    console.log(`   Amount: ${paymentRequest.maxAmountRequired}`);
    console.log(`   Token: ${paymentRequest.asset}`);

    try {
      // Step 1: Check balance on target chain
      const targetBalance = await this.checkBalance(
        paymentRequest.asset,
        paymentRequest.network
      );

      const requiredAmount = parseUnits(
        paymentRequest.maxAmountRequired,
        targetBalance.decimals
      );

      console.log(`\n💰 Balance Check:`);
      console.log(`   Required: ${paymentRequest.maxAmountRequired}`);
      console.log(`   Available on ${paymentRequest.network}: ${formatUnits(targetBalance.balance, targetBalance.decimals)}`);

      // Step 2: If sufficient balance, proceed with payment
      if (targetBalance.balance >= requiredAmount) {
        console.log(`✅ Sufficient balance on target chain, proceeding with payment...`);
        return await this.sendPayment(paymentRequest, requiredAmount);
      }

      // Step 3: Insufficient balance - check other chains
      console.log(`\n❌ Insufficient balance on target chain`);
      console.log(`🔎 Scanning other chains for assets...`);

      const allBalances = await this.scanAllChains(paymentRequest.asset);
      
      // Filter out target chain and chains with insufficient balance
      const viableChains = allBalances.filter(
        (b) => b.chain !== paymentRequest.network && b.balance >= requiredAmount
      );

      if (viableChains.length === 0) {
        return {
          success: false,
          error: `Insufficient balance across all chains. Required: ${paymentRequest.maxAmountRequired}`,
        };
      }

      // Step 4: Bridge assets from the chain with highest balance
      const sourceChain = viableChains.sort((a, b) => 
        Number(b.balance - a.balance)
      )[0];

      console.log(`\n🌉 Bridging assets:`);
      console.log(`   From: ${sourceChain.chain} (Balance: ${formatUnits(sourceChain.balance, sourceChain.decimals)})`);
      console.log(`   To: ${paymentRequest.network}`);
      console.log(`   Amount: ${paymentRequest.maxAmountRequired}`);

      const bridgeResult = await this.bridgeAssets({
        fromChain: sourceChain.chain,
        toChain: paymentRequest.network,
        tokenAddress: paymentRequest.asset,
        amount: requiredAmount,
      });

      if (!bridgeResult.success) {
        return {
          success: false,
          error: `Bridge failed: ${bridgeResult.error}`,
        };
      }

      // Step 5: Wait and verify balance after bridge
      console.log(`\n⏳ Waiting for bridge confirmation...`);
      const verified = await this.waitForBridgeCompletion(
        paymentRequest.asset,
        paymentRequest.network,
        requiredAmount
      );

      if (!verified) {
        return {
          success: false,
          error: `Bridge verification timeout after ${this.config.maxBridgeWaitTime}s`,
        };
      }

      console.log(`✅ Bridge completed successfully!`);

      // Step 6: Retry payment with bridged assets
      console.log(`\n💳 Retrying payment with bridged assets...`);
      return await this.sendPayment(paymentRequest, requiredAmount);

    } catch (error) {
      console.error(`❌ Payment execution failed:`, error);
      return {
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      };
    }
  }

  // ==========================================================================
  // 2. CHECK BALANCE ON SPECIFIC CHAIN
  // ==========================================================================

  private async checkBalance(
    tokenAddress: Address,
    chain: SupportedChain
  ): Promise<ChainBalance> {
    // Get token decimals
    const decimals = await this.getTokenDecimals(tokenAddress, chain);

    // Get balance
    const balance = await this.blockchain.getERC20Balance(
      tokenAddress,
      this.config.walletAddress,
      chain as any
    );

    return {
      chain,
      balance,
      tokenAddress,
      decimals,
    };
  }

  // ==========================================================================
  // 3. SCAN ALL CHAINS FOR BALANCES
  // ==========================================================================

  private async scanAllChains(tokenAddress: Address): Promise<ChainBalance[]> {
    const balancePromises = this.config.supportedChains.map((chain) =>
      this.checkBalance(tokenAddress, chain).catch((error) => {
        console.warn(`   ⚠️  Failed to check ${chain}: ${error.message}`);
        return {
          chain,
          balance: 0n,
          tokenAddress,
          decimals: 18,
        };
      })
    );

    const balances = await Promise.all(balancePromises);

    console.log(`\n📊 Multi-Chain Balance Summary:`);
    for (const balance of balances) {
      if (balance.balance > 0n) {
        console.log(`   ${balance.chain}: ${formatUnits(balance.balance, balance.decimals)}`);
      }
    }

    return balances.filter((b) => b.balance > 0n);
  }

  // ==========================================================================
  // 4. BRIDGE ASSETS (LayerZero)
  // ==========================================================================

  private async bridgeAssets(options: {
    fromChain: SupportedChain;
    toChain: SupportedChain;
    tokenAddress: Address;
    amount: bigint;
  }): Promise<{ success: boolean; transactionHash?: Hex; error?: string }> {
    const { fromChain, toChain, tokenAddress, amount } = options;

    try {
      // Get LayerZero endpoint address
      const lzEndpoint = LAYERZERO_ENDPOINTS[fromChain];
      
      if (!lzEndpoint) {
        return {
          success: false,
          error: `LayerZero not supported on ${fromChain}`,
        };
      }

      // Get destination chain ID (LayerZero chain IDs)
      const destChainId = this.getLayerZeroChainId(toChain);

      // Step 1: Approve LayerZero to spend tokens
      console.log(`   1️⃣  Approving LayerZero contract...`);
      await this.blockchain.approveERC20({
        from: this.config.walletAddress,
        spender: lzEndpoint as Address,
        tokenAddress,
        amount,
        network: fromChain as any,
      });

      // Step 2: Encode bridge transaction
      // This is a simplified version - real LayerZero integration requires:
      // - OFT (Omnichain Fungible Token) contract interaction
      // - Adapter parameters for gas settings
      // - Proper message encoding
      
      const bridgeData = encodeFunctionData({
        abi: LAYERZERO_BRIDGE_ABI,
        functionName: "sendFrom",
        args: [
          this.config.walletAddress, // from
          destChainId, // destination chain
          this.config.walletAddress, // to (on destination)
          amount, // amount
          this.config.walletAddress, // refund address
          "0x0000000000000000000000000000000000000000" as Address, // zro payment address
          "0x", // adapter params
        ],
      });

      // Step 3: Send bridge transaction
      console.log(`   2️⃣  Sending bridge transaction...`);
      const result = await this.blockchain.sendTransaction({
        from: this.config.walletAddress,
        transaction: {
          to: lzEndpoint as Address,
          data: bridgeData,
        },
        network: fromChain as any,
      });

      console.log(`   ✅ Bridge initiated: ${result.transactionHash}`);

      return {
        success: true,
        transactionHash: result.transactionHash,
      };

    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : "Bridge failed",
      };
    }
  }

  // ==========================================================================
  // 5. WAIT FOR BRIDGE COMPLETION
  // ==========================================================================

  private async waitForBridgeCompletion(
    tokenAddress: Address,
    targetChain: SupportedChain,
    requiredAmount: bigint
  ): Promise<boolean> {
    const startTime = Date.now();
    const maxWaitMs = this.config.maxBridgeWaitTime * 1000;

    let attempts = 0;

    while (Date.now() - startTime < maxWaitMs) {
      attempts++;
      
      console.log(`   🔄 Verification attempt ${attempts}...`);

      try {
        const balance = await this.checkBalance(tokenAddress, targetChain);

        if (balance.balance >= requiredAmount) {
          console.log(`   ✅ Verified! New balance: ${formatUnits(balance.balance, balance.decimals)}`);
          return true;
        }

        console.log(`   ⏳ Not yet... Current balance: ${formatUnits(balance.balance, balance.decimals)}`);
      } catch (error) {
        console.warn(`   ⚠️  Verification error: ${error}`);
      }

      // Wait before next poll
      await this.sleep(this.config.pollInterval);
    }

    return false;
  }

  // ==========================================================================
  // 6. SEND PAYMENT
  // ==========================================================================

  private async sendPayment(
    paymentRequest: X402PaymentRequest,
    amount: bigint
  ): Promise<{ success: boolean; transactionHash?: Hex; error?: string }> {
    try {
      const result = await this.blockchain.transferERC20({
        from: this.config.walletAddress,
        to: paymentRequest.payTo,
        tokenAddress: paymentRequest.asset,
        amount,
        network: paymentRequest.network as any,
      });

      console.log(`✅ Payment successful: ${result.transactionHash}`);

      return {
        success: true,
        transactionHash: result.transactionHash,
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : "Payment failed",
      };
    }
  }

  // ==========================================================================
  // UTILITY METHODS
  // ==========================================================================

  private async getTokenDecimals(
    tokenAddress: Address,
    chain: SupportedChain
  ): Promise<number> {
    // In production, cache this to avoid repeated calls
    try {
      const info = await this.blockchain.getTokenInfo(
        tokenAddress,
        chain as any
      );
      return info.decimals;
    } catch {
      // Default to 18 if fails
      return 18;
    }
  }

  private getLayerZeroChainId(chain: SupportedChain): number {
    const chainIds: Record<SupportedChain, number> = {
      ethereum: 101,
      "ethereum-sepolia": 10161,
      base: 184,
      "base-sepolia": 10160,
      arbitrum: 110,
      optimism: 111,
      polygon: 109,
    };
    return chainIds[chain] || 0;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * Update configuration
   */
  updateConfig(config: Partial<CREConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * Get current configuration
   */
  getConfig(): CREConfig {
    return { ...this.config };
  }
}

// ============================================================================
// LAYERZERO BRIDGE ABI (Simplified)
// ============================================================================

const LAYERZERO_BRIDGE_ABI = [
  {
    inputs: [
      { name: "_from", type: "address" },
      { name: "_dstChainId", type: "uint16" },
      { name: "_toAddress", type: "bytes" },
      { name: "_amount", type: "uint256" },
      { name: "_refundAddress", type: "address" },
      { name: "_zroPaymentAddress", type: "address" },
      { name: "_adapterParams", type: "bytes" },
    ],
    name: "sendFrom",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "_dstChainId", type: "uint16" },
      { name: "_toAddress", type: "bytes" },
      { name: "_amount", type: "uint256" },
      { name: "_useZro", type: "bool" },
      { name: "_adapterParams", type: "bytes" },
    ],
    name: "estimateSendFee",
    outputs: [
      { name: "nativeFee", type: "uint256" },
      { name: "zroFee", type: "uint256" },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;
