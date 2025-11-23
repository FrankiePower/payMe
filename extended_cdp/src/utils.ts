import { parseUnits, formatUnits } from "viem";

/**
 * Common token addresses for different networks
 */
export const TOKEN_ADDRESSES = {
  base: {
    USDC: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    WETH: "0x4200000000000000000000000000000000000006",
  },
  "base-sepolia": {
    USDC: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    WETH: "0x4200000000000000000000000000000000000006",
  },
  ethereum: {
    USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  },
  "ethereum-sepolia": {
    USDC: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    WETH: "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
  },
} as const;

/**
 * Format amount with proper decimals
 */
export function formatAmount(amount: bigint, decimals: number, symbol?: string): string {
  const formatted = formatUnits(amount, decimals);
  return symbol ? `${formatted} ${symbol}` : formatted;
}

/**
 * Parse amount from human-readable string
 */
export function parseAmount(amount: string, decimals: number): bigint {
  return parseUnits(amount, decimals);
}

/**
 * Sleep for specified milliseconds
 */
export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Retry a function with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  initialDelay = 1000
): Promise<T> {
  let lastError: Error;
  
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      const delay = initialDelay * Math.pow(2, i);
      console.log(`Retry ${i + 1}/${maxRetries} after ${delay}ms...`);
      await sleep(delay);
    }
  }
  
  throw lastError!;
}
