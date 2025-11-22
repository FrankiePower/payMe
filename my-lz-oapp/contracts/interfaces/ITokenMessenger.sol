// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ITokenMessenger
 * @notice Circle CCTP TokenMessenger interface
 * @dev Used for burning USDC on source chain for cross-chain transfer
 */
interface ITokenMessenger {
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain
     * @param amount Amount of tokens to burn
     * @param destinationDomain Circle domain ID of destination chain
     * @param mintRecipient Recipient address on destination chain (as bytes32)
     * @param burnToken Token address to burn (USDC)
     * @return nonce Unique nonce for this burn
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);

    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain,
     *         with a specified destination caller
     * @param amount Amount of tokens to burn
     * @param destinationDomain Circle domain ID of destination chain
     * @param mintRecipient Recipient address on destination chain (as bytes32)
     * @param burnToken Token address to burn (USDC)
     * @param destinationCaller Authorized caller on destination chain
     * @return nonce Unique nonce for this burn
     */
    function depositForBurnWithCaller(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller
    ) external returns (uint64 nonce);
}
