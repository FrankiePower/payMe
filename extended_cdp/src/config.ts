/**
 * Configuration utilities for blockchain operations
 */

import * as dotenv from "dotenv";

// Load environment variables
dotenv.config();

/**
 * Validate required environment variables
 */
export function validateEnvironment(): void {
  const required = ["CDP_API_KEY_ID", "CDP_API_KEY_SECRET"];
  const missing = required.filter((key) => !process.env[key]);

  if (missing.length > 0) {
    throw new Error(
      `Missing required environment variables: ${missing.join(", ")}\n` +
      "Please ensure your .env file is properly configured."
    );
  }
}

/**
 * Get CDP API credentials from environment
 */
export function getCdpCredentials() {
  validateEnvironment();

  return {
    apiKeyId: process.env.CDP_API_KEY_ID!,
    apiKeySecret: process.env.CDP_API_KEY_SECRET!,
  };
}

/**
 * Get custom RPC URLs from environment (optional)
 */
export function getCustomRpcUrls() {
  const rpcUrls: Record<string, string> = {};

  if (process.env.RPC_URL_ETHEREUM) {
    rpcUrls.ethereum = process.env.RPC_URL_ETHEREUM;
  }
  if (process.env.RPC_URL_BASE) {
    rpcUrls.base = process.env.RPC_URL_BASE;
  }
  if (process.env.RPC_URL_ETHEREUM_SEPOLIA) {
    rpcUrls["ethereum-sepolia"] = process.env.RPC_URL_ETHEREUM_SEPOLIA;
  }
  if (process.env.RPC_URL_BASE_SEPOLIA) {
    rpcUrls["base-sepolia"] = process.env.RPC_URL_BASE_SEPOLIA;
  }

  return Object.keys(rpcUrls).length > 0 ? rpcUrls : undefined;
}

/**
 * Get wallet secret from environment (optional)
 */
export function getWalletSecret(): string | undefined {
  return process.env.CDP_WALLET_SECRET;
}

