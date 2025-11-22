# User Agent Development TODO Guide

## Overview
This guide outlines the tasks needed to build the **off-chain user agent** that orchestrates multi-chain payment aggregation. The agent is responsible for scanning user balances, creating aggregation plans, and coordinating transfers from multiple source chains.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│ USER AGENT (Off-chain TypeScript/Node.js)           │
│                                                      │
│ 1. Scan user's USDC balances across all chains      │
│ 2. Calculate optimal aggregation plan               │
│ 3. Get user approvals on each source chain          │
│ 4. Initiate parallel transfers via LayerZero        │
│ 5. Monitor settlement progress                      │
│ 6. Handle partial payments and refunds              │
└─────────────────────────────────────────────────────┘
```

---

## Phase 1: Setup & Configuration

### Task 1.1: Project Setup
**Priority:** High
**Estimated Time:** 2 hours

- [ ] Initialize Node.js/TypeScript project
  ```bash
  mkdir payment-agent
  cd payment-agent
  npm init -y
  npm install typescript @types/node ts-node
  npx tsc --init
  ```

- [ ] Install required dependencies
  ```bash
  npm install ethers@6 dotenv
  npm install @layerzerolabs/lz-v2-utilities
  npm install @layerzerolabs/oapp-evm
  ```

- [ ] Create project structure
  ```
  payment-agent/
  ├── src/
  │   ├── config/
  │   │   ├── chains.ts          # Chain configurations
  │   │   └── contracts.ts       # Contract addresses
  │   ├── services/
  │   │   ├── BalanceScanner.ts  # Balance scanning logic
  │   │   ├── AggregationPlanner.ts
  │   │   ├── TransferOrchestrator.ts
  │   │   └── SettlementMonitor.ts
  │   ├── utils/
  │   │   ├── providers.ts       # RPC providers
  │   │   └── helpers.ts         # Helper functions
  │   └── index.ts               # Main entry point
  ├── .env.example
  └── package.json
  ```

### Task 1.2: Chain Configuration
**Priority:** High
**Estimated Time:** 1 hour

- [ ] Create `src/config/chains.ts`
  ```typescript
  export interface ChainConfig {
    chainId: number;
    name: string;
    lzEid: number;
    rpcUrl: string;
    usdcAddress: string;
    explorerUrl: string;
  }

  export const CHAINS: Record<string, ChainConfig> = {
    ARBITRUM_SEPOLIA: {
      chainId: 421614,
      name: 'Arbitrum Sepolia',
      lzEid: 40231,
      rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC || '',
      usdcAddress: '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d',
      explorerUrl: 'https://sepolia.arbiscan.io',
    },
    BASE_SEPOLIA: {
      chainId: 84532,
      name: 'Base Sepolia',
      lzEid: 40245,
      rpcUrl: process.env.BASE_SEPOLIA_RPC || '',
      usdcAddress: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
      explorerUrl: 'https://sepolia.basescan.org',
    },
    SEPOLIA: {
      chainId: 11155111,
      name: 'Sepolia',
      lzEid: 40161,
      rpcUrl: process.env.SEPOLIA_RPC || '',
      usdcAddress: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
      explorerUrl: 'https://sepolia.etherscan.io',
    },
  };
  ```

- [ ] Create `src/config/contracts.ts`
  ```typescript
  export const CONTRACT_ADDRESSES = {
    ARBITRUM_SEPOLIA: {
      sourceChainInitiator: '0x...',
      usdcBalanceFetcher: '0x...',
    },
    BASE_SEPOLIA: {
      sourceChainInitiator: '0x...',
      usdcBalanceFetcher: '0x...',
      paymentAggregator: '0x...',  // Destination chain
    },
    SEPOLIA: {
      sourceChainInitiator: '0x...',
      usdcBalanceFetcher: '0x...',
    },
  };
  ```

- [ ] Create `.env.example`
  ```env
  # RPC URLs
  ARBITRUM_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc
  BASE_SEPOLIA_RPC=https://sepolia.base.org
  SEPOLIA_RPC=https://rpc.sepolia.org

  # Private keys (for testing only - use secure key management in production)
  USER_PRIVATE_KEY=0x...

  # LayerZero settings
  LZ_SCAN_API_KEY=...
  ```

---

## Phase 2: Core Services

### Task 2.1: Balance Scanner Service
**Priority:** High
**Estimated Time:** 4 hours

- [ ] Create `src/services/BalanceScanner.ts`

**Responsibilities:**
- Query UserBalanceScanner contract
- Fetch user's USDC balances across all chains
- Cache results for performance

**Implementation:**
```typescript
import { ethers } from 'ethers';
import { CHAINS } from '../config/chains';
import { CONTRACT_ADDRESSES } from '../config/contracts';

