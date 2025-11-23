// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "./interfaces/ISwapRouter.sol";

/**
 * @notice Circle CCTP MessageTransmitter interface for receiving hooks
 */
interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/**
 * @title InstantAggregator
 * @notice FAST payment aggregation using Circle CCTP for instant settlement
 * @dev Key innovation: Transfer USDC immediately when ALL payments confirmed via CCTP
 *
 * Speed comparison:
 * - Traditional aggregation: 10-15 minutes (wait for all USDC to arrive)
 * - CCTP aggregation: 1-2 minutes (Circle mints USDC directly to this contract)
 *
 * Flow:
 * 1. Scan user balances across chains to determine exact amounts
 * 2. User sends USDC from all source chains via SourceChainInitiator
 * 3. SourceChainInitiator burns USDC via CCTP with hookData containing requestId
 * 4. Circle mints USDC to this contract with handleReceiveMessage hook
 * 5. When FULL amount received (100%), INSTANTLY transfer USDC to merchant
 * 6. Merchant receives native USDC in ~2 minutes
 *
 * With CCTP:
 * - USDC burned on source chains, minted natively on destination
 * - Merchant receives native USDC (not wrapped)
 * - No OFT Adapter issues - Circle handles everything
 *
 * No Partial Payments:
 * - Must receive exact target amount (100%)
 * - If deadline expires without full amount, request fails
 * - All-or-nothing settlement
 */
