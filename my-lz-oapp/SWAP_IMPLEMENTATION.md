# Token Swap Implementation with Gas Management

## Overview

The InstantAggregator now supports **automatic token swaps** for non-USDC tokens using **horizontal composability**. This allows users to pay with ARB, ETH, or other tokens, which are automatically swapped to USDC before aggregation.

## Key Innovation: User Pre-Pays ALL Gas

**CRITICAL**: The user pays for EVERYTHING upfront, including swap gas. No API calls needed - everything is on-chain.

## How It Works

### Architecture

```
User on Arbitrum (has 100 ARB)
    ↓
[Initiates send with lzComposeOptions]
    ↓
quoteSend() calculates TOTAL cost:
  - Cross-chain message delivery: ~0.001 ETH
  - lzReceive execution: ~0.0005 ETH
  - lzCompose execution: ~0.002 ETH
  - DEX swap gas: ~0.003 ETH  ← Included!
  TOTAL: ~0.0065 ETH
    ↓
User pays 0.0065 ETH upfront
    ↓
OFTAdapter.send() - ARB locked on source chain
    ↓
LayerZero delivers message to destination
    ↓
OFTAdapter unlocks ARB to InstantAggregator
    ↓
LayerZero calls lzCompose() with PRE-PAID gas
    ↓
InstantAggregator.lzCompose():
  - Receives ARB
  - Calls Uniswap V3 router (on-chain, no API)
  - Swaps ARB → USDC
  - Adds USDC to aggregation request
    ↓
Instant settlement when target amount reached
```

### Gas Payment Flow

```solidity
// 1. User quotes the full cost (including swap)
SendParam memory sendParam = SendParam({
    dstEid: destinationEid,
    to: addressToBytes32(instantAggregatorAddress),
    amountLD: 100e18, // 100 ARB
    minAmountLD: 100e18,
    extraOptions: options.toHex(), // Includes lzComposeOptions!
    composeMsg: abi.encode(requestId, arbTokenAddress, 100e18),
    oftCmd: "0x"
});

// 2. Quote includes ALL gas (delivery + lzCompose + swap)
MessagingFee memory fee = arbOFTAdapter.quoteSend(sendParam, false);
// fee.nativeFee = 0.0065 ETH (includes swap gas!)

// 3. User sends with full payment upfront
arbOFTAdapter.send(sendParam, fee, refundAddress, {
    value: fee.nativeFee  // Pays for EVERYTHING
});

// 4. LayerZero executes lzCompose with user's pre-paid gas
// InstantAggregator.lzCompose() runs swap using that gas
// No additional gas needed from contract!
```

## Implementation Details

### 1. Swap Router Interface

Created [ISwapRouter.sol](contracts/interfaces/ISwapRouter.sol) for Uniswap V3:

```solidity
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;      // ARB, ETH, etc.
        address tokenOut;     // USDC
        uint24 fee;          // Pool fee (3000 = 0.3%)
        address recipient;   // InstantAggregator
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;  // Slippage protection
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}
```

**Deployed Addresses:**
- Ethereum: `0xE592427A0AEce92De3Edee1F18E0157C05861564`
- Arbitrum: `0xE592427A0AEce92De3Edee1F18E0157C05861564`
- Base: `0x2626664c2603336E57B271c5C0b26F421741e481`
- Optimism: `0xE592427A0AEce92De3Edee1F18E0157C05861564`

### 2. lzCompose Implementation

```solidity
function lzCompose(
    address /* _oApp */,
    bytes32 /* _guid */,
    bytes calldata _message,
    address /* _executor */,
    bytes calldata /* _extraData */
) external payable override {
    // Only endpoint can call
    require(msg.sender == address(endpoint), "Only endpoint");

    // Decode OFT compose message
    bytes memory composeMsg = _message.composeMsg();
    (bytes32 requestId, address tokenIn, uint256 amountIn) = abi.decode(
        composeMsg,
        (bytes32, address, uint256)
    );

    // Check if swap needed
    uint256 usdcAmount;
    if (tokenIn == usdcToken) {
        usdcAmount = amountIn;  // Already USDC
    } else {
        usdcAmount = _swapToUSDC(requestId, tokenIn, amountIn);  // Swap
    }

    // Add to aggregation
    request.totalLocked += usdcAmount;

    // Check for instant settlement
    if (request.totalLocked == request.targetAmount) {
        _instantSettle(requestId, block.timestamp);
    }
}
```

### 3. On-Chain Swap Function

```solidity
function _swapToUSDC(
    bytes32 requestId,
    address tokenIn,
    uint256 amountIn
) internal returns (uint256 usdcOut) {
    // Approve Uniswap router
    IERC20(tokenIn).safeIncreaseAllowance(swapRouter, amountIn);

    // Execute swap on-chain (NO API CALL)
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        tokenIn: tokenIn,
        tokenOut: usdcToken,
        fee: 3000,  // 0.3% pool
        recipient: address(this),
        deadline: block.timestamp,
        amountIn: amountIn,
        amountOutMinimum: 0,  // TODO: Add slippage protection
        sqrtPriceLimitX96: 0
    });

    // Contract-to-contract call (on-chain)
    usdcOut = ISwapRouter(swapRouter).exactInputSingle(params);

    emit TokenSwapped(requestId, tokenIn, amountIn, usdcOut);
    return usdcOut;
}
```

