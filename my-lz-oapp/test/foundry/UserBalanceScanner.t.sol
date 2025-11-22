// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "./UserBalanceScannerHarness.sol";
import { Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract MockERC20 {
    mapping(address => uint256) public balances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function setBalance(address account, uint256 balance) external {
        balances[account] = balance;
    }
}

contract MockLayerZeroEndpointV2 {
    uint32 public eid = 40161;

    function send(
        uint32,
        bytes calldata,
        bytes calldata,
        address
    ) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt({
            guid: bytes32(uint256(1)),
            nonce: 1,
            fee: MessagingFee({nativeFee: 0, lzTokenFee: 0})
        });
    }

    function quote(
        uint32,
        bytes calldata,
        bytes calldata,
        bool
    ) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: 0.001 ether, lzTokenFee: 0});
    }

    function setDelegate(address) external {}
}

// Mock USDCBalanceFetcher for testing
contract USDCBalanceFetcher {
    struct BalanceData {
        uint256 balance;
        uint256 minThreshold;
        uint256 usdcAmount;
        bool meetsThreshold;
    }

    address public usdcAddress;

    constructor(address _usdc) {
        usdcAddress = _usdc;
    }

    function fetchUSDCBalance(address wallet) external view returns (uint256) {
        return MockERC20(usdcAddress).balanceOf(wallet);
    }

    function fetchUSDCBalanceWithThreshold(
        address wallet,
        uint256 minThreshold,
        uint256 usdcAmount
    ) external view returns (BalanceData memory) {
        uint256 balance = MockERC20(usdcAddress).balanceOf(wallet);
        return BalanceData({
            balance: balance,
            minThreshold: minThreshold,
            usdcAmount: usdcAmount,
            meetsThreshold: balance >= minThreshold
        });
    }
}

