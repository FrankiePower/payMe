# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2024-11-22

### 🎉 Major Fixes & Improvements

#### Fixed Issues

1. **✅ Issue #1: Fixed `readContract` Implementation**
   - Integrated viem's `createPublicClient` for reading blockchain data
   - All read operations now work properly:
     - `checkAllowance()` 
     - `getTokenInfo()`
     - `getERC20Balance()`
     - `checkENSAvailability()`
   - Added support for custom RPC URLs via constructor options
   - Automatic public client caching for better performance

2. **✅ Issue #2: Fixed ENS Registration**
   - Implemented full commit-reveal pattern (previously incomplete)
   - Now properly follows ENS security requirements:
     1. Checks name availability
     2. Gets accurate pricing from contract
     3. Submits commitment transaction
     4. Waits required 60 seconds
     5. Completes registration
   - Added detailed progress logging
   - Production-ready ENS registration

3. **✅ Issue #4: Updated Dependencies**
   - Added `dotenv` for environment variable management
   - Pinned `@coinbase/cdp-sdk` to specific version (^0.0.12)
   - Updated `viem` to latest stable (^2.21.0)
   - Updated all dev dependencies
   - Added package metadata (description, keywords, license)

4. **✅ Issue #5: Enhanced Error Handling & Chain IDs**
   - Fixed hardcoded `chainId: 1` bug
   - Added proper chain ID mapping for all networks:
     - Ethereum: 1
     - Base: 8453
     - Ethereum Sepolia: 11155111
     - Base Sepolia: 84532
   - Comprehensive error handling for:
     - Insufficient funds
     - Authentication failures
     - Rate limiting
     - Nonce errors
     - Invalid networks
     - Contract read failures
   - All errors now include helpful context and suggestions

### 🆕 New Features

- **Config Module**: Added `src/config.ts` for environment management
  - `validateEnvironment()`: Ensures required variables are set
  - `getCdpCredentials()`: Safely loads CDP API credentials
  - `getCustomRpcUrls()`: Loads optional custom RPC endpoints
  - `getWalletSecret()`: Loads optional wallet encryption secret

- **Custom RPC Support**: BlockchainOperations constructor now accepts options:
  ```typescript
  const blockchain = new BlockchainOperations(client, {
    rpcUrls: {
      ethereum: "https://eth.llamarpc.com",
      base: "https://base.llamarpc.com"
    }
  });
  ```

- **Public Client Caching**: Viem public clients are cached per network for efficiency

### 📝 Documentation

- Updated `env.example` with RPC URL configuration examples
- Added comprehensive `example.ts` demonstrating all fixes
- Added this CHANGELOG.md to track changes
- All fixed methods now have accurate JSDoc comments

### 🔧 Internal Improvements

- Added `CHAIN_ID_MAP` constant for network-to-chainId mapping
- Added `VIEM_CHAIN_MAP` for viem chain configurations
- Added private helper methods:
  - `getPublicClient()`: Get or create viem public client
  - `getChainId()`: Get chain ID for network
  - `sleep()`: Helper for async delays
- Better type safety with no more `as any` casts where avoidable

### ⚠️ Breaking Changes

None - all changes are backwards compatible

### 🐛 Bug Fixes

- Fixed `readContract()` throwing error instead of reading data
- Fixed `sendTransaction()` using wrong chain IDs
- Fixed ENS registration skipping commit step
- Fixed missing error context in transaction failures

### 📦 Dependencies

**Added:**
- `dotenv@^16.4.5`

**Updated:**
- `@coinbase/cdp-sdk`: latest → ^0.0.12 (pinned)
- `viem`: ^2.0.0 → ^2.21.0
- `@types/node`: ^20.0.0 → ^22.0.0
- `tsx`: ^4.0.0 → ^4.19.0
- `typescript`: ^5.0.0 → ^5.6.0

---

## [1.0.0] - Initial Release

- Initial implementation of blockchain operations
- ERC-20 token transfers and approvals
- Native token transfers
- Cross-chain resource execution (CRE)
- ENS name registration (incomplete)
- Basic documentation

