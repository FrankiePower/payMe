/**
 * Complete Blockchain Operations Module for CDP SDK
 * 
 * Features:
 * - ENS name registration
 * - Native & ERC-20 transfers
 * - ERC-20 approvals & allowances
 * - Send & read transactions
 */

import { 
  encodeFunctionData, 
  parseEther, 
  parseUnits, 
  formatUnits,
  createPublicClient,
  http,
  type PublicClient
} from "viem";
import { mainnet, base, baseSepolia, sepolia } from "viem/chains";
import { serializeTransaction } from "viem";
import type { TransactionRequestEIP1559 } from "viem";
import type { CdpOpenApiClientType } from "@coinbase/cdp-sdk";
import {
  ERC20_ABI,
  ENS_ETH_REGISTRAR_CONTROLLER_ABI,
  ENS_RESOLVER_ABI,
  CONTRACT_ADDRESSES,
  type SupportedNetwork,
} from "./abis.js";

// ============================================================================
// TYPES
// ============================================================================

export type Address = `0x${string}`;
export type Hex = `0x${string}`;

export interface TransferNativeOptions {
  /** Sender's address */
  from: Address;
  /** Recipient's address */
  to: Address;
  /** Amount in ETH (e.g., "0.1") */
  amountInEth: string;
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
  /** Optional idempotency key */
  idempotencyKey?: string;
}

export interface TransferERC20Options {
  /** Sender's address */
  from: Address;
  /** Recipient's address */
  to: Address;
  /** Token contract address */
  tokenAddress: Address;
  /** Amount in token's smallest unit */
  amount: bigint;
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
  /** Optional idempotency key */
  idempotencyKey?: string;
}

export interface ApproveERC20Options {
  /** Owner's address */
  from: Address;
  /** Spender's address to approve */
  spender: Address;
  /** Token contract address */
  tokenAddress: Address;
  /** Amount to approve */
  amount: bigint;
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
  /** Optional idempotency key */
  idempotencyKey?: string;
}

export interface CheckAllowanceOptions {
  /** Owner's address */
  owner: Address;
  /** Spender's address */
  spender: Address;
  /** Token contract address */
  tokenAddress: Address;
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
}

export interface RegisterENSOptions {
  /** Owner's address */
  owner: Address;
  /** ENS name without .eth (e.g., "myname") */
  name: string;
  /** Duration in years */
  durationInYears: number;
  /** Network (only ethereum or ethereum-sepolia) */
  network: "ethereum" | "ethereum-sepolia";
  /** Optional idempotency key */
  idempotencyKey?: string;
}

export interface SendTransactionOptions {
  /** Sender's address */
  from: Address;
  /** Transaction request */
  transaction: TransactionRequestEIP1559;
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
  /** Optional idempotency key */
  idempotencyKey?: string;
}

export interface ReadContractOptions {
  /** Contract address */
  contractAddress: Address;
  /** ABI of the function */
  abi: readonly unknown[];
  /** Function name */
  functionName: string;
  /** Function arguments */
  args?: unknown[];
  /** Network to use */
  network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia";
}

export interface TransactionResult {
  transactionHash: Hex;
}

export interface TokenInfo {
  name: string;
  symbol: string;
  decimals: number;
  totalSupply: bigint;
}

// ============================================================================
// CHAIN ID MAPPING
// ============================================================================

const CHAIN_ID_MAP: Record<string, number> = {
  "ethereum": 1,
  "ethereum-sepolia": 11155111,
  "base": 8453,
  "base-sepolia": 84532,
};

const VIEM_CHAIN_MAP = {
  "ethereum": mainnet,
  "ethereum-sepolia": sepolia,
  "base": base,
  "base-sepolia": baseSepolia,
} as const;

// ============================================================================
// MAIN BLOCKCHAIN CLASS
// ============================================================================

export class BlockchainOperations {
  private publicClients: Map<string, PublicClient> = new Map();
  private customRpcUrls?: Record<string, string>;

  constructor(
    private client: CdpOpenApiClientType,
    options?: { rpcUrls?: Record<string, string> }
  ) {
    this.customRpcUrls = options?.rpcUrls;
  }

  /**
   * Get or create a viem public client for reading blockchain data
   */
  private getPublicClient(network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia"): PublicClient {
    if (!this.publicClients.has(network)) {
      const chain = VIEM_CHAIN_MAP[network];
      const rpcUrl = this.customRpcUrls?.[network];

      const client = createPublicClient({
        chain,
        transport: http(rpcUrl),
      });

      this.publicClients.set(network, client);
    }

    return this.publicClients.get(network)!;
  }

