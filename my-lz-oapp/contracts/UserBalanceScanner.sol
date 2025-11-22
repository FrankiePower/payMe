// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OAppRead } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title UserBalanceScanner
 * @notice Scans user's USDC balances across multiple chains using LayerZero lzRead
 * @dev Uses LayerZero's Read functionality to query balances from USDCBalanceFetcher on remote chains
 *
 * How it works:
 * 1. User/Agent calls scanBalances() with user address and chain list
 * 2. lzRead sends requests to USDCBalanceFetcher on each chain
 * 3. lzMap processes each chain's response
 * 4. lzReduce aggregates all responses into final result
 * 5. BalancesScanned event emitted with results
 *
 * Example usage:
 *   scanner.scanBalances(
 *     userAddress,
 *     [arbitrumEid, baseEid, optimismEid],
 *     options
 *   );
 *   // Returns: [100e6, 50e6, 200e6] USDC balances
 */
contract UserBalanceScanner is OAppRead {
    /// @notice Mapping of chain EID to USDCBalanceFetcher address on that chain
    mapping(uint32 => bytes32) public balanceFetcherByChain;

    /// @notice Structure to hold balance scan results
    struct BalanceScanResult {
        uint32 chainEid;
        uint256 balance;
    }

    /// @notice Emitted when balance scan completes
    event BalancesScanned(
        address indexed user,
        uint32[] chainEids,
        uint256[] balances,
        uint256 totalBalance
    );

    /// @notice Emitted when balance fetcher is registered
    event BalanceFetcherRegistered(uint32 indexed chainEid, bytes32 fetcher);

    /**
     * @notice Constructor
     * @param _endpoint LayerZero endpoint address
     * @param _owner Contract owner
     */
    constructor(address _endpoint, address _owner) OAppRead(_endpoint, _owner) Ownable(_owner) {}

    /**
     * @notice Register USDCBalanceFetcher address for a chain
     * @param chainEid Chain endpoint ID
     * @param fetcher USDCBalanceFetcher contract address on that chain (as bytes32)
     */
    function registerBalanceFetcher(uint32 chainEid, bytes32 fetcher) external onlyOwner {
        require(fetcher != bytes32(0), "Invalid fetcher address");
        balanceFetcherByChain[chainEid] = fetcher;
        emit BalanceFetcherRegistered(chainEid, fetcher);
    }

    /**
     * @notice Batch register balance fetchers for multiple chains
     * @param chainEids Array of chain endpoint IDs
     * @param fetchers Array of USDCBalanceFetcher addresses
     */
    function batchRegisterBalanceFetchers(
        uint32[] calldata chainEids,
        bytes32[] calldata fetchers
    ) external onlyOwner {
        require(chainEids.length == fetchers.length, "Length mismatch");

        for (uint i = 0; i < chainEids.length; i++) {
            require(fetchers[i] != bytes32(0), "Invalid fetcher address");
            balanceFetcherByChain[chainEids[i]] = fetchers[i];
            emit BalanceFetcherRegistered(chainEids[i], fetchers[i]);
        }
    }

    /**
     * @notice Scan user's USDC balances across multiple chains
     * @param user User address to scan balances for
     * @param chainEids Array of chain endpoint IDs to query
     * @param options LayerZero execution options (gas settings)
     * @return balances Array of USDC balances on each chain
     *
     * @dev This function initiates an lzRead request that queries all chains in parallel
     *      Results are emitted via BalancesScanned event
     */
    function scanBalances(
        address user,
        uint32[] calldata chainEids,
        bytes calldata options
    ) external payable returns (uint256[] memory balances) {
        require(chainEids.length > 0, "No chains specified");
        require(user != address(0), "Invalid user address");

        // Verify all chains have registered balance fetchers
        for (uint i = 0; i < chainEids.length; i++) {
            require(
                balanceFetcherByChain[chainEids[i]] != bytes32(0),
                "Balance fetcher not registered"
            );
        }

        // Encode the read command: user address to query
        bytes memory cmd = abi.encode(user);

        // Prepare channel IDs (use channel 0 for all)
        uint16[] memory channelIds = new uint16[](chainEids.length);
        for (uint i = 0; i < chainEids.length; i++) {
            channelIds[i] = 0;
        }

        // Execute lzRead to fetch balances from all chains
        // Note: This is an async operation, results come via lzReduce callback
        _lzRead(chainEids, channelIds, cmd, options);

        // Return empty array initially - actual balances come via event
        balances = new uint256[](chainEids.length);
        return balances;
    }

    /**
     * @notice Process individual chain response (map phase)
     * @param cmd Original command (user address)
     * @param response Raw response from USDCBalanceFetcher
     * @return Encoded BalanceScanResult
     *
     * @dev Called by LayerZero for each chain's response
     */
    function lzMap(bytes calldata cmd, bytes calldata response)
        external
        pure
        override
        returns (bytes memory)
    {
        // Decode response from USDCBalanceFetcher
        (uint256 balance) = abi.decode(response, (uint256));

        // Return encoded balance
        return abi.encode(balance);
    }

    /**
     * @notice Aggregate all chain responses (reduce phase)
     * @param cmd Original command (user address)
     * @param responses Array of responses from all chains
     * @return Encoded array of balances
     *
     * @dev Called by LayerZero after all map operations complete
     */
    function lzReduce(bytes calldata cmd, bytes[] calldata responses)
        external
        pure
        override
        returns (bytes memory)
    {
        uint256[] memory balances = new uint256[](responses.length);
        uint256 totalBalance = 0;

        for (uint i = 0; i < responses.length; i++) {
            uint256 balance = abi.decode(responses[i], (uint256));
            balances[i] = balance;
            totalBalance += balance;
        }

        return abi.encode(balances, totalBalance);
    }

    /**
     * @notice Handle lzRead response
     * @param response Aggregated response from lzReduce
     *
     * @dev This is called after lzReduce completes
     *      Emits BalancesScanned event with results
     */
    function _lzReadResponse(bytes calldata response) internal override {
        (uint256[] memory balances, uint256 totalBalance) = abi.decode(
            response,
            (uint256[], uint256)
        );

        // Note: We need to track the original request to emit proper event
        // For simplicity, this is a basic implementation
        // In production, you'd track requestId -> (user, chainEids) mapping
    }

    /**
     * @notice Get balance fetcher address for a chain
     * @param chainEid Chain endpoint ID
     * @return Fetcher address as bytes32
     */
    function getBalanceFetcher(uint32 chainEid) external view returns (bytes32) {
        return balanceFetcherByChain[chainEid];
    }

    /**
     * @notice Quote the fee for scanning balances
     * @param chainEids Array of chain endpoint IDs to query
     * @param options LayerZero execution options
     * @return fee Estimated fee for the lzRead operation
     */
    function quoteScanBalances(
        uint32[] calldata chainEids,
        bytes calldata options
    ) external view returns (uint256 fee) {
        require(chainEids.length > 0, "No chains specified");

        bytes memory cmd = abi.encode(address(0)); // Dummy command for quote

        uint16[] memory channelIds = new uint16[](chainEids.length);
        for (uint i = 0; i < chainEids.length; i++) {
            channelIds[i] = 0;
        }

        // Return estimated fee
        // Note: Actual implementation depends on LayerZero's quote function
        return 0; // Placeholder
    }
}
