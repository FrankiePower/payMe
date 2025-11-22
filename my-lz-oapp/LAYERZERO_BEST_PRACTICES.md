# LayerZero Best Practices - Implementation Guide

## What We Learned from LayerZero Examples

After studying the official LayerZero contracts, here are the critical insights for our payment aggregation system:

---

## 1. OFT vs OFTAdapter: CRITICAL CHOICE

### OFT.sol - Burn & Mint Pattern
**Use when:** Creating a NEW cross-chain token
- Burns tokens on source chain
- Mints tokens on destination chain
- Total supply changes per chain

### OFTAdapter.sol - Lock & Unlock Pattern
**Use when:** Wrapping EXISTING tokens (like USDC!)
- Locks tokens on source chain in adapter contract
- Unlocks from pool on destination chain
- Total supply stays constant globally

**⚠️ CRITICAL WARNING from OFTAdapter.sol lines 14-15:**
> "ONLY 1 of these should exist for a given global mesh"

### Our Implementation Strategy:

```solidity
// Deploy USDCOFTAdapter on chains with native USDC
contract USDCOFTAdapter is OFTAdapter {
    constructor(
        address _usdc,  // Native USDC address
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_usdc, _lzEndpoint, _owner) {}
}
```

**Deploy on:**
- Ethereum: USDC at 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
- Arbitrum: USDC at 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
- Base: USDC at 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
- Optimism: USDC at 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85
- Polygon: USDC at 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359

---

## 2. Decimal Conversion: MUST HANDLE

### The Problem:
Tokens have different decimals on different chains. LayerZero uses **6 shared decimals** for all cross-chain transfers.

### From OFTCore.sol (lines 25-38):
```solidity
// Example: Token with 18 decimals locally, 6 shared
// Local: 1.234567890123456789 => 1234567890123456789 (18 decimals)
// Shared: 1.234567 => 1234567 (6 decimals)
// Conversion rate: 10 ** (18 - 6) = 1e12

uint256 public immutable decimalConversionRate;

constructor(uint8 _localDecimals) {
    decimalConversionRate = 10 ** (_localDecimals - sharedDecimals());
}

function sharedDecimals() public pure returns (uint8) {
    return 6;  // Always 6 for cross-chain
}
```

### Add to Our Contracts:
```solidity
// Convert from local (18 decimals) to shared (6 decimals)
function _toSharedDecimals(uint256 _amountLD) internal pure returns (uint64) {
    uint256 _amountSD = _amountLD / 1e12;  // 18 - 6 = 12
    require(_amountSD <= type(uint64).max, "Amount overflow");
    return uint64(_amountSD);
}

// Convert from shared (6 decimals) to local (18 decimals)
function _toLocalDecimals(uint64 _amountSD) internal pure returns (uint256) {
    return uint256(_amountSD) * 1e12;
}

// Remove dust (fractional amounts < 1e-6)
function _removeDust(uint256 _amountLD) internal pure returns (uint256) {
    return (_amountLD / 1e12) * 1e12;
}
```

---

## 3. Compose Message Format: USE STANDARD

### From OFTComposeMsgCodec.sol:
```
Message Structure (bytes):
├─ [0-7]    nonce (uint64)
├─ [8-11]   srcEid (uint32)
├─ [12-43]  amountLD (uint256)
├─ [44-75]  composeFrom (bytes32)
└─ [76+]    composeMsg (your custom data)
```

### Encoding:
```solidity
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

// Build compose message
bytes memory customData = abi.encode(merchantId, payer);
bytes memory fullComposeMsg = abi.encodePacked(
    bytes32(uint256(uint160(msg.sender))),  // composeFrom
    customData
);
```

### Decoding in lzCompose:
```solidity
function lzCompose(
    address _oApp,
    bytes32 _guid,
    bytes calldata _message,
    address,
    bytes calldata
) external payable override {
    // Use OFTComposeMsgCodec helpers
    uint64 nonce = OFTComposeMsgCodec.nonce(_message);
    uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
    uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
    bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(_message);
    bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

    // Decode YOUR custom data
    (bytes32 merchantId, address payer) = abi.decode(composeMsg, (bytes32, address));
}
```

---

## 4. Horizontal Composability: CORRECT PATTERN

### From OFTCore.sol _lzReceive (lines 266-297):

**The RIGHT way:**
```solidity
function _lzReceive(
    Origin calldata _origin,
    bytes32 _guid,
    bytes calldata _message,
    address,
    bytes calldata
) internal override {
    // STEP 1 (CRITICAL): Credit tokens first
    address toAddress = _message.sendTo().bytes32ToAddress();
    uint256 amountReceived = _credit(toAddress, _toLD(_message.amountSD()), _origin.srcEid);

    emit OFTReceived(_guid, _origin.srcEid, toAddress, amountReceived);

    // STEP 2 (NON-CRITICAL): If composed, send to composer
    if (_message.isComposed()) {
        bytes memory composeMsg = OFTComposeMsgCodec.encode(
            _origin.nonce,
            _origin.srcEid,
            amountReceived,
            _message.composeMsg()
        );

        // LayerZero endpoint calls sendCompose, not you!
        endpoint.sendCompose(toAddress, _guid, 0, composeMsg);
    }
}
```

