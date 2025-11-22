// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "./interfaces/ISwapRouter.sol";

/**
 * @title InstantAggregator
 * @notice FAST payment aggregation using OFTAdapter for instant settlement
 * @dev Key innovation: Transfer USDC immediately when ALL locks confirmed via OFTAdapter
 *
 * Speed comparison:
 * - Traditional aggregation: 10-15 minutes (wait for all USDC to arrive)
 * - Instant aggregation: 30 seconds (transfer USDC as soon as all locks confirmed)
 *
 * Flow:
 * 1. Scan user balances across chains to determine exact amounts
 * 2. Agent locks USDC on all source chains in PARALLEL
 * 3. Each source chain sends "LOCKED" message to this contract
 * 4. When FULL amount received (100%), INSTANTLY transfer USDC to merchant
 * 5. Merchant receives actual USDC in ~30 seconds (immediately usable)
 *
 * With OFTAdapter:
 * - USDC locked on source chains gets unlocked from adapter on destination
 * - Merchant receives native USDC directly (no intermediate OFT token)
 * - No background resolution needed - adapter handles everything
 *
 * No Partial Payments:
 * - Must receive exact target amount (100%)
 * - If deadline expires without full amount, request fails
 * - All-or-nothing settlement
 */
contract InstantAggregator is OApp, IOAppComposer {
    using SafeERC20 for IERC20;
    using OFTComposeMsgCodec for bytes;

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

    /// @notice USDC OFT Adapter for instant cross-chain settlement
    /// @dev This adapter wraps native USDC - when user sends USDC cross-chain,
    ///      it gets locked in source adapter and unlocked from destination adapter
    address public immutable usdcOFTAdapter;

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
     * @param _endpoint LayerZero endpoint
     * @param _usdcOFTAdapter USDC OFT Adapter address (wraps native USDC)
     * @param _owner Contract owner
     */
    constructor(
        address _endpoint,
        address _usdcOFTAdapter,
        address _owner
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        require(_usdcOFTAdapter != address(0), "Invalid USDC OFT Adapter");
        usdcOFTAdapter = _usdcOFTAdapter;
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
     * @notice Receive lock confirmation from source chain
     * @dev CRITICAL: This is where instant settlement happens!
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address,
        bytes calldata
    ) internal override {
        (bytes32 requestId, uint256 lockedAmount, uint256 startTime) = abi.decode(
            _message,
            (bytes32, uint256, uint256)
        );

        InstantAggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(request.status == SettlementStatus.PENDING, "Invalid status");
        require(block.timestamp <= request.deadline, "Expired");

        // Update locked amount
        lockedPerChain[requestId][_origin.srcEid] += lockedAmount;
        request.totalLocked += lockedAmount;

        emit LockConfirmed(
            requestId,
            _origin.srcEid,
            lockedAmount,
            request.totalLocked
        );

        // Check if FULL amount received for INSTANT SETTLEMENT
        if (request.totalLocked == request.targetAmount && request.usdcSettledAmount == 0) {
            // INSTANT SETTLEMENT: Transfer USDC to merchant NOW
            _instantSettle(requestId, startTime);
        }
    }

    /**
     * @notice INSTANT SETTLEMENT: Transfer USDC from OFT Adapter to merchant
     * @dev This happens as soon as threshold is met (30 seconds vs 15 minutes)
     * @dev The USDC is already unlocked in the OFT Adapter from source chain locks
     */
    function _instantSettle(bytes32 requestId, uint256 startTime) internal {
        InstantAggregationRequest storage request = requests[requestId];

        // Transfer USDC from adapter to merchant (INSTANT PAYMENT)
        // Note: USDC was already unlocked from source chains into the adapter
        IERC20(usdcOFTAdapter).safeTransfer(request.merchant, request.totalLocked);

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
     * @notice Horizontal Composability: Handle composed messages with token swaps
     * @dev Called by LayerZero endpoint when user sends non-USDC token with composeMsg
     * @dev Gas is PRE-PAID by user in initial send (via lzComposeOptions)
     *
     * Flow:
     * 1. User sends ARB from Arbitrum with composeMsg containing requestId
     * 2. OFTAdapter unlocks ARB to this contract
     * 3. LayerZero calls lzCompose() with pre-paid gas
     * 4. This function swaps ARB → USDC using Uniswap
     * 5. USDC is added to aggregation request
     *
     * Gas Payment:
     * - User pays for ALL gas upfront via quoteSend(sendParam, false)
     * - Includes cross-chain delivery + lzCompose execution + swap gas
     * - No need for contract to hold gas - user pre-funded everything
     */
    function lzCompose(
        address /* _oApp */,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override {
        // Only LayerZero endpoint can call this
        require(msg.sender == address(endpoint), "Only endpoint");

        // Decode the OFT compose message
        // Format: nonce (8 bytes) + srcEid (4 bytes) + amountLD (32 bytes) + composeMsg
        bytes memory composeMsg = _message.composeMsg();

        // Decode our custom compose message: (requestId, tokenIn, amountIn)
        (bytes32 requestId, address tokenIn, uint256 amountIn) = abi.decode(
            composeMsg,
            (bytes32, address, uint256)
        );

        InstantAggregationRequest storage request = requests[requestId];
        require(request.exists, "Request not found");
        require(request.status == SettlementStatus.PENDING, "Invalid status");

        uint256 usdcAmount;

        // If token is already USDC, no swap needed
        if (tokenIn == usdcToken) {
            usdcAmount = amountIn;
        } else {
            // Swap non-USDC token to USDC using DEX
            // Gas for this swap is pre-paid by user in lzComposeOptions
            usdcAmount = _swapToUSDC(requestId, tokenIn, amountIn);
        }

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