export interface ChainBalance {
  chainName: string;
  chainEid: number;
  balance: bigint;
  balanceFormatted: string;
}

export class BalanceScanner {
  private providers: Map<string, ethers.Provider>;
  private scannerContract: ethers.Contract;

  constructor() {
    // Initialize providers for each chain
    this.providers = new Map();
    // Initialize UserBalanceScanner contract
  }

  /**
   * Scan user's USDC balances across all chains
   */
  async scanBalances(
    userAddress: string,
    chainKeys: string[]
  ): Promise<ChainBalance[]> {
    // TODO: Implementation steps:
    // 1. Get chain EIDs from chainKeys
    // 2. Call UserBalanceScanner.scanBalances()
    // 3. Parse results
    // 4. Format balances (convert from 6 decimals)
    // 5. Return ChainBalance array
  }

  /**
   * Get USDC balance on a single chain (fallback)
   */
  async getBalanceOnChain(
    userAddress: string,
    chainKey: string
  ): Promise<bigint> {
    // TODO: Direct USDC.balanceOf() call for single chain
  }

  /**
   * Calculate total USDC across all chains
   */
  calculateTotalBalance(balances: ChainBalance[]): bigint {
    return balances.reduce((sum, b) => sum + b.balance, 0n);
  }
}
```

**Sub-tasks:**
- [ ] Implement provider initialization
- [ ] Implement UserBalanceScanner contract interaction
- [ ] Add error handling for RPC failures
- [ ] Add retry logic for failed requests
- [ ] Implement balance caching (5-second TTL)
- [ ] Add unit tests

---

### Task 2.2: Aggregation Planner Service
**Priority:** High
**Estimated Time:** 4 hours

- [ ] Create `src/services/AggregationPlanner.ts`

**Responsibilities:**
- Calculate which chains to pull funds from
- Optimize for gas costs
- Handle insufficient balance scenarios

**Implementation:**
```typescript
export interface AggregationPlan {
  requestId: string;
  targetAmount: bigint;
  minimumThreshold: number; // Percentage (e.g., 90)
  destinationChain: string;
  refundChain: string;
  sources: SourceAllocation[];
  totalAvailable: bigint;
  estimatedGasCost: bigint;
}

export interface SourceAllocation {
  chainKey: string;
  chainEid: number;
  amount: bigint;
  amountFormatted: string;
}

export class AggregationPlanner {
  /**
   * Create aggregation plan from user balances
   */
  createPlan(
    userAddress: string,
    targetAmount: bigint,
    minimumThreshold: number,
    destinationChain: string,
    balances: ChainBalance[]
  ): AggregationPlan {
    // TODO: Implementation steps:
    // 1. Calculate total available USDC
    // 2. Check if sufficient funds available
    // 3. Determine which chains to pull from (optimize for gas)
    // 4. Calculate exact amounts per chain
    // 5. Estimate total gas costs
    // 6. Return AggregationPlan
  }

  /**
   * Optimize source selection (prefer fewer chains, lower gas)
   */
  private optimizeSources(
    balances: ChainBalance[],
    targetAmount: bigint
  ): SourceAllocation[] {
    // TODO: Optimization strategies:
    // Strategy 1: Greedy - Use largest balances first
    // Strategy 2: Minimize chains - Use fewest chains possible
    // Strategy 3: Gas-aware - Consider LZ fees per chain
  }

  /**
   * Validate plan feasibility
   */
  validatePlan(plan: AggregationPlan): {
    valid: boolean;
    errors: string[];
  } {
    // TODO: Validation checks:
    // - Total available >= minimum threshold
    // - Each source has sufficient balance
    // - Destination chain is valid
    // - Gas costs are reasonable
  }
}
```

**Sub-tasks:**
- [ ] Implement greedy allocation algorithm
- [ ] Add gas cost estimation
- [ ] Handle edge cases (single chain, insufficient funds)
- [ ] Add plan validation logic
- [ ] Add unit tests with various scenarios

---

### Task 2.3: Transfer Orchestrator Service
**Priority:** High
**Estimated Time:** 6 hours

- [ ] Create `src/services/TransferOrchestrator.ts`

**Responsibilities:**
- Execute aggregation plan
- Get user approvals on each source chain
- Initiate parallel transfers
- Track transfer progress

**Implementation:**
```typescript
export interface TransferStatus {
  transferId: string;
  sourceChain: string;
  amount: bigint;
  status: 'PENDING' | 'APPROVING' | 'APPROVED' | 'SENDING' | 'SENT' | 'CONFIRMED' | 'FAILED';
  txHash?: string;
  error?: string;
}