contract UserBalanceScannerTest is Test {
    UserBalanceScannerHarness public scanner;
    USDCBalanceFetcher public fetcherArbitrum;
    USDCBalanceFetcher public fetcherBase;
    USDCBalanceFetcher public fetcherOptimism;
    MockERC20 public usdcArbitrum;
    MockERC20 public usdcBase;
    MockERC20 public usdcOptimism;
    MockLayerZeroEndpointV2 public endpoint;

    address public user = address(0x1);
    address public owner = address(this);

    uint32 public arbitrumEid = 40231;
    uint32 public baseEid = 40245;
    uint32 public optimismEid = 40232;

    function setUp() public {
        endpoint = new MockLayerZeroEndpointV2();
        usdcArbitrum = new MockERC20();
        usdcBase = new MockERC20();
        usdcOptimism = new MockERC20();

        // Deploy balance fetchers
        fetcherArbitrum = new USDCBalanceFetcher(address(usdcArbitrum));
        fetcherBase = new USDCBalanceFetcher(address(usdcBase));
        fetcherOptimism = new USDCBalanceFetcher(address(usdcOptimism));

        // Deploy scanner
        scanner = new UserBalanceScannerHarness(address(endpoint), owner);

        // Register balance fetchers
        scanner.registerBalanceFetcher(
            arbitrumEid,
            bytes32(uint256(uint160(address(fetcherArbitrum))))
        );
        scanner.registerBalanceFetcher(
            baseEid,
            bytes32(uint256(uint160(address(fetcherBase))))
        );
        scanner.registerBalanceFetcher(
            optimismEid,
            bytes32(uint256(uint160(address(fetcherOptimism))))
        );

        // Set user balances
        usdcArbitrum.setBalance(user, 100e6);  // 100 USDC on Arbitrum
        usdcBase.setBalance(user, 50e6);       // 50 USDC on Base
        usdcOptimism.setBalance(user, 200e6);  // 200 USDC on Optimism
    }

    function testRegisterBalanceFetcher() public {
        uint32 newChainEid = 40106; // Avalanche
        bytes32 fetcherAddress = bytes32(uint256(uint160(address(0x123))));

        scanner.registerBalanceFetcher(newChainEid, fetcherAddress);

        assertEq(scanner.getBalanceFetcher(newChainEid), fetcherAddress);
    }

    function test_RevertWhen_RegisterZeroAddressFetcher() public {
        vm.expectRevert("Invalid fetcher address");
        scanner.registerBalanceFetcher(40106, bytes32(0));
    }

    function testGetBalanceFetcher() public {
        bytes32 fetcher = scanner.getBalanceFetcher(arbitrumEid);
        assertEq(fetcher, bytes32(uint256(uint160(address(fetcherArbitrum)))));
    }

    function testScanBalances() public {
        vm.deal(user, 1 ether);

        uint32[] memory chainEids = new uint32[](3);
        chainEids[0] = arbitrumEid;
        chainEids[1] = baseEid;
        chainEids[2] = optimismEid;

        vm.prank(user);
        bytes32 requestId = scanner.scanBalances{value: 0.01 ether}(
            user,
            chainEids,
            ""
        );

        // Request ID should be generated
        assertTrue(requestId != bytes32(0));
    }

    function test_RevertWhen_ScanBalancesNoChains() public {
        vm.deal(user, 1 ether);

        uint32[] memory chainEids = new uint32[](0);

        vm.prank(user);
        vm.expectRevert("No chains specified");
        scanner.scanBalances{value: 0.01 ether}(user, chainEids, "");
    }

    function test_RevertWhen_ScanBalancesInvalidUser() public {
        vm.deal(user, 1 ether);

        uint32[] memory chainEids = new uint32[](1);
        chainEids[0] = arbitrumEid;

        vm.prank(user);
        vm.expectRevert("Invalid user address");
        scanner.scanBalances{value: 0.01 ether}(address(0), chainEids, "");
    }

    function test_RevertWhen_ScanBalancesUnregisteredChain() public {
        vm.deal(user, 1 ether);

        uint32[] memory chainEids = new uint32[](1);
        chainEids[0] = 40999; // Unregistered chain

        vm.prank(user);
        vm.expectRevert("Balance fetcher not registered");
        scanner.scanBalances{value: 0.01 ether}(user, chainEids, "");
    }

    function testDirectBalanceFetch() public {
        // Test USDCBalanceFetcher directly
        uint256 balance = fetcherArbitrum.fetchUSDCBalance(user);
        assertEq(balance, 100e6);

        balance = fetcherBase.fetchUSDCBalance(user);
        assertEq(balance, 50e6);

        balance = fetcherOptimism.fetchUSDCBalance(user);
        assertEq(balance, 200e6);
    }

    function testBalanceFetchWithThreshold() public {
        USDCBalanceFetcher.BalanceData memory result = fetcherArbitrum.fetchUSDCBalanceWithThreshold(
            user,
            50e6,  // minThreshold
            500e6  // usdcAmount
        );

        assertEq(result.balance, 100e6);
        assertEq(result.minThreshold, 50e6);
        assertEq(result.usdcAmount, 500e6);
    }

    function testLzReceive() public {
        // Simulate balance response from remote chain
        bytes32 requestId = keccak256(abi.encode(user, block.timestamp));
        bytes memory message = abi.encode(requestId, user, 100e6);

        Origin memory origin = Origin({
            srcEid: arbitrumEid,
            sender: bytes32(uint256(uint160(address(fetcherArbitrum)))),
            nonce: 1
        });

        // This should emit BalancesScanned event
        vm.expectEmit(true, false, false, false);
        emit UserBalanceScanner.BalancesScanned(
            user,
            new uint32[](1),
            new uint256[](1),
            100e6
        );

        scanner.exposed_lzReceive(
            origin,
            bytes32(uint256(1)),
            message,
            address(0),
            ""
        );
    }

    function testQuoteScanBalances() public view {
        uint32[] memory chainEids = new uint32[](3);
        chainEids[0] = arbitrumEid;
        chainEids[1] = baseEid;
        chainEids[2] = optimismEid;

        uint256 fee = scanner.quoteScanBalances(chainEids, "");

        // Returns 0 as placeholder (not implemented yet)
        assertEq(fee, 0);
    }
}
