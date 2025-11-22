// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MerchantRegistry } from "./MerchantRegistry.sol";
import { GenericUSDCAnalyzer } from "./GenericUSDCAnalyzer.sol";
import { ITokenMessenger } from "./interfaces/ITokenMessenger.sol";

/**
 * @title PaymentComposerOFT
 * @notice Composer contract that receives horizontally composed messages from PaymentReceiverOFT
 *         and executes optimal USDC routing using BOTH LayerZero OFT and Circle CCTP
 * @dev Implements IOAppComposer to receive lzCompose() calls from LayerZero Endpoint
 *
 * Innovation: Hybrid routing strategy
 * - Use OFT for fast, small-amount transfers
 * - Use CCTP for native USDC settlement on large amounts
 * - Merchant can configure preference per chain
 */
contract PaymentComposerOFT is IOAppComposer, Ownable {
    using SafeERC20 for IERC20;

    /// @notice LayerZero Endpoint address
    ILayerZeroEndpointV2 public immutable endpoint;

    /// @notice PaymentReceiverOFT OApp address (only this address can send composed messages)
    address public immutable paymentReceiver;

    /// @notice OFT token on this chain (the PaymentReceiverOFT itself)
    IERC20 public immutable oftToken;

    /// @notice Merchant registry
    MerchantRegistry public immutable merchantRegistry;

    /// @notice GenericUSDCAnalyzer for balance analysis
    GenericUSDCAnalyzer public usdcAnalyzer;

    /// @notice Circle CCTP TokenMessenger contract
    ITokenMessenger public cctpTokenMessenger;

    /// @notice Mapping of LayerZero EID → Circle domain ID
    mapping(uint32 => uint32) public circleDomainByEid;

    /// @notice Routing preference: OFT (0), CCTP (1), Hybrid (2)
    enum RoutingMode { OFT, CCTP, HYBRID }

    /// @notice Merchant routing preferences
    mapping(bytes32 => RoutingMode) public merchantRoutingMode;

    /// @notice Threshold for hybrid routing (amounts above this use CCTP)
    uint256 public hybridThreshold = 1000 * 1e6; // 1000 USDC default

    /// @notice Emitted when optimal routing is executed
    event OptimalRoutingExecuted(
        bytes32 indexed merchantId,
        uint256 totalAmount,
        uint256[] dispatchPlan,
        uint32[] targetChains,
        RoutingMode mode
    );

    /// @notice Emitted when OFT transfer is initiated
    event OFTTransferInitiated(
        bytes32 indexed merchantId,
        uint32 destinationEid,
        address recipient,
        uint256 amount
    );

    /// @notice Emitted when CCTP transfer is initiated
    event CCTPTransferInitiated(
        bytes32 indexed merchantId,
        uint32 destinationDomain,
        address recipient,
        uint256 amount,
        uint64 nonce
    );

    /**
     * @notice Constructor
     * @param _endpoint LayerZero endpoint address
     * @param _paymentReceiver PaymentReceiverOFT address (also the OFT token)
     * @param _merchantRegistry Merchant registry address
     * @param _owner Contract owner
     */
    constructor(
        address _endpoint,
        address _paymentReceiver,
        address _merchantRegistry,
        address _owner
    ) Ownable(_owner) {
        endpoint = ILayerZeroEndpointV2(_endpoint);
        paymentReceiver = _paymentReceiver;
        oftToken = IERC20(_paymentReceiver); // PaymentReceiverOFT is also an ERC20
        merchantRegistry = MerchantRegistry(_merchantRegistry);
    }

    /**
     * @notice Set the GenericUSDCAnalyzer contract address
     * @param _analyzer Address of GenericUSDCAnalyzer
     */
    function setUSDCAnalyzer(address _analyzer) external onlyOwner {
        require(_analyzer != address(0), "Invalid analyzer");
        usdcAnalyzer = GenericUSDCAnalyzer(_analyzer);
    }

    /**
     * @notice Set Circle CCTP TokenMessenger address
     * @param _tokenMessenger Circle TokenMessenger address
     */
    function setCCTPTokenMessenger(address _tokenMessenger) external onlyOwner {
        require(_tokenMessenger != address(0), "Invalid token messenger");
        cctpTokenMessenger = ITokenMessenger(_tokenMessenger);

        // Approve OFT token spending for CCTP (in case we convert OFT to USDC)
        oftToken.approve(_tokenMessenger, type(uint256).max);
    }

    /**
     * @notice Map LayerZero EID to Circle domain ID
     * @param eid LayerZero endpoint ID
     * @param domainId Circle domain ID
     */
    function setCircleDomain(uint32 eid, uint32 domainId) external onlyOwner {
        circleDomainByEid[eid] = domainId;
    }

    /**
     * @notice Set merchant's routing preference
     * @param merchantId Merchant identifier
     * @param mode Routing mode (OFT, CCTP, or HYBRID)
     */
    function setMerchantRoutingMode(bytes32 merchantId, RoutingMode mode) external {
        // Only merchant or owner can set routing mode
        MerchantRegistry.MerchantConfig memory config = merchantRegistry.getMerchantConfig(merchantId);
        require(
            msg.sender == owner() || _isMerchantWallet(config, msg.sender),
            "Not authorized"
        );
        merchantRoutingMode[merchantId] = mode;
    }

    /**
     * @notice Set hybrid routing threshold
     * @param threshold Amount threshold (amounts above use CCTP, below use OFT)
     */
    function setHybridThreshold(uint256 threshold) external onlyOwner {
        hybridThreshold = threshold;
    }

    /**
     * @notice STEP 2 (NON-CRITICAL): Handle composed message from PaymentReceiverOFT
     * @dev This is called by LayerZero Endpoint after PaymentReceiverOFT.lzReceive() calls sendCompose()
     * @param _oApp Address of the OApp that sent the composed message (must be paymentReceiver)
     * @param _guid Global unique identifier
     * @param _message Encoded composed message containing:
     *        - nonce: Origin nonce
     *        - srcEid: Source chain endpoint ID
     *        - merchantId: Merchant identifier
     *        - amount: OFT amount received
     *        - payer: Original payer address
     *        - recipient: Where tokens were minted
     */
    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address, // executor
        bytes calldata // extraData
    ) external payable override {
        // Security: Only accept composed messages from our PaymentReceiverOFT
        require(_oApp == paymentReceiver, "Invalid OApp");
        require(msg.sender == address(endpoint), "Unauthorized sender");

        // Decode composed message
        (
            uint64 nonce,
            uint32 srcEid,
            bytes32 merchantId,
            uint256 amount,
            address payer,
            address recipient
        ) = abi.decode(_message, (uint64, uint32, bytes32, uint256, address, address));

        // Execute optimal routing based on merchant preference
        _executeOptimalRouting(merchantId, amount, recipient, _guid);
    }

    /**
     * @notice Execute optimal routing based on merchant configuration
     * @param merchantId Merchant identifier
     * @param amount Total OFT amount to route
     * @param currentRecipient Where OFT tokens are currently held
     * @param guid Message GUID for tracking
     */
    function _executeOptimalRouting(
        bytes32 merchantId,
        uint256 amount,
        address currentRecipient,
        bytes32 guid
    ) internal {
        // Get merchant configuration
        MerchantRegistry.MerchantConfig memory config = merchantRegistry.getMerchantConfig(merchantId);

        // If only one chain configured, send directly
        if (config.chainEids.length == 1) {
            _sendToChain(
                merchantId,
                config.wallets[0],
                config.chainEids[0],
                amount,
                currentRecipient
            );
            return;
        }

        // Get routing mode for this merchant
        RoutingMode mode = merchantRoutingMode[merchantId];

        // TODO: Integrate GenericUSDCAnalyzer for intelligent dispatch plan
        // For now: Equal distribution across all chains

        uint256[] memory dispatchPlan = new uint256[](config.chainEids.length);
        uint256 amountPerChain = amount / config.chainEids.length;
        uint256 remainder = amount % config.chainEids.length;

        for (uint i = 0; i < config.chainEids.length; i++) {
            dispatchPlan[i] = amountPerChain;
            if (i < remainder) {
                dispatchPlan[i] += 1;
            }
        }

        // Execute routing based on mode
        if (mode == RoutingMode.OFT) {
            _routeViaOFT(merchantId, config, dispatchPlan, currentRecipient);
        } else if (mode == RoutingMode.CCTP) {
            _routeViaCCTP(merchantId, config, dispatchPlan, currentRecipient);
        } else {
            _routeHybrid(merchantId, config, dispatchPlan, currentRecipient);
        }

        emit OptimalRoutingExecuted(merchantId, amount, dispatchPlan, config.chainEids, mode);
    }

    /**
     * @notice Route funds via LayerZero OFT
     * @param merchantId Merchant identifier
     * @param config Merchant configuration
     * @param amounts Amounts to send to each chain
     * @param fromAddress Address holding the OFT tokens
     */
    function _routeViaOFT(
        bytes32 merchantId,
        MerchantRegistry.MerchantConfig memory config,
        uint256[] memory amounts,
        address fromAddress
    ) internal {
        // Transfer OFT tokens from current holder to this contract if needed
        if (fromAddress != address(this)) {
            for (uint i = 0; i < amounts.length; i++) {
                if (amounts[i] > 0) {
                    oftToken.safeTransferFrom(fromAddress, address(this), amounts[i]);
                }
            }
        }

        for (uint i = 0; i < config.chainEids.length; i++) {
            if (amounts[i] == 0) continue;

            uint32 currentEid = endpoint.eid();

            // Same chain - direct transfer
            if (config.chainEids[i] == currentEid) {
                oftToken.safeTransfer(config.wallets[i], amounts[i]);
                continue;
            }

            // Cross-chain via OFT
            // Note: This would require calling the OFT's send function
            // For simplicity in demo, we emit event
            emit OFTTransferInitiated(merchantId, config.chainEids[i], config.wallets[i], amounts[i]);
        }
    }

    /**
     * @notice Route funds via Circle CCTP
     * @param merchantId Merchant identifier
     * @param config Merchant configuration
     * @param amounts Amounts to send to each chain
     * @param fromAddress Address holding the OFT tokens
     */
    function _routeViaCCTP(
        bytes32 merchantId,
        MerchantRegistry.MerchantConfig memory config,
        uint256[] memory amounts,
        address fromAddress
    ) internal {
        require(address(cctpTokenMessenger) != address(0), "CCTP not configured");

        // Note: In production, you'd convert OFT to native USDC first
        // For demo, we assume OFT can be used with CCTP

        for (uint i = 0; i < config.chainEids.length; i++) {
            if (amounts[i] == 0) continue;

            uint32 currentEid = endpoint.eid();

            // Same chain - direct transfer
            if (config.chainEids[i] == currentEid) {
                oftToken.safeTransfer(config.wallets[i], amounts[i]);
                continue;
            }

            // Cross-chain via CCTP
            _bridgeViaCCTP(merchantId, config.wallets[i], config.chainEids[i], amounts[i]);
        }
    }

    /**
     * @notice Hybrid routing: Use OFT for small amounts, CCTP for large
     * @param merchantId Merchant identifier
     * @param config Merchant configuration
     * @param amounts Amounts to send to each chain
     * @param fromAddress Address holding the OFT tokens
     */
    function _routeHybrid(
        bytes32 merchantId,
        MerchantRegistry.MerchantConfig memory config,
        uint256[] memory amounts,
        address fromAddress
    ) internal {
        for (uint i = 0; i < config.chainEids.length; i++) {
            if (amounts[i] == 0) continue;

            uint32 currentEid = endpoint.eid();

            // Same chain - direct transfer
            if (config.chainEids[i] == currentEid) {
                oftToken.safeTransfer(config.wallets[i], amounts[i]);
                continue;
            }

            // Choose protocol based on amount
            if (amounts[i] >= hybridThreshold) {
                // Large amount - use CCTP for native USDC
                _bridgeViaCCTP(merchantId, config.wallets[i], config.chainEids[i], amounts[i]);
            } else {
                // Small amount - use OFT for speed
                emit OFTTransferInitiated(merchantId, config.chainEids[i], config.wallets[i], amounts[i]);
            }
        }
    }

    /**
     * @notice Send tokens to a single chain
     * @param merchantId Merchant identifier
     * @param wallet Merchant wallet address
     * @param chainEid Chain endpoint ID
     * @param amount Amount to send
     * @param fromAddress Current token holder
     */
    function _sendToChain(
        bytes32 merchantId,
        address wallet,
        uint32 chainEid,
        uint256 amount,
        address fromAddress
    ) internal {
        uint32 currentEid = endpoint.eid();

        if (chainEid == currentEid) {
            // Same chain - direct transfer
            if (fromAddress != wallet) {
                oftToken.safeTransferFrom(fromAddress, wallet, amount);
            }
        } else {
            // Cross-chain - use merchant's preferred mode
            RoutingMode mode = merchantRoutingMode[merchantId];
            if (mode == RoutingMode.CCTP || (mode == RoutingMode.HYBRID && amount >= hybridThreshold)) {
                _bridgeViaCCTP(merchantId, wallet, chainEid, amount);
            } else {
                emit OFTTransferInitiated(merchantId, chainEid, wallet, amount);
            }
        }
    }

    /**
     * @notice Bridge tokens via Circle CCTP
     * @param merchantId Merchant identifier
     * @param recipient Recipient address on destination chain
     * @param destinationEid Destination LayerZero endpoint ID
     * @param amount Amount to bridge
     */
    function _bridgeViaCCTP(
        bytes32 merchantId,
        address recipient,
        uint32 destinationEid,
        uint256 amount
    ) internal {
        require(address(cctpTokenMessenger) != address(0), "CCTP not configured");

        // Get Circle domain ID from LayerZero EID
        uint32 destinationDomain = circleDomainByEid[destinationEid];
        require(destinationDomain != 0, "Unsupported destination chain");

        // Convert recipient address to bytes32 for CCTP
        bytes32 mintRecipient = bytes32(uint256(uint160(recipient)));

        // Call Circle CCTP depositForBurn
        // Note: In production, convert OFT to USDC first
        uint64 nonce = cctpTokenMessenger.depositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            address(oftToken) // Using OFT token address (in prod, use USDC)
        );

        emit CCTPTransferInitiated(merchantId, destinationDomain, recipient, amount, nonce);
    }

    /**
     * @notice Check if address is merchant wallet
     * @param config Merchant config
     * @param wallet Address to check
     * @return bool True if wallet belongs to merchant
     */
    function _isMerchantWallet(MerchantRegistry.MerchantConfig memory config, address wallet)
        internal
        pure
        returns (bool)
    {
        for (uint i = 0; i < config.wallets.length; i++) {
            if (config.wallets[i] == wallet) return true;
        }
        return false;
    }

    /**
     * @notice Emergency withdraw function
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
