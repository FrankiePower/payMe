// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MerchantRegistry
 * @notice Stores merchant payment preferences including chains, addresses, and balance thresholds
 * @dev Used by PaymentReceiver to determine optimal USDC routing for each merchant
 */
contract MerchantRegistry is Ownable {
    /// @notice Structure containing merchant's multi-chain payment configuration
    /// @param wallets Array of merchant wallet addresses (1 per chain)
    /// @param chainEids Array of LayerZero endpoint IDs for supported chains
    /// @param minThresholds Minimum USDC balance desired for each chain (in USDC units, 6 decimals)
    /// @param defaultChainIndex Index in chainEids array for default receive chain
    /// @param isActive Whether merchant is accepting payments
    struct MerchantConfig {
        address[] wallets;
        uint32[] chainEids;
        uint256[] minThresholds;
        uint8 defaultChainIndex;
        bool isActive;
    }

    /// @notice Maps merchant identifier (address or ENS hash) to their configuration
    mapping(bytes32 => MerchantConfig) public merchants;

    /// @notice Emitted when a merchant registers or updates their configuration
    event MerchantRegistered(
        bytes32 indexed merchantId,
        address[] wallets,
        uint32[] chainEids,
        uint256[] minThresholds
    );

    /// @notice Emitted when a merchant deactivates their account
    event MerchantDeactivated(bytes32 indexed merchantId);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Register or update merchant payment configuration
     * @param merchantId Unique identifier for merchant (could be address or keccak256(ENS name))
     * @param wallets Merchant wallet addresses for each chain
     * @param chainEids LayerZero endpoint IDs for each chain
     * @param minThresholds Minimum USDC balance for each chain (e.g., 1000 = 1000 USDC)
     * @param defaultChainIndex Index of default receive chain in the arrays
     */
    function registerMerchant(
        bytes32 merchantId,
        address[] calldata wallets,
        uint32[] calldata chainEids,
        uint256[] calldata minThresholds,
        uint8 defaultChainIndex
    ) external {
        require(wallets.length == chainEids.length, "Length mismatch: wallets/chains");
        require(wallets.length == minThresholds.length, "Length mismatch: wallets/thresholds");
        require(wallets.length > 0, "At least one chain required");
        require(defaultChainIndex < wallets.length, "Invalid default chain index");

        merchants[merchantId] = MerchantConfig({
            wallets: wallets,
            chainEids: chainEids,
            minThresholds: minThresholds,
            defaultChainIndex: defaultChainIndex,
            isActive: true
        });

        emit MerchantRegistered(merchantId, wallets, chainEids, minThresholds);
    }

    /**
     * @notice Deactivate merchant account (stop accepting payments)
     * @param merchantId Merchant identifier to deactivate
     */
    function deactivateMerchant(bytes32 merchantId) external {
        require(merchants[merchantId].isActive, "Merchant not active");
        require(
            msg.sender == owner() ||
            _isMerchantWallet(merchantId, msg.sender),
            "Not authorized"
        );

        merchants[merchantId].isActive = false;
        emit MerchantDeactivated(merchantId);
    }

    /**
     * @notice Get merchant configuration
     * @param merchantId Merchant identifier
     * @return config Full merchant configuration struct
     */
    function getMerchantConfig(bytes32 merchantId)
        external
        view
        returns (MerchantConfig memory config)
    {
        require(merchants[merchantId].isActive, "Merchant not active");
        return merchants[merchantId];
    }

    /**
     * @notice Check if merchant is registered and active
     * @param merchantId Merchant identifier
     * @return bool True if merchant is active
     */
    function isMerchantActive(bytes32 merchantId) external view returns (bool) {
        return merchants[merchantId].isActive;
    }

    /**
     * @notice Get merchant's default receiving wallet and chain
     * @param merchantId Merchant identifier
     * @return wallet Default wallet address
     * @return chainEid Default chain endpoint ID
     */
    function getDefaultReceiver(bytes32 merchantId)
        external
        view
        returns (address wallet, uint32 chainEid)
    {
        require(merchants[merchantId].isActive, "Merchant not active");
        MerchantConfig storage config = merchants[merchantId];
        uint8 idx = config.defaultChainIndex;
        return (config.wallets[idx], config.chainEids[idx]);
    }

    /**
     * @notice Helper to check if an address is one of the merchant's wallets
     * @param merchantId Merchant identifier
     * @param wallet Address to check
     * @return bool True if wallet belongs to merchant
     */
    function _isMerchantWallet(bytes32 merchantId, address wallet)
        internal
        view
        returns (bool)
    {
        MerchantConfig storage config = merchants[merchantId];
        for (uint i = 0; i < config.wallets.length; i++) {
            if (config.wallets[i] == wallet) {
                return true;
            }
        }
        return false;
    }
}