**⚠️ Our InstantAggregator Mistake (line 239):**
```solidity
// WRONG - Don't call endpoint.sendCompose directly!
endpoint.sendCompose(backgroundResolver, _guid, 0, composerMsg);

// RIGHT - Include compose data in OFT send, endpoint handles the rest
SendParam memory sendParam = SendParam({
    composeMsg: fullComposeMsg,  // This triggers sendCompose automatically
    ...
});
```

---

## 5. lzRead Map-Reduce: PROPER IMPLEMENTATION

### From IOAppMapper.sol & IOAppReducer.sol:

```solidity
contract UserBalanceScanner is OApp, OAppRead, IOAppMapper, IOAppReducer {
    // Track requests
    mapping(bytes32 => ScanRequest) public scanRequests;

    constructor(address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        OAppRead(_endpoint, _owner) {}

    // Enable read channels
    function enableReadChannel(uint32 chainEid) external onlyOwner {
        setReadChannel(chainEid, true);  // From OAppRead
    }

    // Initiate scan
    function scanBalances(
        address user,
        uint32[] calldata chainEids
    ) external payable returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(user, chainEids, block.timestamp));

        // Store request
        scanRequests[requestId] = ScanRequest({user, chainEids, ...});

        // Encode command with request ID
        bytes memory cmd = abi.encode(requestId, user);

        // Call lzRead (triggers map-reduce)
        _lzRead(chainEids, channelIds, cmd, options);

        return requestId;
    }

    // Map phase: Process individual chain response
    function lzMap(bytes calldata cmd, bytes calldata response)
        external
        view
        override
        returns (bytes memory)
    {
        (bytes32 requestId, address user) = abi.decode(cmd, (bytes32, address));
        uint256 balance = abi.decode(response, (uint256));

        return abi.encode(requestId, balance);
    }

    // Reduce phase: Aggregate all responses
    function lzReduce(bytes calldata cmd, bytes[] calldata responses)
        external
        view
        override
        returns (bytes memory)
    {
        (bytes32 requestId, address user) = abi.decode(cmd, (bytes32, address));

        uint256[] memory balances = new uint256[](responses.length);
        uint256 total = 0;

        for (uint i = 0; i < responses.length; i++) {
            (, uint256 balance) = abi.decode(responses[i], (bytes32, uint256));
            balances[i] = balance;
            total += balance;
        }

        return abi.encode(requestId, user, balances, total);
    }

    // Final callback with aggregated results
    function _lzReadResponse(bytes calldata response) internal override {
        (bytes32 requestId, address user, uint256[] memory balances, uint256 total) =
            abi.decode(response, (bytes32, address, uint256[], uint256));

        ScanRequest storage req = scanRequests[requestId];
        require(req.user == user, "Invalid user");

        emit BalancesScanned(user, balances, total);
    }
}
```

---

## 6. Message Types: SEND vs SEND_AND_CALL

### From OFTCore.sol (lines 43-44):
```solidity
uint16 public constant SEND = 1;          // Simple transfer
uint16 public constant SEND_AND_CALL = 2; // Transfer with compose
```

### When to Use Each:

**SEND (Type 1):**
- Simple cross-chain transfer
- No additional logic needed
- Just moves tokens A → B

**SEND_AND_CALL (Type 2):**
- Transfer + trigger additional logic
- Uses horizontal composability
- Enables our instant settlement pattern!

**How It's Determined (OFTCore.sol line 244):**
```solidity
function _buildMsgAndOptions(SendParam calldata _sendParam)
    internal view returns (bytes memory message, bytes memory options)
{
    bool hasCompose;
    (message, hasCompose) = OFTMsgCodec.encode(
        _sendParam.to,
        _toSD(_sendParam.amountLD),
        _sendParam.composeMsg  // If not empty, hasCompose = true
    );

    uint16 msgType = hasCompose ? SEND_AND_CALL : SEND;
    options = combineOptions(_sendParam.dstEid, msgType, _sendParam.extraOptions);
}
```

**For Our InstantAggregator:**
```solidity
// Include compose message to trigger SEND_AND_CALL
SendParam memory sendParam = SendParam({
    dstEid: destinationEid,
    to: bytes32(uint256(uint160(merchant))),
    amountLD: amount,
    minAmountLD: amount,
    extraOptions: options,
    composeMsg: abi.encodePacked(
        bytes32(uint256(uint160(address(this)))),
        abi.encode(requestId, user)
    ),  // Non-empty = SEND_AND_CALL
    oftCmd: ""
});
```

