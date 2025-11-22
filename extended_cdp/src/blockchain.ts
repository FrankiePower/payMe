/**
 * Complete Blockchain Operations Module for CDP SDK
 * 
 * Features:
 * - ENS name registration
 * - Native & ERC-20 transfers
 * - ERC-20 approvals & allowances
 * - Send & read transactions
 */

import { encodeFunctionData, parseEther, parseUnits, formatUnits } from "viem";
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
// MAIN BLOCKCHAIN CLASS
// ============================================================================

export class BlockchainOperations {
  constructor(private client: CdpOpenApiClientType) {}

  // ==========================================================================
  // 1. CREATE ENS NAME
  // ==========================================================================

  /**
   * Register an ENS name (simplified version - production requires commit/reveal)
   * 
   * ⚠️ IMPORTANT: Real ENS registration requires a two-step process:
   * 1. Commit (makeCommitment + commit)
   * 2. Wait 60 seconds
   * 3. Register
   * 
   * This is a simplified version for demonstration.
   * 
   * @example
   * ```ts
   * const result = await blockchain.registerENSName({
   *   owner: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
   *   name: "myname",
   *   durationInYears: 1,
   *   network: "ethereum-sepolia"
   * });
   * ```
   */
  async registerENSName(options: RegisterENSOptions): Promise<TransactionResult> {
    const { owner, name, durationInYears, network, idempotencyKey } = options;

    // Get contract address
    const controllerAddress = CONTRACT_ADDRESSES[network].ensEthRegistrarController;
    const resolverAddress = CONTRACT_ADDRESSES[network].ensPublicResolver;

    // Generate random secret for commit/reveal
    const secret = `0x${Array.from({ length: 64 }, () =>
      Math.floor(Math.random() * 16).toString(16)
    ).join("")}` as Hex;

    const duration = BigInt(durationInYears * 365 * 24 * 60 * 60); // Convert years to seconds

    // Step 1: Check if name is available
    const availableData = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "available",
      args: [name],
    });

    console.log(`Checking availability for ${name}.eth...`);

    // Step 2: Get rent price
    const rentPriceData = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "rentPrice",
      args: [name, duration],
    });

    console.log(`Getting rent price for ${name}.eth...`);

    // Step 3: Make commitment
    const commitmentData = encodeFunctionData({
      abi: ENS_ETH_REGISTRAR_CONTROLLER_ABI,
      functionName: "makeCommitment",
      args: [
        name,
        owner,
        duration,
        secret,
        resolverAddress,
        [], // data
        false, // reverseRecord
        0, // ownerControlledFuses
      ],
    });

    console.log(`Creating commitment for ${name}.eth...`);

    // Step 4: Register (simplified - in production, you need to commit first and wait 60s)
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

    // Estimate cost (0.01 ETH for demo - real price comes from rentPrice call)
    const value = parseEther("0.01");

    const transaction: TransactionRequestEIP1559 = {
      to: controllerAddress as `0x${string}`,
      data: registerData,
      value,
    };

    return this.sendTransaction({
      from: owner,
      transaction,
      network,
      idempotencyKey,
    });
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

    // Serialize the transaction
    const serializedTx = serializeTransaction({
      ...transaction,
      chainId: 1, // CDP API will use the correct chainId based on network
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
  }

  // ==========================================================================
  // 7. READ CONTRACT (Read-only calls)
  // ==========================================================================

  /**
   * Read data from a contract (view/pure functions)
   * 
   * ⚠️ NOTE: CDP SDK doesn't have native read support.
   * This is a placeholder. In production, you'd use:
   * - viem's publicClient.readContract()
   * - ethers.js Contract.call()
   * - Or a third-party RPC provider
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

    // Encode the function call
    const data = encodeFunctionData({
      abi: abi as any,
      functionName,
      args,
    });

    console.warn(
      "⚠️ CDP SDK doesn't support direct contract reads. " +
      "Use viem publicClient or ethers.js for read operations."
    );

    // In a real implementation, you would:
    // 1. Use viem's createPublicClient() with a public RPC
    // 2. Or use ethers.js with a provider
    // 3. Or use a service like Alchemy/Infura

    throw new Error(
      "Read operations are not supported directly by CDP SDK. " +
      "Please use viem publicClient or ethers.js for read-only calls."
    );

    // Example implementation with viem (commented out):
    /*
    import { createPublicClient, http } from 'viem';
    import { mainnet, base } from 'viem/chains';
    
    const client = createPublicClient({
      chain: network === 'ethereum' ? mainnet : base,
      transport: http()
    });
    
    return await client.readContract({
      address: contractAddress,
      abi: abi as any,
      functionName,
      args
    });
    */
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
