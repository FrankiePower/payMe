// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../../contracts/CctpBridger.sol";
import "../../contracts/SourceChainInitiator.sol";
import "../../contracts/InstantAggregator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PayMeCCTPForkTest
 * @notice Fork test for PayMe CCTP integration
 * @dev Tests the full flow: User → SourceChainInitiator → CCTP → InstantAggregator → Merchant
 */
contract PayMeCCTPForkTest is Test {
    // Sepolia Testnet Addresses
    address constant ETH_SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address constant ETH_SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ETH_SEPOLIA_TOKEN_MESSENGER = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
    address constant ETH_SEPOLIA_MESSAGE_TRANSMITTER = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;

    address constant BASE_SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant BASE_SEPOLIA_MESSAGE_TRANSMITTER = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
    address constant BASE_SEPOLIA_SWAP_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    // Test actors
    address owner = address(0x1);
    address user = address(0x2);
    address merchant = address(0x3);

    // Contracts on ETH Sepolia
    CctpBridger cctpBridger;
    SourceChainInitiator sourceChainInitiator;

    // Contracts on Base Sepolia
    InstantAggregator instantAggregator;

    function setUp() public {
        // Fork ETH Sepolia for source chain setup
        vm.createSelectFork(vm.envString("ETH_SEPOLIA_RPC"));

        // Deploy CctpBridger on ETH Sepolia
        vm.startPrank(owner);
        cctpBridger = new CctpBridger(ETH_SEPOLIA_TOKEN_MESSENGER, ETH_SEPOLIA_USDC);

        // Deploy SourceChainInitiator on ETH Sepolia
        sourceChainInitiator = new SourceChainInitiator(
            ETH_SEPOLIA_ENDPOINT,
            ETH_SEPOLIA_USDC,
            address(cctpBridger),
            owner
        );
        vm.stopPrank();

        // Switch to Base Sepolia fork
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"));

        // Deploy InstantAggregator on Base Sepolia
        vm.startPrank(owner);
        instantAggregator = new InstantAggregator(
            BASE_SEPOLIA_ENDPOINT,
            BASE_SEPOLIA_MESSAGE_TRANSMITTER,
            owner
        );

        // Configure InstantAggregator
        instantAggregator.setSwapConfig(BASE_SEPOLIA_SWAP_ROUTER, BASE_SEPOLIA_USDC);
        vm.stopPrank();
    }

    function test_deployment_addresses_exist() public {
        // Verify ETH Sepolia deployment
        vm.selectFork(0); // ETH Sepolia fork
        assertTrue(address(cctpBridger) != address(0), "CctpBridger not deployed");
        assertTrue(address(sourceChainInitiator) != address(0), "SourceChainInitiator not deployed");
        assertEq(sourceChainInitiator.owner(), owner, "Wrong owner");

        // Verify Base Sepolia deployment
        vm.selectFork(1); // Base Sepolia fork
        assertTrue(address(instantAggregator) != address(0), "InstantAggregator not deployed");
        assertEq(instantAggregator.owner(), owner, "Wrong owner");
    }

    function test_cctpBridger_configuration() public {
        vm.selectFork(0); // ETH Sepolia

        assertEq(address(cctpBridger.messenger()), ETH_SEPOLIA_TOKEN_MESSENGER, "Wrong messenger");
        assertEq(address(cctpBridger.usdc()), ETH_SEPOLIA_USDC, "Wrong USDC");
    }

    function test_sourceChainInitiator_register_aggregator() public {
        vm.selectFork(0); // ETH Sepolia

        uint32 baseEid = 40245;

        vm.prank(owner);
        sourceChainInitiator.registerAggregator(baseEid, address(instantAggregator));

        assertEq(
            sourceChainInitiator.aggregatorByEid(baseEid),
            address(instantAggregator),
            "Aggregator not registered"
        );
    }

    function test_sourceChainInitiator_register_cctp_domain() public {
        vm.selectFork(0); // ETH Sepolia

        uint32 baseEid = 40245;
        uint32 baseDomain = 6;

        vm.prank(owner);
        sourceChainInitiator.registerCCTPDomain(baseEid, baseDomain);

        assertEq(
            sourceChainInitiator.cctpDomainByEid(baseEid),
            baseDomain,
            "CCTP domain not registered"
        );
    }

    function test_instantAggregator_create_request() public {
        vm.selectFork(1); // Base Sepolia

        uint256 targetAmount = 10e6; // 10 USDC
        uint32 refundChain = 40161; // ETH Sepolia

        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40161; // ETH Sepolia

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 10e6; // 10 USDC

        vm.deal(user, 0.1 ether); // Give user some ETH for refund gas
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
            ,,,,, // totalLocked, destinationChain, refundChain, deadline, refundGasDeposit
            , // status (SettlementStatus enum)
            bool exists,
            // usdcSettledAmount
        ) = instantAggregator.requests(requestId);

        assertEq(storedRequestId, requestId, "Wrong request ID");
        assertEq(storedUser, user, "Wrong user");
        assertEq(storedMerchant, merchant, "Wrong merchant");
        assertEq(storedTargetAmount, targetAmount, "Wrong target amount");
        assertTrue(exists, "Request not created");
    }

    function test_full_flow_simulation() public {
        // This test simulates the full flow but doesn't actually execute CCTP
        // because we can't bridge between forks in a single test

        // 1. Setup on Base Sepolia
        vm.selectFork(1);
        uint256 amount = 10e6;

        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40161; // ETH Sepolia

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 10e6; // 10 USDC

        vm.deal(user, 0.1 ether);
        vm.prank(user);
        bytes32 requestId = instantAggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            amount,
            40161, // refundChain: ETH Sepolia
            sourceChains,
            expectedAmounts
        );

        // 2. Setup on ETH Sepolia
        vm.selectFork(0);

        vm.startPrank(owner);
        sourceChainInitiator.registerAggregator(40245, address(instantAggregator));
        sourceChainInitiator.registerCCTPDomain(40245, 6);
        vm.stopPrank();

        // 3. Simulate user having USDC
        deal(ETH_SEPOLIA_USDC, user, 100e6);

        // 4. Approve USDC to CctpBridger
        vm.startPrank(user);
        IERC20(ETH_SEPOLIA_USDC).approve(address(cctpBridger), amount);

        // 5. User cannot directly call sendToAggregator yet because
        //    SourceChainInitiator expects to pull from user, not from itself
        //    So we approve SourceChainInitiator
        IERC20(ETH_SEPOLIA_USDC).approve(address(sourceChainInitiator), amount);

        // 6. Send to aggregator (this would trigger CCTP in real scenario)
        bytes32 transferId = sourceChainInitiator.sendToAggregator(
            requestId,
            amount,
            40245, // Base
            true // Fast mode
        );
        vm.stopPrank();

        // Verify transfer was recorded
        (
            bytes32 storedRequestId,
            address storedUser,
            uint256 storedAmount,
            ,,,
            bool sent
        ) = sourceChainInitiator.pendingTransfers(transferId);

        assertEq(storedRequestId, requestId, "Wrong request ID in transfer");
        assertEq(storedUser, user, "Wrong user in transfer");
        assertEq(storedAmount, amount, "Wrong amount in transfer");
        assertTrue(sent, "Transfer not marked as sent");
    }
}