export class TransferOrchestrator {
  private providers: Map<string, ethers.Provider>;
  private signers: Map<string, ethers.Signer>;

  /**
   * Execute aggregation plan
   */
  async executeAggregation(
    plan: AggregationPlan,
    userPrivateKey: string
  ): Promise<{
    requestId: string;
    transfers: TransferStatus[];
  }> {
    // TODO: Implementation steps:
    // 1. Initialize PaymentAggregator on destination chain
    // 2. Calculate refund gas deposit
    // 3. Call PaymentAggregator.initiateAggregation()
    // 4. Execute transfers from each source chain in parallel
    // 5. Return request ID and transfer statuses
  }

  /**
   * Execute transfer from a single source chain
   */
  private async executeSourceTransfer(
    requestId: string,
    source: SourceAllocation,
    userPrivateKey: string,
    destinationChain: string
  ): Promise<TransferStatus> {
    // TODO: Implementation steps:
    // 1. Connect to source chain
    // 2. Check USDC balance
    // 3. Approve USDC to SourceChainInitiator
    // 4. Call SourceChainInitiator.sendToAggregator()
    // 5. Wait for transaction confirmation
    // 6. Return TransferStatus
  }

  /**
   * Approve USDC spending
   */
  private async approveUSDC(
    chainKey: string,
    spender: string,
    amount: bigint,
    signer: ethers.Signer
  ): Promise<string> {
    // TODO: ERC20 approval transaction
  }

  /**
   * Estimate LayerZero fees for a transfer
   */
  async estimateLZFee(
    sourceChain: string,
    destinationChain: string,
    amount: bigint
  ): Promise<bigint> {
    // TODO: Call SourceChainInitiator.quote() or endpoint.quote()
  }
}
```

**Sub-tasks:**
- [ ] Implement PaymentAggregator interaction
- [ ] Implement SourceChainInitiator interaction
- [ ] Add parallel transfer execution (Promise.all)
- [ ] Add approval handling with gas optimization
- [ ] Add transaction retry logic
- [ ] Implement gas estimation
- [ ] Add comprehensive error handling
- [ ] Add unit tests

---

### Task 2.4: Settlement Monitor Service
**Priority:** Medium
**Estimated Time:** 4 hours

- [ ] Create `src/services/SettlementMonitor.ts`

**Responsibilities:**
- Monitor aggregation request progress
- Track partial payments
- Notify user when action needed
- Handle timeouts

**Implementation:**
```typescript
export interface SettlementProgress {
  requestId: string;
  status: 'PENDING' | 'PARTIAL' | 'SETTLED' | 'REFUNDING' | 'REFUNDED';
  amountReceived: bigint;
  targetAmount: bigint;
  minimumAmount: bigint;
  percentReceived: number;
  timeRemaining: number; // seconds
  canAcceptPartial: boolean;
  canRefund: boolean;
  receivedPerChain: Map<string, bigint>;
}

export class SettlementMonitor {
  private aggregatorContract: ethers.Contract;
  private pollingInterval: number = 5000; // 5 seconds

  /**
   * Monitor aggregation request progress
   */
  async monitorRequest(
    requestId: string,
    onProgress: (progress: SettlementProgress) => void,
    onComplete: (settled: boolean, amount: bigint) => void
  ): Promise<void> {
    // TODO: Implementation steps:
    // 1. Poll PaymentAggregator.getRequest()
    // 2. Calculate progress metrics
    // 3. Call onProgress callback with updates
    // 4. Listen for settlement events
    // 5. Call onComplete when settled/refunded
  }

  /**
   * Get current request status
   */
  async getRequestStatus(requestId: string): Promise<SettlementProgress> {
    // TODO: Query PaymentAggregator for request details
  }

