// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for InstantAggregator
 */
interface IInstantAggregator {
    function recordDirectPayment(bytes32 requestId, uint256 amount) external;
}

/**
 * @notice CctpBridger interface
 */
interface ICctpBridger {
    function bridgeUSDCV2(
        uint256 amount,
        uint32 destDomain,
        address destMintRecipient,
        address destCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external returns (bytes32 messageHash);
}

/**
 * @title SourceChainInitiator
 * @notice Initiates USDC transfers from source chain to InstantAggregator on destination chain
 * @dev Uses Circle CCTP to burn USDC and mint to aggregator (replacing OFT Adapter)
 *
 * ARCHITECTURE:
 * - User sends USDC from any chain (Arbitrum, Optimism, etc.)
 * - Contract burns USDC via Circle CCTP
 * - Circle mints USDC to InstantAggregator on destination chain
 * - InstantAggregator receives USDC + hookData for aggregation
 *
 * Flow:
 * 1. User approves USDC to this contract
 * 2. User calls sendToAggregator() with request details
 * 3. Contract burns USDC via CCTP with hookData containing requestId
 * 4. Circle mints USDC to InstantAggregator on destination
 * 5. InstantAggregator's handleReceiveMessage() is called with hookData
 * 6. Aggregator tracks the payment and settles when threshold met
 */
contract SourceChainInitiator is OApp {
    using SafeERC20 for IERC20;

    /// @notice USDC token on this chain
    IERC20 public immutable usdcToken;

    /// @notice CctpBridger contract
    ICctpBridger public immutable cctpBridger;

    /// @notice InstantAggregator address on destination chain (as address)
    mapping(uint32 => address) public aggregatorByEid;

    /// @notice CCTP domain ID by LayerZero EID
    mapping(uint32 => uint32) public cctpDomainByEid;

    /// @notice Pending transfer tracking
    struct PendingTransfer {
        bytes32 requestId;
        address user;
        uint256 amount;
        uint32 destinationChain;
        bytes32 cctpMessageHash;
        uint256 timestamp;
        bool sent;
    }

    /// @notice Mapping of transfer ID to pending transfer
    mapping(bytes32 => PendingTransfer) public pendingTransfers;

    /// @notice Events
    event AggregatorRegistered(uint32 indexed chainEid, address aggregator);
    event CCTPDomainRegistered(uint32 indexed chainEid, uint32 cctpDomain);

    event TransferInitiated(
        bytes32 indexed transferId,
        bytes32 indexed requestId,
        address indexed user,
        uint256 amount,
        uint32 destinationChain
    );

    event CCTPBurnInitiated(
        bytes32 indexed transferId,
        bytes32 indexed cctpMessageHash,
        uint256 amount
    );

    /**
     * @notice Constructor
     * @param _endpoint LayerZero endpoint address (for future cross-chain messages if needed)
     * @param _usdcToken USDC token address on this chain
     * @param _cctpBridger CctpBridger contract address
     * @param _owner Contract owner
     */
    constructor(
        address _endpoint,
        address _usdcToken,
        address _cctpBridger,
        address _owner
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_cctpBridger != address(0), "Invalid CctpBridger");
        usdcToken = IERC20(_usdcToken);
        cctpBridger = ICctpBridger(_cctpBridger);
    }

    /**
     * @notice Register InstantAggregator address for a destination chain
     * @param chainEid Destination chain LayerZero endpoint ID
     * @param aggregator InstantAggregator address on that chain
     */
    function registerAggregator(uint32 chainEid, address aggregator) external onlyOwner {
        require(aggregator != address(0), "Invalid aggregator");
        aggregatorByEid[chainEid] = aggregator;
        emit AggregatorRegistered(chainEid, aggregator);
    }

    /**
     * @notice Register CCTP domain for a LayerZero endpoint ID
     * @param chainEid LayerZero endpoint ID
     * @param cctpDomain Circle CCTP domain ID
     *
     * Common mappings (Testnet):
     * - Ethereum Sepolia: EID 40161, Domain 0
     * - Arbitrum Sepolia: EID 40231, Domain 3
     * - Base Sepolia: EID 40245, Domain 6
     * - Optimism Sepolia: EID 40232, Domain 2
     */
    function registerCCTPDomain(uint32 chainEid, uint32 cctpDomain) external onlyOwner {
        cctpDomainByEid[chainEid] = cctpDomain;
        emit CCTPDomainRegistered(chainEid, cctpDomain);
    }

