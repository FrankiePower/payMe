// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,        // EVM addr left-padded to 32 bytes
        address burnToken,            // USDC on source chain
        bytes32 destinationCaller,    // optional hook executor (can be zero)
        uint256 maxFee,               // fast transfer fee ceiling
        uint32  minFinalityThreshold, // e.g. 2000 (standard) / 1000 (fast)
        bytes calldata hookData       // optional metadata for hooks
    ) external returns (bytes32 messageHash);
}

library AddrCast {
    function toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

/**
 * @title CctpBridger
 * @notice Wrapper contract for Circle CCTP v2 depositForBurnWithHook
 * @dev Used by SourceChainInitiator to bridge USDC to InstantAggregator with hook data
 */
contract CctpBridger {
    using AddrCast for address;

    ITokenMessengerV2 public immutable messenger;
    address public immutable usdc;

    constructor(address _messenger, address _usdc) {
        messenger = ITokenMessengerV2(_messenger);
        usdc = _usdc;
    }

    /// @notice Bridge USDC via CCTP v2 with hook data
    /// @param amount Amount of USDC to bridge
    /// @param destDomain Circle CCTP destination domain ID
    /// @param destMintRecipient Address to receive minted USDC (InstantAggregator)
    /// @param destCaller Address that can call the hook (InstantAggregator)
    /// @param maxFee Maximum fee for fast finality (0 for standard)
    /// @param minFinalityThreshold Finality threshold (2000=standard, 1000=fast)
    /// @param hookData Custom data for hook (requestId)
    /// @return messageHash CCTP message hash
    function bridgeUSDCV2(
        uint256 amount,
        uint32  destDomain,
        address destMintRecipient,
        address destCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold,
        bytes calldata hookData
    ) external returns (bytes32) {
        // Pull USDC from caller (SourceChainInitiator)
        require(
            IERC20(usdc).transferFrom(msg.sender, address(this), amount),
            "USDC transfer failed"
        );

        // Approve Circle's TokenMessenger
        IERC20(usdc).approve(address(messenger), amount);

        // Burn USDC on source, Circle will mint on dest and call hook
        return messenger.depositForBurnWithHook(
            amount,
            destDomain,
            destMintRecipient.toBytes32(),
            usdc,
            destCaller.toBytes32(),
            maxFee,
            minFinalityThreshold,
            hookData
        );
    }
}
