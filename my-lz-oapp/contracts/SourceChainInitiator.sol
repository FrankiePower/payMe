// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SourceChainInitiator
 * @notice Initiates USDC transfers from source chain to PaymentAggregator on destination chain
 * @dev Deployed on each source chain (Arbitrum, Optimism, Base, etc.)
 *      Works with PaymentAggregator on destination chain to aggregate payments
 *
 * Flow:
 * 1. User approves USDC to this contract
 * 2. User calls sendToAggregator() with request details
 * 3. Contract locks USDC and sends LayerZero message to destination
 * 4. PaymentAggregator receives and tracks the payment
 *
 * Key Features:
 * - Locks user's USDC before sending
 * - Sends LayerZero message with request ID
 * - Tracks pending transfers
 * - Handles acknowledgments from destination
 */
contract SourceChainInitiator is OApp {
    using SafeERC20 for IERC20;

    /// @notice USDC token on this chain
    IERC20 public immutable usdcToken;

    /// @notice OFT bridge for USDC transfers
    address public oftBridge;

    /// @notice PaymentAggregator address on destination chain (as bytes32)
    mapping(uint32 => bytes32) public aggregatorByChain;

    /// @notice Pending transfer tracking
    struct PendingTransfer {
        bytes32 requestId;
        address user;
        uint256 amount;
        uint32 destinationChain;
        uint256 timestamp;
        bool sent;
        bool acknowledged;
    }

    /// @notice Mapping of transfer ID to pending transfer
    mapping(bytes32 => PendingTransfer) public pendingTransfers;

    /// @notice Events
    event AggregatorRegistered(uint32 indexed chainEid, bytes32 aggregator);

    event TransferInitiated(
        bytes32 indexed transferId,
        bytes32 indexed requestId,
        address indexed user,
        uint256 amount,
        uint32 destinationChain
    );

    event TransferSent(
        bytes32 indexed transferId,
        bytes32 indexed requestId,
        uint256 amount,
        bytes32 guid
    );

    event TransferAcknowledged(
        bytes32 indexed transferId,
        bytes32 indexed requestId
    );

    /**
     * @notice Constructor
     * @param _endpoint LayerZero endpoint address
     * @param _usdcToken USDC token address on this chain
     * @param _owner Contract owner
     */
    constructor(
        address _endpoint,
        address _usdcToken,
        address _owner
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        require(_usdcToken != address(0), "Invalid USDC address");
        usdcToken = IERC20(_usdcToken);
    }

    /**
     * @notice Set OFT bridge address
     * @param _oftBridge OFT bridge address
     */
    function setOFTBridge(address _oftBridge) external onlyOwner {
        require(_oftBridge != address(0), "Invalid OFT bridge");
        oftBridge = _oftBridge;
    }

    /**
     * @notice Register PaymentAggregator address for a destination chain
     * @param chainEid Destination chain endpoint ID
     * @param aggregator PaymentAggregator address on that chain (as bytes32)
     */
    function registerAggregator(uint32 chainEid, bytes32 aggregator) external onlyOwner {
        require(aggregator != bytes32(0), "Invalid aggregator");
        aggregatorByChain[chainEid] = aggregator;
        emit AggregatorRegistered(chainEid, aggregator);
    }

    /**
     * @notice Send USDC to PaymentAggregator on destination chain
     * @param requestId Aggregation request ID
     * @param amount USDC amount to send
     * @param destinationChain Destination chain endpoint ID
     * @param options LayerZero execution options
     * @return transferId Unique transfer identifier
     *
     * @dev User must approve USDC to this contract before calling
     */
    function sendToAggregator(
        bytes32 requestId,
        uint256 amount,
        uint32 destinationChain,
        bytes calldata options
    ) external payable returns (bytes32 transferId) {
        require(amount > 0, "Invalid amount");
        require(aggregatorByChain[destinationChain] != bytes32(0), "Aggregator not registered");

        // Generate transfer ID
        transferId = keccak256(
            abi.encode(
                requestId,
                msg.sender,
                amount,
                destinationChain,
                block.timestamp
            )
        );

        require(!pendingTransfers[transferId].sent, "Transfer already sent");

        // Lock user's USDC
        usdcToken.safeTransferFrom(msg.sender, address(this), amount);

        // Create pending transfer record
        pendingTransfers[transferId] = PendingTransfer({
            requestId: requestId,
            user: msg.sender,
            amount: amount,
            destinationChain: destinationChain,
            timestamp: block.timestamp,
            sent: false,
            acknowledged: false
        });

        emit TransferInitiated(transferId, requestId, msg.sender, amount, destinationChain);

        // Send LayerZero message with USDC via OFT
        _sendViaOFT(transferId, requestId, amount, destinationChain, options);

        return transferId;
    }

    /**
     * @notice Send USDC via OFT bridge
     */
    function _sendViaOFT(
        bytes32 transferId,
        bytes32 requestId,
        uint256 amount,
        uint32 destinationChain,
        bytes calldata options
    ) internal {
        // Prepare message for PaymentAggregator
        bytes memory message = abi.encode(requestId, amount, pendingTransfers[transferId].user);

        // Approve USDC to OFT bridge
        usdcToken.safeApprove(oftBridge, amount);

        // Send via LayerZero
        bytes32 guid = _lzSend(
            destinationChain,
            message,
            options,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        // Mark as sent
        pendingTransfers[transferId].sent = true;

        emit TransferSent(transferId, requestId, amount, guid);
    }

    /**
     * @notice Receive acknowledgment from destination chain
     * @dev Called by LayerZero when PaymentAggregator acknowledges receipt
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, // executor
        bytes calldata // extraData
    ) internal override {
        (bytes32 transferId, bool success) = abi.decode(_message, (bytes32, bool));

        PendingTransfer storage transfer = pendingTransfers[transferId];
        require(transfer.sent, "Transfer not found");

        transfer.acknowledged = true;

        emit TransferAcknowledged(transferId, transfer.requestId);

        // If acknowledgment indicates failure, handle refund
        if (!success) {
            // Refund USDC to user
            usdcToken.safeTransfer(transfer.user, transfer.amount);
        }
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
     * @notice Receive ETH for LayerZero fees
     */
    receive() external payable {}
}