  /**
   * Get chain ID for a network
   */
  private getChainId(network: string): number {
    const chainId = CHAIN_ID_MAP[network];
    if (!chainId) {
      throw new Error(`Unsupported network: ${network}`);
    }
    return chainId;
  }

  // ==========================================================================
  // 1. CREATE ENS NAME
  // ==========================================================================

  /**
   * Register an ENS name using the proper commit-reveal pattern
   * 
   * This implements the full two-step ENS registration process:
   * 1. Commit to the name registration
   * 2. Wait 60 seconds (ENS security requirement)
   * 3. Complete the registration
   * 
   * @example
   * ```ts
   * const result = await blockchain.registerENSName({
   *   owner: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   name: "myname",
   *   durationInYears: 1,
   *   network: "ethereum-sepolia"
   * });
   * // This will take ~60 seconds to complete due to ENS security requirements
   * ```
   */
  async registerENSName(options: RegisterENSOptions): Promise<TransactionResult> {
    const { owner, name, durationInYears, network, idempotencyKey } = options;

    // Get contract addresses
    const controllerAddress = CONTRACT_ADDRESSES[network].ensEthRegistrarController;
    const resolverAddress = CONTRACT_ADDRESSES[network].ensPublicResolver;

    console.log(`\n🔍 Starting ENS registration for ${name}.eth...`);

    // Step 1: Check availability
    console.log(`1️⃣  Checking availability...`);
    const isAvailable = await this.checkENSAvailability(name, network);
    
    if (!isAvailable) {
      throw new Error(`ENS name "${name}.eth" is not available for registration`);
    }
    console.log(`   ✅ Name is available`);

    // Step 2: Get registration price
    console.log(`2️⃣  Getting registration price...`);
    const duration = BigInt(durationInYears * 365 * 24 * 60 * 60);
    const rentPrice = await this.readContract({
      contractAddress: controllerAddress as Address,
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "rentPrice",
      args: [name, duration],
      network,
    }) as bigint;

    // Add 10% buffer for price fluctuations
    const value = (rentPrice * 110n) / 100n;
    console.log(`   💰 Price: ${formatUnits(value, 18)} ETH`);

    // Step 3: Generate secret and make commitment
    console.log(`3️⃣  Creating commitment...`);
    const secret = `0x${Array.from({ length: 64 }, () =>
      Math.floor(Math.random() * 16).toString(16)
    ).join("")}` as Hex;

    const commitmentHash = await this.readContract({
      contractAddress: controllerAddress as Address,
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "makeCommitment",
      args: [
        name,
        owner,
        duration,
        secret,
        resolverAddress,
        [],
        false,
        0,
      ],
      network,
    }) as Hex;

    // Step 4: Submit commitment transaction
    console.log(`4️⃣  Submitting commitment transaction...`);
    const commitData = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "commit",
      args: [commitmentHash],
    });

    const commitTx = await this.sendTransaction({
      from: owner,
      transaction: {
        to: controllerAddress as Address,
        data: commitData,
      },
      network,
      idempotencyKey: idempotencyKey ? `${idempotencyKey}-commit` : undefined,
    });

    console.log(`   ✅ Commitment transaction: ${commitTx.transactionHash}`);

    // Step 5: Wait 60 seconds (ENS requirement)
    console.log(`5️⃣  Waiting 60 seconds (ENS security requirement)...`);
    await this.sleep(60000);
    console.log(`   ✅ Wait complete`);

    // Step 6: Complete registration
    console.log(`6️⃣  Completing registration...`);
    const registerData = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "register",
      args: [
        name,
        owner,
        duration,
        secret,
        resolverAddress,
        [],
        false,
        0,
      ],
    });

    const registerTx = await this.sendTransaction({
      from: owner,
      transaction: {
        to: controllerAddress as Address,
        data: registerData,
        value,
      },
      network,
      idempotencyKey: idempotencyKey ? `${idempotencyKey}-register` : undefined,
    });

    console.log(`\n✅ Successfully registered ${name}.eth!`);
    console.log(`   Transaction: ${registerTx.transactionHash}`);

    return registerTx;
  }

  /**
   * Helper method to sleep
   */
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Check if an ENS name is available
   */
  async checkENSAvailability(name: string, network: "ethereum" | "ethereum-sepolia"): Promise<boolean> {
    const controllerAddress = CONTRACT_ADDRESSES[network].ensEthRegistrarController;

    const data = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "available",
      args: [name],
    });

    const result = await this.readContract({
      contractAddress: controllerAddress as Address,
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "available",
      args: [name],
      network,
    });

    return result as boolean;
  }

  // ==========================================================================
  // 2. TRANSFER NATIVE ASSET (ETH)
  // ==========================================================================

  /**
   * Transfer native ETH to another address
   * 
   * @example
   * ```ts
   * const result = await blockchain.transferNative({
   *   from: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   to: "0x1234567890123456789012345678901234567890",
   *   amountInEth: "0.1",
   *   network: "base-sepolia"
   * });
   * ```
   */
  async transferNative(options: TransferNativeOptions): Promise<TransactionResult> {
    const { from, to, amountInEth, network, idempotencyKey } = options;

    const value = parseEther(amountInEth);

    const transaction: TransactionRequestEIP1559 = {
      to,
      value,
    };

    return this.sendTransaction({
      from,
      transaction,
      network,
      idempotencyKey,
    });
  }

  // ==========================================================================
  // 3. TRANSFER ERC-20 TOKEN
  // ==========================================================================

  /**
   * Transfer ERC-20 tokens to another address
   * 
   * @example
   * ```ts
   * // Transfer 100 USDC (6 decimals)
   * const result = await blockchain.transferERC20({
   *   from: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   to: "0x1234567890123456789012345678901234567890",
   *   tokenAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
   *   amount: parseUnits("100", 6),
   *   network: "base"
   * });
   * ```
   */
  async transferERC20(options: TransferERC20Options): Promise<TransactionResult> {
    const { from, to, tokenAddress, amount, network, idempotencyKey } = options;

    const data = encodeFunctionData({
      abi: ERC20_ABI,
      functionName: "transfer",
      args: [to, amount],
    });

    const transaction: TransactionRequestEIP1559 = {
      to: tokenAddress,
      data,
    };

    return this.sendTransaction({
      from,
      transaction,
      network,
      idempotencyKey,
    });
  }

  // ==========================================================================
  // 4. APPROVE ERC-20 TOKEN
  // ==========================================================================

  /**
   * Approve a spender to use your ERC-20 tokens
   * 
   * @example
   * ```ts
   * // Approve Uniswap to spend 1000 USDC
   * const result = await blockchain.approveERC20({
   *   from: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   spender: "0xUniswapRouterAddress",
   *   tokenAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
   *   amount: parseUnits("1000", 6),
   *   network: "base"
   * });
   * ```
   */
  async approveERC20(options: ApproveERC20Options): Promise<TransactionResult> {
    const { from, spender, tokenAddress, amount, network, idempotencyKey } = options;

    const data = encodeFunctionData({
      abi: ERC20_ABI,
      functionName: "approve",
      args: [spender, amount],
    });

    const transaction: TransactionRequestEIP1559 = {
      to: tokenAddress,
      data,
    };

    return this.sendTransaction({
      from,
      transaction,
      network,
      idempotencyKey,
    });
  }

  /**
   * Approve unlimited amount (max uint256)
   * 
   * ⚠️ USE WITH CAUTION: This gives unlimited approval
   */
  async approveERC20Unlimited(
    options: Omit<ApproveERC20Options, "amount">
  ): Promise<TransactionResult> {
    const maxUint256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    
    return this.approveERC20({
      ...options,
      amount: maxUint256,
    });
  }

  // ==========================================================================
  // 5. CHECK ALLOWANCE
  // ==========================================================================

  /**
   * Check how much a spender is allowed to spend
   * 
   * @example
   * ```ts
   * const allowance = await blockchain.checkAllowance({
   *   owner: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   spender: "0xUniswapRouterAddress",
   *   tokenAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
   *   network: "base"
   * });
   * console.log(`Allowance: ${formatUnits(allowance, 6)} USDC`);
   * ```
   */
  async checkAllowance(options: CheckAllowanceOptions): Promise<bigint> {
    const { owner, spender, tokenAddress, network } = options;

    const result = await this.readContract({
      contractAddress: tokenAddress,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [owner, spender],
      network,
    });

    return result as bigint;
  }

  /**
   * Check if allowance is sufficient for a transfer
   */
  async hasEnoughAllowance(
    options: CheckAllowanceOptions & { requiredAmount: bigint }
  ): Promise<boolean> {
    const allowance = await this.checkAllowance(options);
    return allowance >= options.requiredAmount;
  }

  // ==========================================================================
  // 6. SEND TRANSACTION (Generic)
  // ==========================================================================

  /**
   * Send a generic transaction
   * 
   * @example
   * ```ts
   * const result = await blockchain.sendTransaction({
   *   from: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   transaction: {
   *     to: "0x1234567890123456789012345678901234567890",
   *     value: parseEther("0.1"),
   *     data: "0x"
   *   },
   *   network: "base-sepolia"
   * });
   * ```
   */
  async sendTransaction(options: SendTransactionOptions): Promise<TransactionResult> {
    const { from, transaction, network, idempotencyKey } = options;

    try {
      // Get correct chain ID for the network
      const chainId = this.getChainId(network);

      // Serialize the transaction with proper chain ID
      const serializedTx = serializeTransaction({
        ...transaction,
        chainId,
        type: "eip1559",
      });

      const result = await this.client.sendEvmTransaction(
        from,
        {
          transaction: serializedTx,
          network: network as any,
        },
        idempotencyKey
      );

      return {
        transactionHash: result.transactionHash as Hex,
      };
    } catch (error: any) {
      // Enhanced error handling for common CDP API errors
      if (error?.code === "INSUFFICIENT_FUNDS" || error?.message?.includes("insufficient")) {
        throw new Error(
          `Insufficient balance for transaction on ${network}. Please ensure the account has enough funds.`
        );
      }

      if (error?.code === "UNAUTHORIZED" || error?.status === 401) {
        throw new Error(
          "CDP API authentication failed. Please check your API credentials."
        );
      }

      if (error?.code === "RATE_LIMIT_EXCEEDED" || error?.status === 429) {
        throw new Error(
          "CDP API rate limit exceeded. Please wait a moment and try again."
        );
      }

      if (error?.message?.includes("nonce")) {
        throw new Error(
          `Transaction nonce error on ${network}. The account may have pending transactions.`
        );
      }

      // Re-throw with more context
      throw new Error(
        `Failed to send transaction on ${network}: ${
          error instanceof Error ? error.message : "Unknown error"
        }`
      );
    }
  }

  // ==========================================================================
  // 7. READ CONTRACT (Read-only calls)
  // ==========================================================================

  /**
   * Read data from a contract (view/pure functions)
   * 
   * Uses viem's public client for read-only calls.
   * 
   * @example
   * ```ts
   * const balance = await blockchain.readContract({
   *   contractAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
   *   abi: ERC20_ABI,
   *   functionName: "balanceOf",
   *   args: ["0x742d35Cc6634C0532925a3b844Bc454e4438f44e"],
   *   network: "base"
   * });
   * ```
   */
  async readContract(options: ReadContractOptions): Promise<unknown> {
    const { contractAddress, abi, functionName, args = [], network } = options;

    try {
      const publicClient = this.getPublicClient(network);

      const result = await publicClient.readContract({
        address: contractAddress,
        abi: abi as any,
        functionName,
        args,
      });

      return result;
    } catch (error) {
      throw new Error(
        `Failed to read contract ${contractAddress} on ${network}: ${
          error instanceof Error ? error.message : "Unknown error"
        }`
      );
    }
  }

  // ==========================================================================
  // UTILITY METHODS
  // ==========================================================================

  /**
   * Get ERC-20 token information
   */
  async getTokenInfo(tokenAddress: Address, network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia"): Promise<TokenInfo> {
    const [name, symbol, decimals, totalSupply] = await Promise.all([
      this.readContract({
        contractAddress: tokenAddress,
        abi: ERC20_ABI,
        functionName: "name",
        network,
      }),
      this.readContract({
        contractAddress: tokenAddress,
        abi: ERC20_ABI,
        functionName: "symbol",
        network,
      }),
      this.readContract({
        contractAddress: tokenAddress,
        abi: ERC20_ABI,
        functionName: "decimals",
        network,
      }),
      this.readContract({
        contractAddress: tokenAddress,
        abi: ERC20_ABI,
        functionName: "totalSupply",
        network,
      }),
    ]);

    return {
      name: name as string,
      symbol: symbol as string,
      decimals: decimals as number,
      totalSupply: totalSupply as bigint,
    };
  }

  /**
   * Get ERC-20 balance
   */
  async getERC20Balance(
    tokenAddress: Address,
    accountAddress: Address,
    network: "ethereum" | "base" | "ethereum-sepolia" | "base-sepolia"
  ): Promise<bigint> {
    const balance = await this.readContract({
      contractAddress: tokenAddress,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [accountAddress],
      network,
    });

    return balance as bigint;
  }

  /**
   * Format token amount with decimals
   */
  formatTokenAmount(amount: bigint, decimals: number): string {
    return formatUnits(amount, decimals);
  }

  /**
   * Parse token amount from human-readable string
   */
  parseTokenAmount(amount: string, decimals: number): bigint {
    return parseUnits(amount, decimals);
  }
}