  /**
   * Accept partial payment (if above minimum)
   */
  async acceptPartialPayment(
    requestId: string,
    userPrivateKey: string
  ): Promise<string> {
    // TODO: Call PaymentAggregator.acceptPartialPayment()
  }

  /**
   * Request refund (if eligible)
   */
  async requestRefund(
    requestId: string,
    userPrivateKey: string
  ): Promise<string> {
    // TODO: Call PaymentAggregator.requestRefund()
  }

  /**
   * Process expired request (auto-refund or settle)
   */
  async processExpiredRequest(requestId: string): Promise<string> {
    // TODO: Call PaymentAggregator.processExpiredRequest()
  }
}
```

**Sub-tasks:**
- [ ] Implement polling mechanism
- [ ] Add event listeners for on-chain events
- [ ] Implement partial payment acceptance flow
- [ ] Implement refund request flow
- [ ] Add timeout handling
- [ ] Add progress calculation
- [ ] Add unit tests

---

## Phase 3: Main Application & CLI

### Task 3.1: Main Application Logic
**Priority:** High
**Estimated Time:** 4 hours

- [ ] Create `src/index.ts`

**Implementation:**
```typescript
import { BalanceScanner } from './services/BalanceScanner';
import { AggregationPlanner } from './services/AggregationPlanner';
import { TransferOrchestrator } from './services/TransferOrchestrator';
import { SettlementMonitor } from './services/SettlementMonitor';

export class PaymentAgent {
  private balanceScanner: BalanceScanner;
  private planner: AggregationPlanner;
  private orchestrator: TransferOrchestrator;
  private monitor: SettlementMonitor;

  constructor() {
    this.balanceScanner = new BalanceScanner();
    this.planner = new AggregationPlanner();
    this.orchestrator = new TransferOrchestrator();
    this.monitor = new SettlementMonitor();
  }

  /**
   * Complete payment flow
   */
  async payMerchant(params: {
    userAddress: string;
    userPrivateKey: string;
    merchantAddress: string;
    amount: string; // e.g., "500" for 500 USDC
    destinationChain: string;
    minimumThreshold?: number; // Default 90%
  }): Promise<void> {
    // TODO: Implementation steps:
    // 1. Scan user balances
    // 2. Create aggregation plan
    // 3. Display plan to user for confirmation
    // 4. Execute aggregation
    // 5. Monitor settlement
    // 6. Handle partial payment or refund
  }
}

// CLI entry point
async function main() {
  const agent = new PaymentAgent();

  await agent.payMerchant({
    userAddress: '0x...',
    userPrivateKey: process.env.USER_PRIVATE_KEY!,
    merchantAddress: '0x...',
    amount: '500',
    destinationChain: 'BASE_SEPOLIA',
    minimumThreshold: 90,
  });
}

