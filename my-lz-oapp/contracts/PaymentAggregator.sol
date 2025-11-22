// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/**
 * @title PaymentAggregator
 * @notice Aggregates USDC payments from multiple chains with atomic settlement
 * @dev Implements escrow with conditional release pattern:
 *      - User specifies target amount and minimum acceptable threshold
 *      - Payments arrive from multiple source chains via LayerZero
 *      - Auto-settle if target reached
 *      - Manual accept for partial payments above minimum
 *      - Auto-refund if below minimum after timeout
 *
 * Key Features:
 * - 3-minute timeout for aggregation
 * - Percentage-based minimum threshold (e.g., 90%)
 * - User pays refund gas (pre-deposited)
 * - Manual partial acceptance required
 * - Cross-chain refund support
 */
contract PaymentAggregator is OApp {
    using SafeERC20 for IERC20;

    /// @notice Settlement status enum
    enum SettlementStatus {
        PENDING,      // Waiting for payments
        SETTLED,      // Paid to merchant
        PARTIAL,      // Above minimum, waiting for user decision
        REFUNDING,    // Refund in progress
        REFUNDED      // Refund completed
    }

    /// @notice Aggregation request structure
    struct AggregationRequest {
        bytes32 requestId;
        address user;
        address merchant;
        uint256 targetAmount;         // Full amount requested (e.g., 500 USDC)
        uint256 minimumThreshold;     // Minimum acceptable % (e.g., 90 = 90%)
        uint256 amountReceived;       // Total received so far
        uint32 destinationChain;      // Where merchant receives (this chain)
        uint32 refundChain;           // Where user wants refund
        uint256 deadline;             // block.timestamp + 3 minutes
        uint256 refundGasDeposit;     // ETH deposited for refund
        SettlementStatus status;
        bool exists;
    }

    /// @notice Source chain contribution tracking
    struct SourceContribution {
        uint32 chainEid;
        uint256 expectedAmount;
        uint256 receivedAmount;
        bool received;
    }

    /// @notice USDC token on this chain
    IERC20 public immutable usdcToken;

    /// @notice OFT bridge for cross-chain USDC transfers
    address public oftBridge;

    /// @notice Payment aggregation timeout (3 minutes)
    uint256 public constant AGGREGATION_TIMEOUT = 3 minutes;

    /// @notice Minimum refund gas deposit (0.01 ETH)
    uint256 public constant MIN_REFUND_GAS = 0.01 ether;

    /// @notice Mapping of request ID to aggregation request
    mapping(bytes32 => AggregationRequest) public requests;

    /// @notice Mapping of request ID to source contributions
    mapping(bytes32 => SourceContribution[]) public sourceContributions;

    /// @notice Mapping of request ID to received amount per chain
    mapping(bytes32 => mapping(uint32 => uint256)) public receivedPerChain;

    /// @notice Events
    event AggregationInitiated(
        bytes32 indexed requestId,
        address indexed user,
        address indexed merchant,
        uint256 targetAmount,
        uint256 minimumThreshold,
        uint32[] sourceChains,
        uint256[] expectedAmounts
    );

    event PartialPaymentReceived(
        bytes32 indexed requestId,
        uint32 indexed sourceChain,
        uint256 amount,
        uint256 totalReceived,
        uint256 targetAmount
    );

    event PaymentSettled(
        bytes32 indexed requestId,
        address indexed merchant,
        uint256 amount,
        bool isPartial
    );

    event MinimumThresholdReached(
        bytes32 indexed requestId,
        uint256 amountReceived,
        uint256 targetAmount,
        uint256 minimumPercentage
    );

    event PartialPaymentAccepted(
        bytes32 indexed requestId,
        address indexed user,
        uint256 amountAccepted,
        uint256 targetAmount
    );

    event RefundInitiated(
        bytes32 indexed requestId,
        address indexed user,
        uint256 amount,
        uint32 refundChain
    );

    event RefundCompleted(
        bytes32 indexed requestId,
        address indexed user,
        uint256 amount
    );

    event RefundGasWithdrawn(address indexed user, uint256 amount);

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
     * @notice Set OFT bridge address for cross-chain refunds
     * @param _oftBridge OFT bridge address
     */
    function setOFTBridge(address _oftBridge) external onlyOwner {
        require(_oftBridge != address(0), "Invalid OFT bridge");
        oftBridge = _oftBridge;
    }

    /**
     * @notice Initiate payment aggregation from multiple chains
     * @param merchant Merchant to receive payment
     * @param targetAmount Total USDC amount to aggregate (in token decimals)
     * @param minimumThreshold Minimum acceptable percentage (0-100, e.g., 90 = 90%)
     * @param refundChain Chain EID where user wants refund if payment fails
     * @param sourceChains Array of source chain EIDs
     * @param expectedAmounts Array of expected amounts from each source chain
     * @return requestId Unique identifier for this aggregation request
     */
    function initiateAggregation(
        address merchant,
        uint256 targetAmount,
        uint256 minimumThreshold,
        uint32 refundChain,
        uint32[] calldata sourceChains,
        uint256[] calldata expectedAmounts
    ) external payable returns (bytes32 requestId) {
        require(merchant != address(0), "Invalid merchant");
        require(targetAmount > 0, "Invalid target amount");
        require(minimumThreshold > 0 && minimumThreshold <= 100, "Invalid threshold %");
        require(sourceChains.length == expectedAmounts.length, "Length mismatch");
        require(sourceChains.length > 0, "No source chains");
        require(msg.value >= MIN_REFUND_GAS, "Insufficient refund gas");

        // Verify total expected amounts match target
        uint256 totalExpected = 0;
        for (uint i = 0; i < expectedAmounts.length; i++) {
            totalExpected += expectedAmounts[i];
        }
        require(totalExpected >= targetAmount, "Expected < target");

        // Generate unique request ID
        requestId = keccak256(
            abi.encode(
                msg.sender,
                merchant,
                targetAmount,
                block.timestamp,
                block.number
            )
        );

        require(!requests[requestId].exists, "Request already exists");

        // Create aggregation request
        requests[requestId] = AggregationRequest({
            requestId: requestId,
            user: msg.sender,
            merchant: merchant,
            targetAmount: targetAmount,
            minimumThreshold: minimumThreshold,
            amountReceived: 0,
            destinationChain: uint32(endpoint.eid()),
            refundChain: refundChain,
            deadline: block.timestamp + AGGREGATION_TIMEOUT,
            refundGasDeposit: msg.value,
            status: SettlementStatus.PENDING,
            exists: true
        });

        // Store source contributions
        for (uint i = 0; i < sourceChains.length; i++) {
            sourceContributions[requestId].push(
                SourceContribution({
                    chainEid: sourceChains[i],
                    expectedAmount: expectedAmounts[i],
                    receivedAmount: 0,
                    received: false
                })
            );
        }

        emit AggregationInitiated(
            requestId,
            msg.sender,
            merchant,
            targetAmount,
            minimumThreshold,
            sourceChains,
            expectedAmounts
        );

        return requestId;
    }

    /**
     * @notice Receive aggregated payment from source chain
     * @dev Called by LayerZero endpoint when payment arrives
     * @param _origin Source chain information
     * @param _guid Global unique identifier
     * @param _message Encoded (requestId, amount)
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, // executor
        bytes calldata // extraData
    ) internal override {
        (bytes32 requestId, uint256 amount, address user) = abi.decode(
            _message,
            (bytes32, uint256, address)
        );

        AggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(request.status == SettlementStatus.PENDING, "Invalid status");
        require(block.timestamp <= request.deadline, "Request expired");

        // Update received amounts
        request.amountReceived += amount;
        receivedPerChain[requestId][_origin.srcEid] += amount;

        // Update source contribution tracking
        _updateSourceContribution(requestId, _origin.srcEid, amount);

        emit PartialPaymentReceived(
            requestId,
            _origin.srcEid,
            amount,
            request.amountReceived,
            request.targetAmount
        );

        // Check settlement conditions
        _checkSettlement(requestId);
    }

    /**
     * @notice Update source contribution tracking
     */
    function _updateSourceContribution(
        bytes32 requestId,
        uint32 chainEid,
        uint256 amount
    ) internal {
        SourceContribution[] storage contributions = sourceContributions[requestId];

        for (uint i = 0; i < contributions.length; i++) {
            if (contributions[i].chainEid == chainEid) {
                contributions[i].receivedAmount += amount;
                contributions[i].received = true;
                break;
            }
        }
    }

    /**
     * @notice Check if settlement conditions are met
     */
    function _checkSettlement(bytes32 requestId) internal {
        AggregationRequest storage request = requests[requestId];

        // Auto-settle if target amount reached
        if (request.amountReceived >= request.targetAmount) {
            _settleToMerchant(requestId, false);
            return;
        }

        // Check if minimum threshold reached
        uint256 minimumAmount = (request.targetAmount * request.minimumThreshold) / 100;

        if (request.amountReceived >= minimumAmount) {
            request.status = SettlementStatus.PARTIAL;

            emit MinimumThresholdReached(
                requestId,
                request.amountReceived,
                request.targetAmount,
                request.minimumThreshold
            );
        }
    }

    /**
     * @notice User manually accepts partial payment
     * @param requestId Aggregation request ID
     */
    function acceptPartialPayment(bytes32 requestId) external {
        AggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(msg.sender == request.user, "Not authorized");
        require(request.status == SettlementStatus.PARTIAL, "Not in partial status");

        uint256 minimumAmount = (request.targetAmount * request.minimumThreshold) / 100;
        require(request.amountReceived >= minimumAmount, "Below minimum");

        emit PartialPaymentAccepted(
            requestId,
            msg.sender,
            request.amountReceived,
            request.targetAmount
        );

        _settleToMerchant(requestId, true);
    }

    /**
     * @notice Process expired request (auto-settle or auto-refund)
     * @param requestId Aggregation request ID
     */
    function processExpiredRequest(bytes32 requestId) external {
        AggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(block.timestamp > request.deadline, "Not expired yet");
        require(
            request.status == SettlementStatus.PENDING ||
            request.status == SettlementStatus.PARTIAL,
            "Invalid status"
        );

        uint256 minimumAmount = (request.targetAmount * request.minimumThreshold) / 100;

        if (request.amountReceived >= request.targetAmount) {
            // Late arrival, settle anyway
            _settleToMerchant(requestId, false);
        } else if (request.amountReceived >= minimumAmount) {
            // Partial but above minimum - keep in PARTIAL state
            // User must manually accept or request refund
            request.status = SettlementStatus.PARTIAL;
        } else {
            // Below minimum - auto-refund
            _refundToUser(requestId);
        }
    }

    /**
     * @notice User requests refund for partial payment
     * @param requestId Aggregation request ID
     */
    function requestRefund(bytes32 requestId) external {
        AggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(msg.sender == request.user, "Not authorized");
        require(
            request.status == SettlementStatus.PARTIAL ||
            (request.status == SettlementStatus.PENDING && block.timestamp > request.deadline),
            "Cannot refund"
        );
        require(request.amountReceived > 0, "Nothing to refund");

        _refundToUser(requestId);
    }

    /**
     * @notice Settle payment to merchant
     */
    function _settleToMerchant(bytes32 requestId, bool isPartial) internal {
        AggregationRequest storage request = requests[requestId];
        request.status = SettlementStatus.SETTLED;

        // Transfer USDC to merchant
        usdcToken.safeTransfer(request.merchant, request.amountReceived);

        // Refund unused gas deposit to user
        if (request.refundGasDeposit > 0) {
            (bool success, ) = request.user.call{value: request.refundGasDeposit}("");
            require(success, "Gas refund failed");
        }

        emit PaymentSettled(requestId, request.merchant, request.amountReceived, isPartial);
    }

    /**
     * @notice Refund collected amount to user
     */
    function _refundToUser(bytes32 requestId) internal {
        AggregationRequest storage request = requests[requestId];
        request.status = SettlementStatus.REFUNDING;

        uint32 currentChain = uint32(endpoint.eid());

        emit RefundInitiated(requestId, request.user, request.amountReceived, request.refundChain);

        if (request.refundChain == currentChain) {
            // Local refund
            usdcToken.safeTransfer(request.user, request.amountReceived);
            request.status = SettlementStatus.REFUNDED;

            // Refund gas deposit
            if (request.refundGasDeposit > 0) {
                (bool success, ) = request.user.call{value: request.refundGasDeposit}("");
                require(success, "Gas refund failed");
            }

            emit RefundCompleted(requestId, request.user, request.amountReceived);
        } else {
            // Cross-chain refund via OFT
            require(oftBridge != address(0), "OFT bridge not set");

            // Transfer USDC to OFT bridge for cross-chain transfer
            usdcToken.safeApprove(oftBridge, request.amountReceived);

            // Use gas deposit to pay for LayerZero fees
            // Note: In production, would call oftBridge.send() with proper params
            // For now, emit event and handle refund completion separately

            // Status will be updated when cross-chain refund completes
        }
    }

    /**
     * @notice Get aggregation request details
     */
    function getRequest(bytes32 requestId) external view returns (AggregationRequest memory) {
        return requests[requestId];
    }

    /**
     * @notice Get source contributions for a request
     */
    function getSourceContributions(bytes32 requestId)
        external
        view
        returns (SourceContribution[] memory)
    {
        return sourceContributions[requestId];
    }

    /**
     * @notice Calculate minimum acceptable amount for a request
     */
    function getMinimumAmount(bytes32 requestId) external view returns (uint256) {
        AggregationRequest memory request = requests[requestId];
        return (request.targetAmount * request.minimumThreshold) / 100;
    }

    /**
     * @notice Check if request is eligible for settlement
     */
    function canSettle(bytes32 requestId) external view returns (bool) {
        AggregationRequest memory request = requests[requestId];
        return request.amountReceived >= request.targetAmount;
    }

    /**
     * @notice Check if request is eligible for partial acceptance
     */
    function canAcceptPartial(bytes32 requestId) external view returns (bool) {
        AggregationRequest memory request = requests[requestId];
        uint256 minimumAmount = (request.targetAmount * request.minimumThreshold) / 100;
        return request.amountReceived >= minimumAmount && request.status == SettlementStatus.PARTIAL;
    }

    /**
     * @notice Emergency withdraw (owner only)
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Receive ETH for gas deposits
     */
    receive() external payable {}
}