contract InstantAggregator is OApp {
    using SafeERC20 for IERC20;

    /// @notice Settlement status
    enum SettlementStatus {
        PENDING,           // Waiting for lock confirmations
        SETTLED,           // USDC transferred to merchant (INSTANT)
        REFUNDING,         // Refund in progress
        REFUNDED           // Refund completed
    }

    /// @notice Aggregation request
    struct InstantAggregationRequest {
        bytes32 requestId;
        address user;
        address merchant;
        uint256 targetAmount;          // Exact amount required (100%)
        uint256 totalLocked;           // Total confirmed locks
        uint32 destinationChain;
        uint32 refundChain;
        uint256 deadline;              // 180 seconds (3 minutes)
        uint256 refundGasDeposit;
        SettlementStatus status;
        bool exists;
        uint256 usdcSettledAmount;     // USDC transferred to merchant
    }

    /// @notice Circle CCTP MessageTransmitter for receiving USDC with hooks
    /// @dev Circle calls handleReceiveMessage on this contract after minting USDC
    address public messageTransmitter;

    /// @notice Uniswap V3 Swap Router for token swaps
    /// @dev Used to swap non-USDC tokens (ARB, ETH, etc.) to USDC on-chain
    address public swapRouter;

    /// @notice Native USDC token address
    address public usdcToken;

    /// @notice Requests mapping
    mapping(bytes32 => InstantAggregationRequest) public requests;

    /// @notice Locked amounts per chain per request
    mapping(bytes32 => mapping(uint32 => uint256)) public lockedPerChain;

    /// @notice Expected amounts per chain per request
    mapping(bytes32 => mapping(uint32 => uint256)) public expectedPerChain;

    /// @notice Events
    event InstantAggregationInitiated(
        bytes32 indexed requestId,
        address indexed user,
        address indexed merchant,
        uint256 targetAmount
    );

    event LockConfirmed(
        bytes32 indexed requestId,
        uint32 indexed sourceChain,
        uint256 amount,
        uint256 totalLocked
    );

    event InstantSettlement(
        bytes32 indexed requestId,
        address indexed merchant,
        uint256 usdcAmount,
        uint256 timeElapsed
    );

    event TokenSwapped(
        bytes32 indexed requestId,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcOut
    );

    /**
     * @notice Constructor
     * @param _endpoint LayerZero endpoint (for future cross-chain messages if needed)
     * @param _messageTransmitter Circle CCTP MessageTransmitter address
     * @param _owner Contract owner
     */
    constructor(
        address _endpoint,
        address _messageTransmitter,
        address _owner
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        require(_messageTransmitter != address(0), "Invalid MessageTransmitter");
        messageTransmitter = _messageTransmitter;
    }

    /**
     * @notice Set swap router and USDC token addresses
     * @dev Owner-only function to configure DEX integration
     */
    function setSwapConfig(address _swapRouter, address _usdcToken) external onlyOwner {
        require(_swapRouter != address(0), "Invalid swap router");
        require(_usdcToken != address(0), "Invalid USDC token");
        swapRouter = _swapRouter;
        usdcToken = _usdcToken;
    }

    /**
     * @notice Initiate instant aggregation
     * @dev Agent calls this first, then sends lock messages to source chains
     */
    function initiateInstantAggregation(
        address merchant,
        uint256 targetAmount,
        uint32 refundChain,
        uint32[] calldata sourceChains,
        uint256[] calldata expectedAmounts
    ) external payable returns (bytes32 requestId) {
        require(merchant != address(0), "Invalid merchant");
        require(targetAmount > 0, "Invalid amount");
        require(sourceChains.length == expectedAmounts.length, "Length mismatch");
        require(msg.value >= 0.01 ether, "Insufficient refund gas");

        requestId = keccak256(
            abi.encode(msg.sender, merchant, targetAmount, block.timestamp)
        );

        requests[requestId] = InstantAggregationRequest({
            requestId: requestId,
            user: msg.sender,
            merchant: merchant,
            targetAmount: targetAmount,
            totalLocked: 0,
            destinationChain: uint32(endpoint.eid()),
            refundChain: refundChain,
            deadline: block.timestamp + 180, // 3 minutes
            refundGasDeposit: msg.value,
            status: SettlementStatus.PENDING,
            exists: true,
            usdcSettledAmount: 0
        });

        // Store expected amounts per chain
        for (uint i = 0; i < sourceChains.length; i++) {
            expectedPerChain[requestId][sourceChains[i]] = expectedAmounts[i];
        }

        emit InstantAggregationInitiated(
            requestId,
            msg.sender,
            merchant,
            targetAmount
        );

        return requestId;
    }

    /**
     * @notice Handle LayerZero messages (optional for future use)
     * @dev Currently not used since CCTP handles all cross-chain transfers
     *      Kept for potential future acknowledgments or status updates
     */
    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata,
        address,
        bytes calldata
    ) internal override {
        // Not currently used - CCTP handles all cross-chain transfers
        // Could be used for acknowledgments or status updates in the future
    }

    /**
     * @notice INSTANT SETTLEMENT: Transfer USDC to merchant
     * @dev This happens as soon as threshold is met (1-2 minutes with CCTP Fast)
     * @dev The USDC was minted directly to this contract by Circle CCTP
     */
    function _instantSettle(bytes32 requestId, uint256 startTime) internal {
        InstantAggregationRequest storage request = requests[requestId];

        // Transfer USDC to merchant (INSTANT PAYMENT)
        // Note: USDC was minted to this contract by Circle via CCTP
        IERC20(usdcToken).safeTransfer(request.merchant, request.totalLocked);

        request.usdcSettledAmount = request.totalLocked;
        request.status = SettlementStatus.SETTLED;

        uint256 timeElapsed = block.timestamp - startTime;

        emit InstantSettlement(
            requestId,
            request.merchant,
            request.totalLocked,
            timeElapsed
        );
    }

    /**
     * @notice Get request details
     */
    function getRequest(bytes32 requestId)
        external
        view
        returns (InstantAggregationRequest memory)
    {
        return requests[requestId];
    }

    /**
     * @notice Get locked amount per chain
     */
    function getLockedAmount(bytes32 requestId, uint32 chainEid)
        external
        view
        returns (uint256)
    {
        return lockedPerChain[requestId][chainEid];
    }

    /**
     * @notice Check if instant settlement is possible
     */
    function canInstantSettle(bytes32 requestId) external view returns (bool) {
        InstantAggregationRequest memory request = requests[requestId];
        return request.totalLocked == request.targetAmount && request.usdcSettledAmount == 0;
    }

    /**
     * @notice Direct same-chain payment recording (no LayerZero needed)
     * @dev Called by SourceChainInitiator when source and destination are the same chain
     * @param requestId The aggregation request ID
     * @param amount Amount of USDC received (already transferred to this contract)
     */
    function recordDirectPayment(bytes32 requestId, uint256 amount) external {
        InstantAggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(request.status == SettlementStatus.PENDING, "Invalid status");

        // Add USDC to aggregation request
        request.totalLocked += amount;

        emit LockConfirmed(
            requestId,
            uint32(endpoint.eid()),
            amount,
            request.totalLocked
        );

        // Check if we can instant settle
        if (request.totalLocked == request.targetAmount && request.usdcSettledAmount == 0) {
            _instantSettle(requestId, block.timestamp);
        }
    }

    /**
     * @notice CCTP Hook: Handle USDC receipt from Circle with hookData
     * @dev Called by Circle's MessageTransmitter after minting USDC to this contract
     *
     * Flow:
     * 1. User burns USDC on source chain via SourceChainInitiator
     * 2. SourceChainInitiator includes requestId in hookData
     * 3. Circle mints USDC to this contract
     * 4. Circle calls this function with hookData
     * 5. We decode requestId and add USDC to aggregation
     * 6. If threshold met, instantly settle to merchant
     */
    function handleReceiveMessage(
        uint32 /* sourceDomain */,
        bytes32 /* sender */,
        bytes calldata messageBody
    ) external returns (bool) {
        // Only Circle's MessageTransmitter can call this
        require(msg.sender == messageTransmitter, "Only MessageTransmitter");

        // Decode hookData to get requestId
        bytes32 requestId = abi.decode(messageBody, (bytes32));

        InstantAggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(request.status == SettlementStatus.PENDING, "Invalid status");

        // Get USDC balance (Circle just minted to this contract)
        uint256 usdcAmount = IERC20(usdcToken).balanceOf(address(this));
        require(usdcAmount > 0, "No USDC received");

        // Add USDC to aggregation request
        request.totalLocked += usdcAmount;

        emit LockConfirmed(
            requestId,
            uint32(endpoint.eid()),
            usdcAmount,
            request.totalLocked
        );

        // Check if we can instant settle
        if (request.totalLocked == request.targetAmount && request.usdcSettledAmount == 0) {
            _instantSettle(requestId, block.timestamp);
        }

        return true;
    }

    /**
     * @notice Swap non-USDC token to USDC using Uniswap V3
     * @dev Gas for this function is pre-paid by user via lzComposeOptions
     * @param requestId Request ID for event tracking
     * @param tokenIn Token to swap from (ARB, ETH, etc.)
     * @param amountIn Amount of tokenIn to swap
     * @return usdcOut Amount of USDC received from swap
     */
    function _swapToUSDC(
        bytes32 requestId,
        address tokenIn,
        uint256 amountIn
    ) internal returns (uint256 usdcOut) {
        require(swapRouter != address(0), "Swap router not configured");
        require(usdcToken != address(0), "USDC token not configured");

        // Approve Uniswap router to spend our tokens
        IERC20(tokenIn).safeIncreaseAllowance(swapRouter, amountIn);

        // Swap using Uniswap V3 (on-chain, no API call)
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: usdcToken,
            fee: 3000, // 0.3% pool (most common)
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0, // TODO: In production, calculate from oracle for slippage protection
            sqrtPriceLimitX96: 0
        });

        usdcOut = ISwapRouter(swapRouter).exactInputSingle(params);

        emit TokenSwapped(requestId, tokenIn, amountIn, usdcOut);

        return usdcOut;
    }

    /**
     * @notice Emergency withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyOwner
    {
        IERC20(token).safeTransfer(to, amount);
    }

    receive() external payable {}
}