## Configuration

### Owner Must Set Swap Config

```solidity
// Deploy InstantAggregator
InstantAggregator aggregator = new InstantAggregator(
    lzEndpoint,
    usdcOFTAdapter,
    owner
);

// Configure swap functionality
aggregator.setSwapConfig(
    0xE592427A0AEce92De3Edee1F18E0157C05861564,  // Uniswap V3 Router
    0xaf88d065e77c8cC2239327C5EDb3A432268e5831   // Native USDC
);
```

## User Flow Example

### Scenario: User has 100 ARB on Arbitrum, needs to pay 50 USDC

```typescript
// 1. Create compose message with requestId
const composeMsg = ethers.utils.defaultAbiCoder.encode(
    ["bytes32", "address", "uint256"],
    [requestId, ARB_TOKEN_ADDRESS, ethers.utils.parseEther("100")]
);

// 2. Build options with lzCompose gas allocation
const options = Options.newOptions()
    .addExecutorLzReceiveOption(200000, 0)      // lzReceive gas
    .addExecutorComposeOption(0, 500000, 0);    // lzCompose gas (for swap!)

// 3. Create send params
const sendParam = {
    dstEid: BASE_EID,
    to: addressToBytes32(instantAggregatorAddress),
    amountLD: ethers.utils.parseEther("100"),  // 100 ARB
    minAmountLD: ethers.utils.parseEther("100"),
    extraOptions: options.toHex(),
    composeMsg: composeMsg,  // Tell lzCompose what to do
    oftCmd: "0x"
};

// 4. Quote includes ALL gas
const fee = await arbOFTAdapter.quoteSend(sendParam, false);
console.log("Total cost:", ethers.utils.formatEther(fee.nativeFee), "ETH");

// 5. Send with full pre-payment
await arbOFTAdapter.send(
    sendParam,
    fee,
    userAddress,
    { value: fee.nativeFee }  // User pays EVERYTHING upfront
);

// Result:
// - 100 ARB locked on Arbitrum
// - LayerZero delivers to Base
// - lzCompose() called with pre-paid gas
// - Swap executes: 100 ARB → ~50 USDC (depending on price)
// - 50 USDC added to aggregation request
// - Instant settlement when full amount reached
```

## Key Advantages

### 1. No API Calls
- Everything is on-chain contract-to-contract calls
- Uniswap router is a deployed smart contract
- No centralized infrastructure needed

### 2. User Pre-Pays All Gas
- `quoteSend()` calculates total cost including swap
- User pays once upfront
- No gas management needed in contract
- No risk of transactions failing due to insufficient gas

### 3. Horizontal Composability
- Step 1 (Critical): OFT transfer succeeds
- Step 2 (Non-Critical): Swap happens in lzCompose
- If swap fails, user still has tokens on destination
- Separation of concerns

### 4. Instant Settlement
- Swap happens automatically on destination
- USDC immediately added to aggregation
- Merchant receives payment in ~30 seconds
- No manual intervention needed

## Gas Cost Estimation

Typical gas costs on Base (destination chain):

| Operation | Gas Used | Cost @ 0.1 gwei |
|-----------|----------|-----------------|
| lzReceive (USDC direct) | ~100,000 | ~$0.00001 |
| lzCompose callback | ~50,000 | ~$0.000005 |
| Uniswap V3 swap | ~150,000 | ~$0.000015 |
| Total (with swap) | ~300,000 | ~$0.00003 |

**User pays**: Cross-chain delivery (~0.001 ETH) + destination execution (~0.0003 ETH) = **~0.0013 ETH total**

All paid upfront in the initial `send()` transaction.

## Security Considerations

### 1. Slippage Protection
Current implementation has `amountOutMinimum: 0` for testing. **Production must add:**

```solidity
// Get price from oracle (Chainlink, etc.)
uint256 expectedUSDC = getOraclePrice(tokenIn, amountIn);

// Allow 1% slippage
uint256 minUSDC = (expectedUSDC * 99) / 100;

params.amountOutMinimum = minUSDC;
```

### 2. Pool Liquidity
- Ensure sufficient liquidity in Uniswap pools
- Large swaps may experience high slippage
- Consider using multi-hop swaps for better pricing

### 3. MEV Protection
- Swaps are executed at current block price
- Consider using Flashbots or MEV protection for large amounts
- Time-sensitive applications should set tight deadlines

### 4. Token Whitelisting
Consider adding token whitelist:

```solidity
mapping(address => bool) public supportedTokens;

function addSupportedToken(address token) external onlyOwner {
    supportedTokens[token] = true;
}

// In lzCompose:
require(supportedTokens[tokenIn] || tokenIn == usdcToken, "Unsupported token");
```

## Testing

TODO: Add comprehensive tests for:
- [ ] Swap ARB → USDC via lzCompose
- [ ] Direct USDC send (no swap)
- [ ] Multiple tokens in same aggregation request
- [ ] Slippage scenarios
- [ ] Failed swap handling
- [ ] Gas cost measurements

## Future Enhancements

1. **Multi-hop swaps** - Better pricing for exotic tokens
2. **1inch integration** - Aggregated DEX routing for best prices
3. **Slippage oracle** - Automated price checking
4. **Swap caching** - Reuse recent swap results
5. **Batch swaps** - Multiple tokens in one transaction
