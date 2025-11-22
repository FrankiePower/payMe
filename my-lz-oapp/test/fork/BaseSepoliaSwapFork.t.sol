// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISwapRouter } from "../../contracts/interfaces/ISwapRouter.sol";

/**
 * @title BaseSepoliaSwapForkTest
 * @notice Fork test to verify REAL Uniswap V3 swap functionality on Base Sepolia
 * @dev This tests against ACTUAL deployed contracts (not mocks!)
 *
 * What this proves:
 * - Real Uniswap router works with our ISwapRouter interface
 * - Real WETH → USDC swaps execute correctly
 * - Our swap parameters are valid
 * - Gas estimation is realistic
 */
contract BaseSepoliaSwapForkTest is Test {
    // Real contract addresses from .env
    address constant UNISWAP_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    ISwapRouter public swapRouter;
    IERC20 public weth;
    IERC20 public usdc;

    address public testUser = address(0x123);

    function setUp() public {
        // Fork Base Sepolia
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC"));

        swapRouter = ISwapRouter(UNISWAP_ROUTER);
        weth = IERC20(WETH);
        usdc = IERC20(USDC);

        // Give test user some ETH and deal WETH
        vm.deal(testUser, 10 ether);
    }

    /**
     * @notice Test 1: Verify Uniswap router exists and is correct contract
     */
    function test_uniswap_router_exists() public {
        // Uniswap router should have code
        uint256 codeSize;
        address router = address(swapRouter);
        assembly {
            codeSize := extcodesize(router)
        }
        assertTrue(codeSize > 0, "Uniswap router has no code");
    }

    /**
     * @notice Test 2: Verify WETH and USDC tokens exist
     */
    function test_tokens_exist() public {
        // WETH should exist
        uint256 wethCode;
        assembly {
            wethCode := extcodesize(WETH)
        }
        assertTrue(wethCode > 0, "WETH has no code");

        // USDC should exist
        uint256 usdcCode;
        assembly {
            usdcCode := extcodesize(USDC)
        }
        assertTrue(usdcCode > 0, "USDC has no code");
    }

    /**
     * @notice Test 3: Execute REAL swap: WETH → USDC
     * @dev This is the CRITICAL test - it uses the ACTUAL Uniswap contract!
     */
    function test_real_weth_to_usdc_swap() public {
        // Get WETH for test user (wrap ETH)
        vm.startPrank(testUser);

        // Wrap 0.1 ETH to WETH
        (bool success,) = WETH.call{value: 0.1 ether}("");
        require(success, "WETH wrap failed");

        uint256 wethBalance = weth.balanceOf(testUser);
        assertGt(wethBalance, 0, "No WETH balance after wrap");
        emit log_named_decimal_uint("WETH balance", wethBalance, 18);

        // Approve Uniswap router
        weth.approve(address(swapRouter), wethBalance);

        uint256 usdcBefore = usdc.balanceOf(testUser);

        // Execute REAL swap using REAL Uniswap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000, // 0.3% pool
            recipient: testUser,
            deadline: block.timestamp + 60,
            amountIn: wethBalance,
            amountOutMinimum: 0, // Accept any amount for test
            sqrtPriceLimitX96: 0
        });

        uint256 gasBefore = gasleft();
        uint256 amountOut = swapRouter.exactInputSingle(params);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        // Verify swap succeeded
        uint256 usdcAfter = usdc.balanceOf(testUser);
        uint256 usdcReceived = usdcAfter - usdcBefore;

        assertEq(amountOut, usdcReceived, "USDC amount mismatch");
        assertGt(usdcReceived, 0, "No USDC received from swap");

        // Log results
        emit log_named_decimal_uint("WETH swapped", wethBalance, 18);
        emit log_named_decimal_uint("USDC received", usdcReceived, 6);
        emit log_named_uint("Gas used for swap", gasUsed);
        emit log_string("REAL Uniswap swap successful!");
    }

    /**
     * @notice Test 4: Verify our ISwapRouter interface matches real Uniswap
     */
    function test_interface_compatibility() public {
        vm.startPrank(testUser);

        // Wrap some ETH
        (bool success,) = WETH.call{value: 0.01 ether}("");
        require(success, "WETH wrap failed");

        uint256 wethAmount = 0.01 ether;
        weth.approve(address(swapRouter), wethAmount);

        // This test passes if the function selector matches
        // If interface is wrong, this will revert
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: testUser,
            deadline: block.timestamp + 60,
            amountIn: wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // If this doesn't revert, our interface is correct
        try swapRouter.exactInputSingle(params) returns (uint256 amount) {
            assertGt(amount, 0, "Swap returned 0");
            emit log_string("Interface is compatible with real Uniswap");
        } catch {
            revert("Interface incompatible - function selector mismatch");
        }

        vm.stopPrank();
    }

    /**
     * @notice Test 5: Measure realistic gas costs
     */
    function test_gas_costs_realistic() public {
        vm.startPrank(testUser);

        // Wrap ETH
        (bool success,) = WETH.call{value: 0.1 ether}("");
        require(success);

        uint256 wethAmount = weth.balanceOf(testUser);
        weth.approve(address(swapRouter), wethAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 3000,
            recipient: testUser,
            deadline: block.timestamp + 60,
            amountIn: wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // Measure gas
        uint256 gasBefore = gasleft();
        swapRouter.exactInputSingle(params);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        // Typical Uniswap V3 swap uses 100-200k gas
        assertLt(gasUsed, 300000, "Gas too high");
        assertGt(gasUsed, 50000, "Gas too low - something wrong");

        emit log_named_uint("Actual gas used", gasUsed);
        emit log_string("Gas cost is realistic for Uniswap V3 swap");
    }
}
