// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IMessageTransmitter
 * @notice Circle CCTP MessageTransmitter interface
 * @dev Used for receiving and verifying attestations on destination chain
 */
interface IMessageTransmitter {
    /**
     * @notice Receive a message and attestation from Circle's attestation service
     * @param message Circle message bytes
     * @param attestation Attestation signature from Circle
     * @return success Whether the message was successfully received
     */
    function receiveMessage(bytes calldata message, bytes calldata attestation)
        external
        returns (bool success);

    /**
     * @notice Replace a message with a new message body
     * @param originalMessage Original Circle message
     * @param originalAttestation Original attestation
     * @param newMessageBody New message body to replace
     * @param newDestinationCaller New destination caller (optional)
     */
    function replaceMessage(
        bytes calldata originalMessage,
        bytes calldata originalAttestation,
        bytes calldata newMessageBody,
        bytes32 newDestinationCaller
    ) external;
}
