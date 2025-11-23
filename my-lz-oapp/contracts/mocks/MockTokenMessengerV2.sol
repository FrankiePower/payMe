// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold,
        bytes calldata hookData
    ) external returns (bytes32 messageHash);
}

contract MockTokenMessengerV2 is ITokenMessengerV2 {
    struct LastCall {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32  minFinalityThreshold;
        bytes   hookData;
        address caller;
    }

    LastCall private _lastCall;

    function last() external view returns (
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes memory hookData,
        address caller
    ) {
        return (
            _lastCall.amount,
            _lastCall.destinationDomain,
            _lastCall.mintRecipient,
            _lastCall.burnToken,
            _lastCall.destinationCaller,
            _lastCall.maxFee,
            _lastCall.minFinalityThreshold,
            _lastCall.hookData,
            _lastCall.caller
        );
    }
    bytes32 private _nextHash;

    constructor() {
        _nextHash = keccak256("mock-cctp");
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold,
        bytes calldata hookData
    ) external returns (bytes32 messageHash) {
        _lastCall = LastCall({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken,
            destinationCaller: destinationCaller,
            maxFee: maxFee,
            minFinalityThreshold: minFinalityThreshold,
            hookData: hookData,
            caller: msg.sender
        });
        messageHash = _nextHash;
        _nextHash = keccak256(abi.encode(_nextHash, block.timestamp));
    }
}