---

## 7. Critical Fixes for Our Contracts

### InstantAggregator.sol

**Issue 1: Line 259 - Manual Transfer**
```solidity
// CURRENT (WRONG)
oftToken.safeTransfer(request.merchant, request.totalLocked);

// FIX
if (request.destinationChain == endpoint.eid()) {
    // Same chain - direct transfer OK
    oftToken.safeTransfer(request.merchant, request.totalLocked);
} else {
    // Cross-chain - use OFT send()
    _sendOFTCrossChain(request.merchant, request.totalLocked, request.destinationChain);
}
```

**Issue 2: Line 239 - Manual sendCompose**
```solidity
// CURRENT (WRONG)
endpoint.sendCompose(backgroundResolver, _guid, 0, composerMsg);

// FIX - Remove this line entirely
// Compose happens automatically when you include composeMsg in SendParam
```

**Issue 3: Missing Decimal Conversion**
```solidity
// ADD these helpers
function _toSharedDecimals(uint256 _amountLD) internal pure returns (uint64) {
    uint256 _amountSD = _amountLD / 1e12;
    require(_amountSD <= type(uint64).max, "Overflow");
    return uint64(_amountSD);
}

function _toLocalDecimals(uint64 _amountSD) internal pure returns (uint256) {
    return uint256(_amountSD) * 1e12;
}
```

### PaymentComposerOFT.sol

**Issue: Line 180 - Wrong Decoding**
```solidity
// CURRENT (WRONG)
(uint64 nonce, uint32 srcEid, bytes32 merchantId, ...) =
    abi.decode(_message, (...));

// FIX - Use OFTComposeMsgCodec
uint64 nonce = OFTComposeMsgCodec.nonce(_message);
uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

// Then decode YOUR custom data
(bytes32 merchantId, address payer) = abi.decode(composeMsg, (bytes32, address));
```

### UserBalanceScanner.sol

**Issue: Missing OAppRead**
```solidity
// CURRENT (WRONG)
contract UserBalanceScanner is OApp {

// FIX
import { OAppRead } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import { IOAppMapper } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppMapper.sol";
import { IOAppReducer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppReducer.sol";

contract UserBalanceScanner is OApp, OAppRead, IOAppMapper, IOAppReducer {
    constructor(address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        OAppRead(_endpoint, _owner) {}
}
```

---

## 8. New Contract: USDCOFTAdapter

**Create this for production:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";

/**
 * @title USDCOFTAdapter
 * @notice ONE adapter for USDC across ALL chains
 * @dev Deploy on each chain with native USDC
 */
contract USDCOFTAdapter is OFTAdapter {
    constructor(
        address _usdc,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_usdc, _lzEndpoint, _owner) {
        require(IERC20Metadata(_usdc).decimals() == 6, "USDC must be 6 decimals");
    }

    // Override for safety (handle fee-on-transfer variants)
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        uint256 balBefore = innerToken.balanceOf(address(this));
        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
        uint256 balAfter = innerToken.balanceOf(address(this));

        uint256 actualReceived = balAfter - balBefore;
        require(actualReceived >= amountSentLD, "Fee detected");

        return (actualReceived, amountReceivedLD);
    }
}
```

---

## Summary: Critical Actions

### 1. Use OFTAdapter for USDC ✅
- Deploy USDCOFTAdapter on chains with native USDC
- ONE adapter per chain, globally coordinated

### 2. Fix Decimal Handling ✅
- Add `_toSharedDecimals()` and `_toLocalDecimals()`
- Always convert to 6 decimals for cross-chain
- Remove dust before sending

### 3. Use OFTComposeMsgCodec ✅
- Import the codec library
- Use helper functions for encoding/decoding
- Never manually call `endpoint.sendCompose()`

### 4. Fix UserBalanceScanner ✅
- Extend OAppRead properly
- Implement IOAppMapper and IOAppReducer
- Track requests with IDs

### 5. Horizontal Composability ✅
- Include composeMsg in SendParam (not manual sendCompose)
- Let endpoint handle the compose call
- Decode using OFTComposeMsgCodec in lzCompose

---

## Testing Checklist

Before deploying:

- [ ] Test decimal conversion (18 → 6 → 18)
- [ ] Test OFTAdapter lock/unlock
- [ ] Test compose message encoding/decoding
- [ ] Test lzRead map-reduce flow
- [ ] Test horizontal composability
- [ ] Verify ONE adapter per token rule
- [ ] Test cross-chain with actual LayerZero testnet

---

This guide is based on actual LayerZero production contracts. Follow it precisely to avoid bugs! 🚀
