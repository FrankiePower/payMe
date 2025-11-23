/**
 * Contract ABIs for blockchain interactions
 */

/**
 * Standard ERC-20 Token ABI
 * Includes: transfer, approve, allowance, balanceOf, decimals, symbol, name
 */
export const ERC20_ABI = [
  // Read functions
  {
    inputs: [{ name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    name: "allowance",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "decimals",
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "symbol",
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "name",
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "totalSupply",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  // Write functions
  {
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "transfer",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "approve",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "transferFrom",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
    type: "function",
  },
  // Events
  {
    anonymous: false,
    inputs: [
      { indexed: true, name: "from", type: "address" },
      { indexed: true, name: "to", type: "address" },
      { indexed: false, name: "value", type: "uint256" },
    ],
    name: "Transfer",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, name: "owner", type: "address" },
      { indexed: true, name: "spender", type: "address" },
      { indexed: false, name: "value", type: "uint256" },
    ],
    name: "Approval",
    type: "event",
  },
] as const;

/**
 * ENS Registry ABI
 * For ENS name registration and management
 */
export const ENS_REGISTRY_ABI = [
  {
    inputs: [{ name: "node", type: "bytes32" }],
    name: "owner",
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "node", type: "bytes32" }],
    name: "resolver",
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "owner", type: "address" },
    ],
    name: "setOwner",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "resolver", type: "address" },
    ],
    name: "setResolver",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

/**
 * ENS Public Resolver ABI
 * For setting ENS records (address, text, etc.)
 */
export const ENS_RESOLVER_ABI = [
  {
    inputs: [{ name: "node", type: "bytes32" }],
    name: "addr",
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "a", type: "address" },
    ],
    name: "setAddr",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "key", type: "string" },
    ],
    name: "text",
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "node", type: "bytes32" },
      { name: "key", type: "string" },
      { name: "value", type: "string" },
    ],
    name: "setText",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

/**
 * ENS ETH Registrar Controller ABI
 * For registering .eth names
 */
export const ENS_ETH_REGISTRAR_CONTROLLER_ABI = [
  {
    inputs: [{ name: "name", type: "string" }],
    name: "available",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "name", type: "string" },
      { name: "duration", type: "uint256" },
    ],
    name: "rentPrice",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "name", type: "string" },
      { name: "owner", type: "address" },
      { name: "duration", type: "uint256" },
      { name: "secret", type: "bytes32" },
      { name: "resolver", type: "address" },
      { name: "data", type: "bytes[]" },
      { name: "reverseRecord", type: "bool" },
      { name: "ownerControlledFuses", type: "uint16" },
    ],
    name: "register",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "commitment", type: "bytes32" },
    ],
    name: "commit",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { name: "name", type: "string" },
      { name: "owner", type: "address" },
      { name: "duration", type: "uint256" },
      { name: "secret", type: "bytes32" },
      { name: "resolver", type: "address" },
      { name: "data", type: "bytes[]" },
      { name: "reverseRecord", type: "bool" },
      { name: "ownerControlledFuses", type: "uint16" },
    ],
    name: "makeCommitment",
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "pure",
    type: "function",
  },
] as const;

/**
 * Contract addresses for different networks
 */
export const CONTRACT_ADDRESSES = {
  ethereum: {
    ensRegistry: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e",
    ensPublicResolver: "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63",
    ensEthRegistrarController: "0x253553366Da8546fC250F225fe3d25d0C782303b",
  },
  "ethereum-sepolia": {
    ensRegistry: "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e",
    ensPublicResolver: "0x8FADE66B79cC9f707aB26799354482EB93a5B7dD",
    ensEthRegistrarController: "0xFED6a969AaA60E4961FCD3EBF1A2e8913ac65B72",
  },
} as const;

/**
 * Helper type for network names
 */
export type SupportedNetwork = keyof typeof CONTRACT_ADDRESSES;