main().catch(console.error);
```

**Sub-tasks:**
- [ ] Implement main payment flow
- [ ] Add user confirmation prompts
- [ ] Add progress logging
- [ ] Add error handling and recovery
- [ ] Create CLI argument parsing
- [ ] Add help documentation

---

### Task 3.2: CLI Interface (Optional Enhancement)
**Priority:** Low
**Estimated Time:** 3 hours

- [ ] Add interactive CLI using `inquirer`
  ```bash
  npm install inquirer @types/inquirer
  ```

- [ ] Create interactive prompts for:
  - [ ] User wallet selection
  - [ ] Merchant address input
  - [ ] Payment amount input
  - [ ] Destination chain selection
  - [ ] Minimum threshold configuration
  - [ ] Plan confirmation
  - [ ] Partial payment acceptance

- [ ] Add colored console output (`chalk`)
- [ ] Add progress bars for transfers (`cli-progress`)
- [ ] Add ASCII art for branding

---

## Phase 4: Testing & Optimization

### Task 4.1: Unit Tests
**Priority:** High
**Estimated Time:** 6 hours

- [ ] Install testing framework
  ```bash
  npm install --save-dev jest @types/jest ts-jest
  ```

- [ ] Create tests for each service:
  - [ ] `BalanceScanner.test.ts`
  - [ ] `AggregationPlanner.test.ts`
  - [ ] `TransferOrchestrator.test.ts`
  - [ ] `SettlementMonitor.test.ts`

- [ ] Test edge cases:
  - [ ] Insufficient balance
  - [ ] Single chain payment
  - [ ] Partial payment scenarios
  - [ ] Timeout scenarios
  - [ ] Failed transfers

### Task 4.2: Integration Tests
**Priority:** Medium
**Estimated Time:** 4 hours

- [ ] Test end-to-end flow on testnet
- [ ] Test with multiple concurrent payments
- [ ] Test refund mechanisms
- [ ] Test error recovery

### Task 4.3: Performance Optimization
**Priority:** Low
**Estimated Time:** 3 hours

- [ ] Add request caching
- [ ] Optimize RPC calls (batch requests)
- [ ] Add connection pooling
- [ ] Implement retry with exponential backoff
- [ ] Add request rate limiting

---

## Phase 5: Documentation & Deployment

### Task 5.1: Documentation
**Priority:** Medium
**Estimated Time:** 3 hours

- [ ] Create README.md with:
  - [ ] Installation instructions
  - [ ] Configuration guide
  - [ ] Usage examples
  - [ ] API documentation

- [ ] Create ARCHITECTURE.md explaining:
  - [ ] System components
  - [ ] Data flow diagrams
  - [ ] Sequence diagrams

- [ ] Add inline code comments
- [ ] Generate TypeDoc documentation

### Task 5.2: Deployment Preparation
**Priority:** Medium
**Estimated Time:** 2 hours

- [ ] Create Docker container
- [ ] Add environment variable validation
- [ ] Create deployment scripts
- [ ] Add health check endpoints
- [ ] Set up logging (Winston/Pino)
- [ ] Add monitoring hooks (optional)

---

## Estimated Timeline

| Phase | Duration |
|-------|----------|
| Phase 1: Setup | 3 hours |
| Phase 2: Core Services | 18 hours |
| Phase 3: Main App & CLI | 7 hours |
| Phase 4: Testing | 13 hours |
| Phase 5: Documentation | 5 hours |
| **Total** | **46 hours** (~1 week full-time) |

---

## Priority Order

1. **Critical Path (MVP):**
   - Task 1.1, 1.2: Setup
   - Task 2.1: Balance Scanner
   - Task 2.2: Aggregation Planner
   - Task 2.3: Transfer Orchestrator
   - Task 3.1: Main Application
   - Task 4.1: Basic unit tests

2. **Important:**
   - Task 2.4: Settlement Monitor
   - Task 4.2: Integration tests
   - Task 5.1: Documentation

3. **Nice to Have:**
   - Task 3.2: CLI Interface
   - Task 4.3: Performance optimization
   - Task 5.2: Deployment

---

## Testing Checklist

Before considering the agent complete, test these scenarios:

- [ ] **Happy Path:** User has 500 USDC across 3 chains, aggregates to pay 400 USDC
- [ ] **Partial Payment:** User has 450 USDC, wants 500 USDC, accepts 90%
- [ ] **Insufficient Funds:** User has 300 USDC, wants 500 USDC, gets refund
- [ ] **Single Chain:** User has all USDC on one chain
- [ ] **Timeout:** One chain fails to send, timeout triggers refund
- [ ] **Manual Refund:** User requests refund before settlement
- [ ] **Gas Estimation:** Verify gas costs are reasonable

---

## Resources

**LayerZero Documentation:**
- [OApp Contracts](https://docs.layerzero.network/contracts/oapp)
- [OFT Standard](https://docs.layerzero.network/contracts/oft)
- [Message Execution Options](https://docs.layerzero.network/contracts/options)

**Ethers.js Documentation:**
- [Contract Interaction](https://docs.ethers.org/v6/api/contract/)
- [Providers](https://docs.ethers.org/v6/api/providers/)
- [Signers](https://docs.ethers.org/v6/api/providers/#Signer)

**Testing:**
- [Jest Documentation](https://jestjs.io/docs/getting-started)
- [Hardhat Forking](https://hardhat.org/hardhat-network/docs/guides/forking-other-networks)

---

## Notes

- **Security:** Never commit private keys to git. Use `.env` and `.gitignore`.
- **RPC Limits:** Use Alchemy/Infura for production-grade RPC endpoints.
- **Gas Optimization:** Consider batch approvals if user makes frequent payments.
- **Error Handling:** Always handle RPC failures gracefully with retries.
- **User Experience:** Add clear progress indicators and error messages.

---

## Support

For questions or issues:
1. Check contract documentation in `/contracts`
2. Review LayerZero developer docs
3. Test on testnet first
4. Contact team for architecture questions

Good luck! 🚀
