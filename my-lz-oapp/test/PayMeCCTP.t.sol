// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CctpBridger} from "../contracts/CctpBridger.sol";
import {SourceChainInitiator} from "../contracts/SourceChainInitiator.sol";
import {InstantAggregator} from "../contracts/InstantAggregator.sol";
import {MockTokenMessengerV2} from "../contracts/mocks/MockTokenMessengerV2.sol";

contract MockUSDC is ERC20("MockUSDC", "mUSDC") {
    constructor() {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockEndpointV2 {
    uint32 public eid;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address) external {}
}

contract MockMessageTransmitter {
    // Simple mock that does nothing
}

/**
 * @title PayMeCCTPTest
 * @notice Unit tests for PayMe CCTP integration using mocks
 * @dev Tests the full flow: User → SourceChainInitiator → CctpBridger → MockTokenMessenger
 */
contract PayMeCCTPTest is Test {
    // Test actors
    address owner = address(0x1);
    address user = address(0x2);
    address merchant = address(0x3);

    // Mock contracts
    MockUSDC usdc;
    MockTokenMessengerV2 tokenMessenger;
    MockEndpointV2 ethEndpoint;
    MockEndpointV2 baseEndpoint;
    MockMessageTransmitter messageTransmitter;

    // PayMe contracts
    CctpBridger cctpBridger;
    SourceChainInitiator sourceChainInitiator;
    InstantAggregator instantAggregator;

    function setUp() public {
        // Deploy mocks
        usdc = new MockUSDC();
        tokenMessenger = new MockTokenMessengerV2();
        ethEndpoint = new MockEndpointV2(40161); // ETH Sepolia EID
        baseEndpoint = new MockEndpointV2(40245); // Base Sepolia EID
        messageTransmitter = new MockMessageTransmitter();

        // Deploy PayMe contracts
        vm.startPrank(owner);

        // Deploy CctpBridger
        cctpBridger = new CctpBridger(address(tokenMessenger), address(usdc));

        // Deploy SourceChainInitiator
        sourceChainInitiator = new SourceChainInitiator(
            address(ethEndpoint),
            address(usdc),
            address(cctpBridger),
            owner
        );

        // Deploy InstantAggregator
        instantAggregator = new InstantAggregator(
            address(baseEndpoint),
            address(messageTransmitter),
            owner
        );

        // Configure InstantAggregator (using a dummy swap router since we won't use it)
        instantAggregator.setSwapConfig(address(0x123), address(usdc));

        // Register aggregator and CCTP domain in SourceChainInitiator
        sourceChainInitiator.registerAggregator(40245, address(instantAggregator));
        sourceChainInitiator.registerCCTPDomain(40245, 6); // Base domain = 6

        vm.stopPrank();

        // Fund user with USDC
        usdc.mint(user, 100e6); // 100 USDC
    }

    function test_deployment() public {
        assertEq(address(cctpBridger.messenger()), address(tokenMessenger), "Wrong messenger");
        assertEq(address(cctpBridger.usdc()), address(usdc), "Wrong USDC");
        assertEq(sourceChainInitiator.owner(), owner, "Wrong owner");
        assertEq(instantAggregator.owner(), owner, "Wrong aggregator owner");
    }

    function test_sourceChainInitiator_configuration() public {
        assertEq(
            sourceChainInitiator.aggregatorByEid(40245),
            address(instantAggregator),
            "Aggregator not registered"
        );
        assertEq(sourceChainInitiator.cctpDomainByEid(40245), 6, "CCTP domain not registered");
    }

    function test_instantAggregator_create_request() public {
        uint256 targetAmount = 10e6; // 10 USDC
        uint32 refundChain = 40161; // ETH Sepolia

        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40161; // ETH Sepolia

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 10e6; // 10 USDC

        vm.deal(user, 0.1 ether);
        vm.prank(user);
        bytes32 requestId = instantAggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            targetAmount,
            refundChain,
            sourceChains,
            expectedAmounts
        );

        (
            bytes32 storedRequestId,
            address storedUser,
            address storedMerchant,
            uint256 storedTargetAmount,
            ,,,,,,
            bool exists,

        ) = instantAggregator.requests(requestId);

        assertEq(storedRequestId, requestId, "Wrong request ID");
        assertEq(storedUser, user, "Wrong user");
        assertEq(storedMerchant, merchant, "Wrong merchant");
        assertEq(storedTargetAmount, targetAmount, "Wrong target amount");
        assertTrue(exists, "Request not created");
    }

    function test_full_flow_with_mock_cctp() public {
        // 1. Create aggregation request
        uint256 amount = 10e6;
        bytes32 requestId = _createAggregationRequest(amount);

        // 2. User approves and sends USDC
        vm.prank(user);
        usdc.approve(address(sourceChainInitiator), amount);

        vm.prank(user);
        bytes32 transferId = sourceChainInitiator.sendToAggregator(
            requestId,
            amount,
            40245, // Base
            true // Fast mode
        );

        // 3. Verify transfer was recorded
        (bytes32 storedRequestId, address storedUser, uint256 storedAmount,,,, bool sent) =
            sourceChainInitiator.pendingTransfers(transferId);

        assertEq(storedRequestId, requestId, "Wrong request ID");
        assertEq(storedUser, user, "Wrong user");
        assertEq(storedAmount, amount, "Wrong amount");
        assertTrue(sent, "Not sent");

        // 4. Verify CCTP call
        _verifyCCTPCall(requestId, amount);

        // 5. Verify USDC balances
        assertEq(usdc.balanceOf(address(cctpBridger)), amount, "USDC not in bridger");
        assertEq(usdc.balanceOf(user), 90e6, "User balance incorrect");
    }

    function _createAggregationRequest(uint256 amount) internal returns (bytes32) {
        uint32 refundChain = 40161;
        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40161;
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = amount;

        vm.deal(user, 0.1 ether);
        vm.prank(user);
        return instantAggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            amount,
            refundChain,
            sourceChains,
            expectedAmounts
        );
    }

    function _verifyCCTPCall(bytes32 requestId, uint256 expectedAmount) internal {
        (
            uint256 cctpAmount,
            uint32 destDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destCaller,
            uint256 maxFee,
            uint32 minFinality,
            bytes memory hookData,
            address caller
        ) = tokenMessenger.last();

        assertEq(cctpAmount, expectedAmount, "Wrong amount");
        assertEq(destDomain, 6, "Wrong domain");
        assertEq(address(uint160(uint256(mintRecipient))), address(instantAggregator), "Wrong recipient");
        assertEq(burnToken, address(usdc), "Wrong token");
        assertEq(address(uint160(uint256(destCaller))), address(instantAggregator), "Wrong caller");
        assertEq(maxFee, 1000000, "Wrong max fee");
        assertEq(minFinality, 1000, "Wrong min finality");
        assertEq(bytes32(hookData), requestId, "Wrong hook data");
        assertEq(caller, address(cctpBridger), "Wrong caller");
    }

    function test_cctpBridger_direct_call() public {
        // Test calling CctpBridger directly
        uint256 amount = 5e6;
        address destRecipient = address(0xBEEF);

        // Transfer USDC to CctpBridger first
        usdc.mint(address(this), amount);
        usdc.approve(address(cctpBridger), amount);

        // Call bridgeUSDCV2
        bytes32 messageHash = cctpBridger.bridgeUSDCV2(
            amount,
            6, // Base domain
            destRecipient,
            address(0), // No dest caller
            0, // No fast fee
            2000, // Standard finality
            bytes("test-hook-data")
        );

        // Verify the mock was called
        (
            uint256 cctpAmount,
            uint32 destDomain,
            bytes32 mintRecipient,
            ,,,,,
        ) = tokenMessenger.last();

        assertEq(cctpAmount, amount, "Wrong amount");
        assertEq(destDomain, 6, "Wrong domain");
        assertEq(address(uint160(uint256(mintRecipient))), destRecipient, "Wrong recipient");
        assertTrue(messageHash != bytes32(0), "No message hash returned");
    }
}
