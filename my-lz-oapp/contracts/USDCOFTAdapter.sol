// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";

/**
 * @title USDCOFTAdapter
 * @notice Adapts existing USDC tokens to LayerZero OFT functionality for cross-chain transfers
 * @dev This adapter wraps native USDC on each chain for cross-chain compatibility
 *
 * CRITICAL WARNINGS from LayerZero:
 * - ONLY 1 adapter should exist per token across ALL chains
 * - This adapter assumes LOSSLESS transfers (no fee-on-transfer tokens)
 * - USDC has 6 decimals, which matches LayerZero's shared decimals (perfect fit!)
 *
 * Deployment Strategy:
 * - Deploy ONE adapter on each chain with native USDC
 * - Ethereum: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
 * - Arbitrum: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
 * - Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 * - Optimism: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85
 * - Polygon: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
 *
 * How it works:
 * - Source chain: Lock USDC in adapter contract
 * - Destination chain: Unlock USDC from adapter contract
 * - Total supply stays constant (lock/unlock, not burn/mint)
 */
contract USDCOFTAdapter is OFTAdapter {
    /**
     * @notice Constructor
     * @param _usdc Address of native USDC token on this chain
     * @param _lzEndpoint LayerZero endpoint address for this chain
     * @param _delegate Address that can configure LayerZero settings (usually deployer)
     */
    constructor(
        address _usdc,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_usdc, _lzEndpoint, _delegate) Ownable(_delegate) {
        require(_usdc != address(0), "USDCOFTAdapter: Invalid USDC address");
    }
}
