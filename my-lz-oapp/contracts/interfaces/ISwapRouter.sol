// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ISwapRouter
 * @notice Minimal interface for Uniswap V3 SwapRouter
 * @dev Used for swapping non-USDC tokens to USDC on-chain
 *
 * Deployed addresses (Mainnet & Testnets):
 * - Ethereum: 0xE592427A0AEce92De3Edee1F18E0157C05861564
 * - Arbitrum: 0xE592427A0AEce92De3Edee1F18E0157C05861564
 * - Base: 0x2626664c2603336E57B271c5C0b26F421741e481
 * - Optimism: 0xE592427A0AEce92De3Edee1F18E0157C05861564
 */
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Swaps `amountIn` of one token for as much as possible of another token
     * @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
     * @return amountOut The amount of the received token
     */
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
