// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "./InstantAggregatorHarness.sol";
import { Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract MockERC20 {
    mapping(address => uint256) public balances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function setBalance(address account, uint256 balance) external {
        balances[account] = balance;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
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

    function sendCompose(
        address,
        bytes32,
        uint16,
        bytes calldata
    ) external {}

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

contract MockSwapRouter {
    MockERC20 public usdc;

    // Mock exchange rates (for testing)
    mapping(address => uint256) public exchangeRates; // tokenIn => USDC per token (6 decimals)

    constructor(address _usdc) {
        usdc = MockERC20(_usdc);
    }

    function setExchangeRate(address token, uint256 rate) external {
        exchangeRates[token] = rate;
    }

    function exactInputSingle(
        ISwapRouter.ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        // Transfer tokenIn from sender
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Calculate USDC out based on mock exchange rate
        uint256 rate = exchangeRates[params.tokenIn];
        require(rate > 0, "Exchange rate not set");

        // For simplicity: amountOut = amountIn * rate / 1e18 (assuming 18 decimal tokens)
        amountOut = (params.amountIn * rate) / 1e18;

        // Transfer USDC to recipient
        usdc.setBalance(params.recipient, usdc.balanceOf(params.recipient) + amountOut);

        return amountOut;
    }
}

// Import for type checking
import { ISwapRouter } from "../../contracts/interfaces/ISwapRouter.sol";

contract InstantAggregatorTest is Test {
    InstantAggregatorHarness public aggregator;
    MockERC20 public usdcOFTAdapter;
    MockERC20 public usdcToken;
    MockERC20 public arbToken;
    MockERC20 public ethToken;
    MockLayerZeroEndpointV2 public endpoint;
    MockSwapRouter public swapRouter;

    address public user = address(0x1);
    address public merchant = address(0x2);
    address public owner = address(this);

    uint32 public baseEid = 40245;
    uint32 public arbitrumEid = 40231;
    uint32 public optimismEid = 40232;

    event InstantAggregationInitiated(
        bytes32 indexed requestId,
        address indexed user,
        address indexed merchant,
        uint256 targetAmount
    );

    event LockConfirmed(
        bytes32 indexed requestId,
        uint32 indexed sourceChain,
        uint256 amount,
        uint256 totalLocked
    );

    event InstantSettlement(
        bytes32 indexed requestId,
        address indexed merchant,
        uint256 usdcAmount,
        uint256 timeElapsed
    );

    event TokenSwapped(
        bytes32 indexed requestId,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcOut
    );

    function setUp() public {
        endpoint = new MockLayerZeroEndpointV2();
        usdcOFTAdapter = new MockERC20();
        usdcToken = new MockERC20();
        arbToken = new MockERC20();
        ethToken = new MockERC20();

        aggregator = new InstantAggregatorHarness(
            address(endpoint),
            address(usdcOFTAdapter),
            owner
        );

        // Setup swap router
        swapRouter = new MockSwapRouter(address(usdcToken));
        aggregator.setSwapConfig(address(swapRouter), address(usdcToken));

        // Set mock exchange rates
        // ARB: 1 ARB = 0.5 USDC (0.5e6 USDC per 1e18 ARB)
        swapRouter.setExchangeRate(address(arbToken), 0.5e6);
        // ETH: 1 ETH = 2000 USDC (2000e6 USDC per 1e18 ETH)
        swapRouter.setExchangeRate(address(ethToken), 2000e6);

        // Fund adapter with USDC for testing
        usdcOFTAdapter.setBalance(address(aggregator), 10000e6);

        // Fund swap router with USDC for swaps
        usdcToken.setBalance(address(swapRouter), 100000e6);

        // Fund aggregator with tokens for swap testing
        arbToken.setBalance(address(aggregator), 1000e18);
        ethToken.setBalance(address(aggregator), 100e18);
    }

    function testInitiateInstantAggregation() public {
        vm.deal(user, 1 ether);

        uint32[] memory sourceChains = new uint32[](3);
        sourceChains[0] = arbitrumEid;
        sourceChains[1] = optimismEid;
        sourceChains[2] = baseEid;

        uint256[] memory expectedAmounts = new uint256[](3);
        expectedAmounts[0] = 200e6;
        expectedAmounts[1] = 150e6;
        expectedAmounts[2] = 150e6;

        vm.prank(user);
        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            500e6, // 500 USDC target (full amount required)
            baseEid,
            sourceChains,
            expectedAmounts
        );

        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(request.user, user);
        assertEq(request.merchant, merchant);
        assertEq(request.targetAmount, 500e6);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.PENDING));
    }

    function testLockConfirmationAndInstantSettle() public {
        // Setup aggregation request
        vm.deal(user, 1 ether);
        vm.prank(user);

        uint32[] memory sourceChains = new uint32[](2);
        sourceChains[0] = arbitrumEid;
        sourceChains[1] = optimismEid;

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 300e6;
        expectedAmounts[1] = 200e6;

        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            500e6,
            baseEid,
            sourceChains,
            expectedAmounts
        );

        uint256 startTime = block.timestamp;

        // Simulate lock confirmations
        Origin memory origin1 = Origin({
            srcEid: arbitrumEid,
            sender: bytes32(uint256(uint160(address(this)))),
            nonce: 1
        });

        bytes memory message1 = abi.encode(requestId, 300e6, startTime);

        uint256 merchantUsdcBefore = usdcOFTAdapter.balanceOf(merchant);

        // First lock - 300 USDC (60%)
        aggregator.exposed_lzReceive(
            origin1,
            bytes32(uint256(1)),
            message1,
            address(0),
            ""
        );

        // Check lock confirmed but not settled yet (only 60%)
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 300e6);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.PENDING));

        // Second lock - 200 USDC (total 100%, triggers instant settlement at 90%)
        Origin memory origin2 = Origin({
            srcEid: optimismEid,
            sender: bytes32(uint256(uint160(address(this)))),
            nonce: 2
        });

        bytes memory message2 = abi.encode(requestId, 200e6, startTime);

        aggregator.exposed_lzReceive(
            origin2,
            bytes32(uint256(2)),
            message2,
            address(0),
            ""
        );

        // Check instant settlement occurred
        request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 500e6);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED));
        assertEq(request.usdcSettledAmount, 500e6);

        // Merchant should have received USDC
        assertEq(usdcOFTAdapter.balanceOf(merchant), merchantUsdcBefore + 500e6);
    }

    function testInstantSettleWithFullAmount() public {
        vm.deal(user, 1 ether);
        vm.prank(user);

        uint32[] memory sourceChains = new uint32[](2);
        sourceChains[0] = arbitrumEid;
        sourceChains[1] = optimismEid;

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 450e6;
        expectedAmounts[1] = 50e6;

        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            500e6, // Full amount required
            baseEid,
            sourceChains,
            expectedAmounts
        );

        uint256 startTime = block.timestamp;
        uint256 merchantUsdcBefore = usdcOFTAdapter.balanceOf(merchant);

        // First lock - 500 USDC (100% - full amount)
        Origin memory origin = Origin({
            srcEid: arbitrumEid,
            sender: bytes32(uint256(uint160(address(this)))),
            nonce: 1
        });

        bytes memory message = abi.encode(requestId, 500e6, startTime);

        aggregator.exposed_lzReceive(
            origin,
            bytes32(uint256(1)),
            message,
            address(0),
            ""
        );

        // Should trigger instant settlement at exactly 100%
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED));
        assertEq(usdcOFTAdapter.balanceOf(merchant), merchantUsdcBefore + 500e6);
    }

    // Note: testResolveToNativeUSDC and testReceiveNativeUSDCAutoResolve removed
    // With OFTAdapter, merchant receives actual USDC directly - no resolution needed

    function testCanInstantSettle() public {
        vm.deal(user, 1 ether);
        vm.prank(user);

        uint32[] memory sourceChains = new uint32[](1);
        sourceChains[0] = arbitrumEid;

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 500e6;

        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            500e6,
            baseEid,
            sourceChains,
            expectedAmounts
        );

        assertFalse(aggregator.canInstantSettle(requestId));

        // Lock 450 USDC (90% threshold)
        Origin memory origin = Origin({
            srcEid: arbitrumEid,
            sender: bytes32(uint256(uint160(address(this)))),
            nonce: 1
        });

        bytes memory message = abi.encode(requestId, 450e6, block.timestamp);

        aggregator.exposed_lzReceive(
            origin,
            bytes32(uint256(1)),
            message,
            address(0),
            ""
        );

        // Should have auto-settled, so canInstantSettle is false (already settled)
        assertFalse(aggregator.canInstantSettle(requestId));
    }

    function testMultipleChainParallelLocks() public {
        vm.deal(user, 1 ether);
        vm.prank(user);

        // 7 chains scenario
        uint32[] memory sourceChains = new uint32[](7);
        uint256[] memory expectedAmounts = new uint256[](7);

        sourceChains[0] = 40231; // Arbitrum
        sourceChains[1] = 40232; // Optimism
        sourceChains[2] = 40245; // Base
        sourceChains[3] = 40109; // Polygon
        sourceChains[4] = 40161; // Ethereum
        sourceChains[5] = 40106; // Avalanche
        sourceChains[6] = 40102; // BSC

        expectedAmounts[0] = 100e6;
        expectedAmounts[1] = 50e6;
        expectedAmounts[2] = 100e6;
        expectedAmounts[3] = 75e6;
        expectedAmounts[4] = 75e6;
        expectedAmounts[5] = 50e6;
        expectedAmounts[6] = 50e6;

        bytes32 requestId = aggregator.initiateInstantAggregation{value: 0.01 ether}(
            merchant,
            500e6, // Full amount required
            baseEid,
            sourceChains,
            expectedAmounts
        );

        uint256 startTime = block.timestamp;
        uint256 merchantUsdcBefore = usdcOFTAdapter.balanceOf(merchant);

        // Simulate parallel lock arrivals - must receive ALL 7 locks
        Origin memory origin = Origin({
            srcEid: sourceChains[0],
            sender: bytes32(uint256(uint160(address(this)))),
            nonce: 1
        });

        // Locks 1-6 arrive but not enough yet
        for (uint i = 0; i < 6; i++) {
            origin.srcEid = sourceChains[i];
            aggregator.exposed_lzReceive(
                origin,
                bytes32(uint256(i + 1)),
                abi.encode(requestId, expectedAmounts[i], startTime),
                address(0),
                ""
            );
        }

        // Check still pending (only 450/500 = 90%)
        InstantAggregator.InstantAggregationRequest memory request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 450e6);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.PENDING));

        // Lock 7: 50 USDC (100% - FULL AMOUNT!)
        origin.srcEid = sourceChains[6];
        aggregator.exposed_lzReceive(
            origin,
            bytes32(uint256(7)),
            abi.encode(requestId, expectedAmounts[6], startTime),
            address(0),
            ""
        );

        // Should have instant settled at 500 USDC (100%)
        request = aggregator.getRequest(requestId);
        assertEq(request.totalLocked, 500e6);
        assertEq(uint(request.status), uint(InstantAggregator.SettlementStatus.SETTLED));
        assertEq(usdcOFTAdapter.balanceOf(merchant), merchantUsdcBefore + 500e6);
    }
}