    /**
     * @notice Send USDC to InstantAggregator on destination chain via CCTP
     * @param requestId Aggregation request ID
     * @param amount USDC amount to send
     * @param destinationEid Destination chain LayerZero endpoint ID
     * @param useFastMode Use CCTP Fast mode (1-2 min, ~$1 fee) vs standard (10-20 min, free)
     * @return transferId Unique transfer identifier
     *
     * @dev User must approve USDC to this contract before calling
     */
    function sendToAggregator(
        bytes32 requestId,
        uint256 amount,
        uint32 destinationEid,
        bool useFastMode
    ) external returns (bytes32 transferId) {
        require(amount > 0, "Invalid amount");
        require(aggregatorByEid[destinationEid] != address(0), "Aggregator not registered");

        uint32 destDomain = cctpDomainByEid[destinationEid];
        require(destDomain != 0 || destinationEid == 40161, "CCTP domain not registered");

        // Generate transfer ID
        transferId = keccak256(
            abi.encode(
                requestId,
                msg.sender,
                amount,
                destinationEid,
                block.timestamp
            )
        );

        require(!pendingTransfers[transferId].sent, "Transfer already sent");

        // Transfer USDC from user to this contract
        usdcToken.safeTransferFrom(msg.sender, address(this), amount);

        emit TransferInitiated(transferId, requestId, msg.sender, amount, destinationEid);

        // Check if same-chain or cross-chain
        uint32 currentEid = uint32(endpoint.eid());

        if (destinationEid == currentEid) {
            // Same chain - direct transfer (no CCTP needed)
            _sendDirect(transferId, requestId, amount, destinationEid);
        } else {
            // Cross chain - use CCTP
            _sendViaCCTP(transferId, requestId, amount, destinationEid, useFastMode);
        }

        return transferId;
    }

    /**
     * @notice Send USDC directly to aggregator (same chain)
     * @dev No CCTP needed - just transfer USDC and call aggregator
     */
    function _sendDirect(
        bytes32 transferId,
        bytes32 requestId,
        uint256 amount,
        uint32 destinationEid
    ) internal {
        address aggregator = aggregatorByEid[destinationEid];
        require(aggregator != address(0), "Invalid aggregator");

        // Transfer USDC to aggregator
        usdcToken.safeTransfer(aggregator, amount);

        // Call aggregator to record the payment
        IInstantAggregator(aggregator).recordDirectPayment(requestId, amount);

        // Mark as sent
        pendingTransfers[transferId] = PendingTransfer({
            requestId: requestId,
            user: msg.sender,
            amount: amount,
            destinationChain: destinationEid,
            cctpMessageHash: bytes32(0),
            timestamp: block.timestamp,
            sent: true
        });
    }

    /**
     * @notice Send USDC via CCTP (cross-chain)
     * @dev Burns USDC on source chain, mints to InstantAggregator on destination
     */
    function _sendViaCCTP(
        bytes32 transferId,
        bytes32 requestId,
        uint256 amount,
        uint32 destinationEid,
        bool useFastMode
    ) internal {
        uint32 destDomain = cctpDomainByEid[destinationEid];
        address aggregator = aggregatorByEid[destinationEid];

        // Approve USDC to CctpBridger
        usdcToken.safeIncreaseAllowance(address(cctpBridger), amount);

        // Prepare hookData: requestId for aggregator to track this payment
        bytes memory hookData = abi.encode(requestId);

        // Configure CCTP parameters
        uint256 maxFee = useFastMode ? 1e6 : 0; // 1 USDC max fee for fast mode
        uint32 minFinalityThreshold = useFastMode ? 1000 : 2000; // 1000=fast, 2000=standard

        // Bridge USDC via CctpBridger
        bytes32 cctpMessageHash = cctpBridger.bridgeUSDCV2(
            amount,
            destDomain,
            aggregator,        // Mint to aggregator
            aggregator,        // Aggregator can receive the hook
            maxFee,
            minFinalityThreshold,
            hookData           // Pass requestId to aggregator
        );

        emit CCTPBurnInitiated(transferId, cctpMessageHash, amount);

        // Store pending transfer
        pendingTransfers[transferId] = PendingTransfer({
            requestId: requestId,
            user: msg.sender,
            amount: amount,
            destinationChain: destinationEid,
            cctpMessageHash: cctpMessageHash,
            timestamp: block.timestamp,
            sent: true
        });
    }

    /**
     * @notice Convert address to bytes32
     */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Get pending transfer details
     */
    function getPendingTransfer(bytes32 transferId)
        external
        view
        returns (PendingTransfer memory)
    {
        return pendingTransfers[transferId];
    }

    /**
     * @notice Emergency withdraw (owner only)
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Receive ETH for LayerZero fees (future use)
     */
    receive() external payable {}

    /**
     * @notice Required by OApp - handle incoming LayerZero messages
     * @dev Not used currently, but required by OApp interface
     */
    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata,
        address,
        bytes calldata
    ) internal override {
        // Not used - keeping for future acknowledgments if needed
    }
}
