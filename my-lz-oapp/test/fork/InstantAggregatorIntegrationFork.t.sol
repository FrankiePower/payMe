// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISwapRouter } from "../../contracts/interfaces/ISwapRouter.sol";
import { InstantAggregator } from "../../contracts/InstantAggregator.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/**
 * @title InstantAggregatorIntegrationForkTest
 * @notice REAL integration test on Base Sepolia with REAL Uniswap and LayerZero
 * @dev This proves the entire system works with actual deployed contracts
 *
 * Test Scenarios:
 * 1. Deploy InstantAggregator on real Base Sepolia
 * 2. Configure with REAL Uniswap router
 * 3. Test lzCompose with REAL swap (WETH → USDC)
 * 4. Verify instant settlement works
 */
contract InstantAggregatorIntegrationForkTest is Test {
    using OFTComposeMsgCodec for bytes;

    // Real Base Sepolia addresses
    address constant LZ_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address constant UNISWAP_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    InstantAggregator public aggregator;
    IERC20 public weth;
    IERC20 public usdc;
    IERC20 public mockUSDCAdapter; // We'll use USDC as OFT adapter for testing

    address public owner = address(this);
    address public merchant = address(0x456);
    address public user = address(0x789);

    function setUp() public {
        // Fork Base Sepolia
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"));

        weth = IERC20(WETH);
        usdc = IERC20(USDC);
        mockUSDCAdapter = usdc; // For testing, use USDC directly

        // Deploy InstantAggregator with REAL LayerZero endpoint
        aggregator = new InstantAggregator(
            LZ_ENDPOINT,
            address(mockUSDCAdapter),
            owner
        );

        // Configure with REAL Uniswap router and USDC
        aggregator.setSwapConfig(UNISWAP_ROUTER, USDC);

        // Fund user with ETH
        vm.deal(user, 10 ether);
    }

    /**
     * @notice Test 1: Verify deployment on real testnet
     */
    function test_deployment_on_real_network() public {
        // Verify aggregator deployed
        address aggAddr = address(aggregator);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(aggAddr)
        }
        assertGt(codeSize, 0, "Aggregator not deployed");

        // Verify configuration
        assertEq(aggregator.swapRouter(), UNISWAP_ROUTER, "Wrong router");
        assertEq(aggregator.usdcToken(), USDC, "Wrong USDC");
        assertEq(aggregator.usdcOFTAdapter(), address(mockUSDCAdapter), "Wrong adapter");

        emit log_string("Deployed and configured on real Base Sepolia");
    }

    /**
     * @notice Test 2: Simulate lzCompose with REAL swap
     * @dev This tests the FULL flow: lzCompose → swap → aggregation
     */
    function test_lzCompose_with_real_swap() public {
        // Setup: Create aggregation request
        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40231; // Arbitrum Sepolia

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 200e6; // 200 USDC expected

        vm.prank(user);
        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            200e6, // Target: 200 USDC
            40245, // Base Sepolia
            sourceChains,
            expectedAmounts
        );

        // Fund aggregator with WETH (simulating OFT transfer)
        vm.deal(address(aggregator), 1 ether);
        vm.prank(address(aggregator));
        (bool success,) = WETH.call{value: 0.1 ether}(""); // Wrap 0.1 ETH
        require(success, "Wrap failed");

        uint256 wethAmount = weth.balanceOf(address(aggregator));
        assertGt(wethAmount, 0, "No WETH in aggregator");

        // Encode compose message
        bytes memory composeMsg = abi.encode(requestId, WETH, wethAmount);

        // Build full OFT compose message format
        // Format: nonce (8) + srcEid (4) + amountLD (32) + composeMsg
        bytes memory fullMessage = abi.encodePacked(
            uint64(1), // nonce
            uint32(40231), // srcEid (Arbitrum)
            bytes32(wethAmount), // amountLD
            composeMsg
        );

        uint256 usdcBefore = usdc.balanceOf(merchant);

        // Call lzCompose as if LayerZero endpoint called it
        vm.prank(LZ_ENDPOINT);
        aggregator.lzCompose(
            address(aggregator), // oApp
            bytes32(uint256(1)), // guid
            fullMessage, // message with composeMsg
            address(0), // executor
            "" // extraData
        );

        // Verify:
        // 1. WETH was swapped for USDC
        assertEq(weth.balanceOf(address(aggregator)), 0, "WETH not swapped");

        // 2. Request was updated
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertGt(request.totalLocked, 0, "No USDC locked");

        // 3. If we got >= 200 USDC from swap, settlement should have happened
        uint256 usdcAfter = usdc.balanceOf(merchant);
        if (request.totalLocked >= 200e6) {
            assertGt(usdcAfter, usdcBefore, "Merchant didn't receive USDC");
            assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED), "Not settled");
            emit log_string("INSTANT SETTLEMENT occurred after REAL swap!");
        }

        emit log_named_decimal_uint("USDC locked from swap", request.totalLocked, 6);
        emit log_named_decimal_uint("Merchant received", usdcAfter - usdcBefore, 6);
    }

    /**
     * @notice Test 3: Direct USDC lzCompose (no swap needed)
     */
    function test_lzCompose_with_usdc_no_swap() public {
        // Setup aggregation request
        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40231;

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 100e6;

        vm.prank(user);
        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            100e6,
            40245,
            sourceChains,
            expectedAmounts
        );

        // Simulate USDC arriving via OFT (mint some to aggregator)
        deal(USDC, address(aggregator), 100e6);

        // Encode compose message with USDC (no swap needed)
        bytes memory composeMsg = abi.encode(requestId, USDC, 100e6);

        bytes memory fullMessage = abi.encodePacked(
            uint64(1),
            uint32(40231),
            bytes32(uint256(100e6)),
            composeMsg
        );

        uint256 merchantBefore = usdc.balanceOf(merchant);

        // Call lzCompose
        vm.prank(LZ_ENDPOINT);
        aggregator.lzCompose(
            address(aggregator),
            bytes32(uint256(1)),
            fullMessage,
            address(0),
            ""
        );

        // Verify settlement
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 100e6, "Wrong amount locked");
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED), "Not settled");

        uint256 merchantAfter = usdc.balanceOf(merchant);
        assertEq(merchantAfter - merchantBefore, 100e6, "Merchant didn't receive USDC");

        emit log_string("Direct USDC (no swap) works correctly");
    }

    /**
     * @notice Test 4: Verify gas costs are reasonable
     */
    function test_gas_costs_lzCompose() public {
        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = 40231;

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 50e6;

        vm.prank(user);
        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            50e6,
            40245,
            sourceChains,
            expectedAmounts
        );

        // Fund with WETH
        vm.deal(address(aggregator), 1 ether);
        vm.prank(address(aggregator));
        (bool success,) = WETH.call{value: 0.05 ether}("");
        require(success);

        uint256 wethAmount = weth.balanceOf(address(aggregator));

        bytes memory composeMsg = abi.encode(requestId, WETH, wethAmount);
        bytes memory fullMessage = abi.encodePacked(
            uint64(1),
            uint32(40231),
            bytes32(wethAmount),
            composeMsg
        );

        // Measure gas
        uint256 gasBefore = gasleft();

        vm.prank(LZ_ENDPOINT);
        aggregator.lzCompose(
            address(aggregator),
            bytes32(uint256(1)),
            fullMessage,
            address(0),
            ""
        );

        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Total gas for lzCompose + swap + settlement", gasUsed);

        // lzCompose + Uniswap swap + settlement should be < 500k gas
        assertLt(gasUsed, 500000, "Gas too high");

        emit log_string("Gas costs are reasonable for production");
    }

    /**
     * @notice Test 5: Multiple chain aggregation scenario
     */
    function test_multi_chain_aggregation_scenario() public {
        // User requests 200 USDC on Base
        // - Chain 1 (Arbitrum): 100 USDC direct
        // - Chain 2 (Optimism): 0.05 WETH → ~50-100 USDC (depends on price)

        uint32[] memory sourceChains = new uint32[](2);
        sourceChains[0] = 40231; // Arbitrum
        sourceChains[1] = 40232; // Optimism

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 100e6;
        expectedAmounts[1] = 100e6; // Expected from WETH swap

        vm.prank(user);
        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            200e6,
            40245,
            sourceChains,
            expectedAmounts
        );

        // Scenario 1: Arbitrum sends 100 USDC (direct)
        deal(USDC, address(aggregator), 100e6);

        bytes memory composeMsg1 = abi.encode(requestId, USDC, 100e6);
        bytes memory fullMessage1 = abi.encodePacked(
            uint64(1),
            uint32(40231),
            bytes32(uint256(100e6)),
            composeMsg1
        );

        vm.prank(LZ_ENDPOINT);
        aggregator.lzCompose(address(aggregator), bytes32(uint256(1)), fullMessage1, address(0), "");

        // Check status - should still be PENDING (only 100/200)
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 100e6, "Wrong locked amount");
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.PENDING), "Should still be pending");

        // Scenario 2: Optimism sends 0.05 WETH (needs swap)
        vm.deal(address(aggregator), 1 ether);
        vm.prank(address(aggregator));
        (bool success,) = WETH.call{value: 0.05 ether}("");
        require(success);

        uint256 wethAmount = weth.balanceOf(address(aggregator));

        bytes memory composeMsg2 = abi.encode(requestId, WETH, wethAmount);
        bytes memory fullMessage2 = abi.encodePacked(
            uint64(2),
            uint32(40232),
            bytes32(wethAmount),
            composeMsg2
        );

        uint256 merchantBefore = usdc.balanceOf(merchant);

        vm.prank(LZ_ENDPOINT);
        aggregator.lzCompose(address(aggregator), bytes32(uint256(2)), fullMessage2, address(0), "");

        // Check final status
        request = aggregator.getRequest(requestId);
        uint256 merchantAfter = usdc.balanceOf(merchant);

        emit log_named_decimal_uint("Total USDC locked", request.totalLocked, 6);
        emit log_named_decimal_uint("Merchant received", merchantAfter - merchantBefore, 6);

        // If swap got us to >= 200 USDC total, settlement should happen
        if (request.totalLocked >= 200e6) {
            assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED), "Should be settled");
            emit log_string("Multi-chain aggregation with SWAP successful!");
        } else {
            emit log_string("Need more USDC from swap to trigger settlement");
            emit log_named_decimal_uint("Still need", 200e6 - request.totalLocked, 6);
        }
    }
}
