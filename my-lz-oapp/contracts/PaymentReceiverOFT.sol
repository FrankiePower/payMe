// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MerchantRegistry } from "./MerchantRegistry.sol";

/**
 * @title PaymentReceiverOFT
 * @notice OFT-based payment receiver with horizontal composability for cross-chain merchant payments
 * @dev Extends LayerZero OFT standard to enable:
 *      1. Cross-chain USDC payments via OFT bridging
 *      2. Horizontal composability for optimal routing
 *      3. Direct integration with PaymentComposer for CCTP settlement
 *
 * Innovation: Hybrid OFT + CCTP routing based on merchant preferences
 */
contract PaymentReceiverOFT is OFT {
    using OFTMsgCodec for bytes;
    using OFTComposeMsgCodec for bytes;

    /// @notice Merchant registry contract
    MerchantRegistry public immutable merchantRegistry;

    /// @notice Address of the PaymentComposer contract on this chain
    address public paymentComposer;

    /// @notice Emitted when a payment is received via OFT (Step 1 - lzReceive)
    event PaymentReceived(
        bytes32 indexed merchantId,
        address indexed payer,
        uint256 amount,
        uint32 sourceChain,
        bytes32 guid
    );

    /// @notice Emitted when a composed message is sent for optimal routing (Step 2 - sendCompose)
    event ComposedForRouting(
        bytes32 indexed merchantId,
        uint256 amount,
        bytes32 guid
    );

    /**
     * @notice Constructor
     * @param _name OFT token name (e.g., "PayMe USDC")
     * @param _symbol OFT token symbol (e.g., "pUSDC")
     * @param _endpoint LayerZero endpoint address
     * @param _owner Contract owner
     * @param _merchantRegistry Merchant registry contract address
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _owner,
        address _merchantRegistry
    ) OFT(_name, _symbol, _endpoint, _owner) Ownable(_owner) {
        merchantRegistry = MerchantRegistry(_merchantRegistry);
    }

    /**
     * @notice Set the PaymentComposer contract address
     * @param _composer Address of PaymentComposer contract
     */
    function setPaymentComposer(address _composer) external onlyOwner {
        require(_composer != address(0), "Invalid composer address");
        paymentComposer = _composer;
    }

    /**
     * @notice Build SendParam for merchant payment
     * @param merchantId Merchant identifier (bytes32 from address or ENS)
     * @param amount OFT amount to send (in token decimals)
     * @param dstEid Destination chain endpoint ID where merchant receives payment
     * @param extraOptions LayerZero execution options (must include compose options)
     * @return sendParam The SendParam struct to use with OFT.send()
     *
     * @dev This function builds the SendParam with merchant-specific logic
     *      The composeMsg encodes merchantId for PaymentComposer to process
     *      Users should call this, then call the inherited send() function
     */
    function buildMerchantPaymentParam(
        bytes32 merchantId,
        uint256 amount,
        uint32 dstEid,
        bytes calldata extraOptions
    ) external view returns (SendParam memory sendParam) {
        require(merchantRegistry.isMerchantActive(merchantId), "Merchant not active");
        require(amount > 0, "Amount must be > 0");

        // Get merchant's default receiver on destination chain
        (address merchantWallet, ) = merchantRegistry.getDefaultReceiver(merchantId);

        // Encode merchant ID in composeMsg for PaymentComposer
        bytes memory composeMsg = abi.encode(merchantId, msg.sender);

        // Create SendParam for OFT
        sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(merchantWallet))), // Merchant wallet as bytes32
            amountLD: amount,
            minAmountLD: (amount * 95) / 100, // 5% slippage tolerance
            extraOptions: extraOptions,
            composeMsg: composeMsg, // Will trigger lzCompose on destination
            oftCmd: "" // No custom OFT command
        });

        return sendParam;
    }

    /**
     * @notice STEP 1 (CRITICAL): Receive OFT payment via LayerZero
     * @dev Overrides OFT._lzReceive to add horizontal composability
     *      This ensures payment is ALWAYS received even if composer fails
     *
     * Flow:
     * 1. OFT mints tokens to recipient (handled by parent OFT contract)
     * 2. Extract merchant data from composed message
     * 3. Emit PaymentReceived event (payment is SAFE)
     * 4. Call endpoint.sendCompose() to trigger PaymentComposer (non-critical)
     *
     * @param _origin Message origin information
     * @param _guid Global unique identifier for this message
     * @param _message Encoded OFT message containing amount and composeMsg
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        // Call parent OFT logic first (mints tokens to recipient)
        super._lzReceive(_origin, _guid, _message, _executor, _extraData);

        // Check if message contains composed data
        if (_message.isComposed()) {
            _handleComposedMessage(_origin, _guid, _message);
        }
    }

    /**
     * @notice Handle composed message for merchant payments
     * @dev Extracted to separate function to avoid stack too deep
     */
    function _handleComposedMessage(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message
    ) internal {
        // Get the recipient address from the OFT message
        address recipient = OFTMsgCodec.bytes32ToAddress(_message.sendTo());

        // Get the composed message from the OFT message
        bytes memory oftComposeMsg = OFTMsgCodec.composeMsg(_message);

        // The compose message format from OFT is: [nonce][srcEid][amountLD][composeFrom][actualComposeMsg]
        // Extract our actual compose message (skip first 76 bytes)
        bytes memory actualComposeMsg = _extractActualComposeMsg(oftComposeMsg);

        // Decode our merchant data (merchantId + payer)
        (bytes32 merchantId, address payer) = abi.decode(actualComposeMsg, (bytes32, address));

        // TODO: Extract actual amount from compose message or track balance change
        uint256 amountReceived = 0;

        // STEP 1 COMPLETE: Emit payment received (CRITICAL - SAFE)
        emit PaymentReceived(merchantId, payer, amountReceived, _origin.srcEid, _guid);

        // STEP 2: Horizontal Composability - Send to PaymentComposer (NON-CRITICAL)
        if (paymentComposer != address(0)) {
            bytes memory composerMsg = abi.encode(
                _origin.nonce,
                _origin.srcEid,
                merchantId,
                amountReceived,
                payer,
                recipient
            );

            endpoint.sendCompose(paymentComposer, _guid, 0, composerMsg);
            emit ComposedForRouting(merchantId, amountReceived, _guid);
        }
    }

    /**
     * @notice Extract actual compose message from OFT compose message
     * @dev Skip first 76 bytes (nonce 8 + srcEid 4 + amountLD 32 + composeFrom 32)
     */
    function _extractActualComposeMsg(bytes memory oftComposeMsg) internal pure returns (bytes memory) {
        if (oftComposeMsg.length > 76) {
            bytes memory actualComposeMsg = new bytes(oftComposeMsg.length - 76);
            for (uint i = 76; i < oftComposeMsg.length; i++) {
                actualComposeMsg[i - 76] = oftComposeMsg[i];
            }
            return actualComposeMsg;
        }
        return oftComposeMsg;
    }

    /**
     * @notice Quote the messaging fee for cross-chain payment
     * @dev Users should first call buildMerchantPaymentParam() to get the SendParam,
     *      then call the inherited quoteSend(sendParam, payInLzToken) function
     */

    /**
     * @notice Local payment function - transfers OFT tokens on same chain
     * @param merchantId Merchant identifier
     * @param amount OFT amount to transfer
     * @dev For same-chain payments, we just transfer OFT tokens directly
     *      No LayerZero messaging needed, but can still trigger composer for routing
     */
    function payMerchantLocal(bytes32 merchantId, uint256 amount) external {
        require(merchantRegistry.isMerchantActive(merchantId), "Merchant not active");
        require(amount > 0, "Amount must be > 0");

        // Get merchant's default wallet on this chain
        (address merchantWallet, ) = merchantRegistry.getDefaultReceiver(merchantId);

        // Transfer OFT tokens from payer to merchant
        _transfer(msg.sender, merchantWallet, amount);

        // Emit payment received
        emit PaymentReceived(
            merchantId,
            msg.sender,
            amount,
            uint32(endpoint.eid()),
            bytes32(0) // No GUID for local transfers
        );
    }

    /**
     * @notice Emergency withdraw function for OFT tokens
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        _transfer(address(this), to, amount);
    }
}
