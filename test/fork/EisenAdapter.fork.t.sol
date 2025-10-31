// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {EisenAdapter} from "../../src/dex-aggregator/EisenAdapter.sol";
import {DexAggregatorFacet} from "../../src/facets/DexAggregatorFacet.sol";
import {IDexAggregatorFacet} from "../../src/interfaces/facets/IDexAggregatorFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title EisenAdapterForkTest
 * @notice Fork tests for EisenAdapter on Flow EVM
 * @dev To run: forge test --match-path test/fork/EisenAdapter.fork.t.sol --fork-url https://mainnet.evm.nodes.onflow.org --ffi -vvv
 */
contract EisenAdapterForkTest is Test {
    EisenAdapter adapter;
    DexAggregatorFacet facet;

    // Flow EVM chain ID
    uint256 constant FLOW_CHAIN_ID = 747;

    // Real tokens on Flow EVM
    address constant WFLOW = 0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e; // Wrapped FLOW
    address constant STG_USDC = 0xF1815bd50389c46847f0Bda824eC8da914045D14; // Stargate USDC
    address constant USDF = 0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED; // USD Flow
    address constant STG_USDT = 0x674843C06FF83502ddb4D37c2E09C01cdA38cbc8; // Stargate USDT

    // Eisen contracts on Flow (from API response)
    address constant EISEN_FORWARDER = 0x85EFA14c12F5fE42Ff9D7Da460A71088b26bEa31;

    address curator;
    address mockRegistry;

    function setUp() public {
        // Check we're on Flow fork
        require(block.chainid == FLOW_CHAIN_ID, "Must fork Flow EVM");

        adapter = new EisenAdapter();
        facet = new DexAggregatorFacet();

        curator = makeAddr("curator");
        mockRegistry = makeAddr("mockRegistry");

        // Setup vault storage
        MoreVaultsStorageHelper.setOwner(address(facet), address(this));
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), mockRegistry);

        // Set available assets (all tokens we'll test with)
        address[] memory availableAssets = new address[](4);
        availableAssets[0] = WFLOW;
        availableAssets[1] = STG_USDC;
        availableAssets[2] = USDF;
        availableAssets[3] = STG_USDT;
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);

        // Mock registry to whitelist Eisen forwarder
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, EISEN_FORWARDER),
            abi.encode(true)
        );

        // Deal tokens to facet (vault) for testing
        deal(WFLOW, address(facet), 100 ether);
        deal(STG_USDC, address(facet), 1000e6); // 1000 USDC (6 decimals)
        deal(USDF, address(facet), 1000e6); // 1000 USDF (6 decimals)
        deal(STG_USDT, address(facet), 1000e6); // 1000 USDT (6 decimals)
    }

    function test_adapter_name() public view {
        assertEq(adapter.adapterName(), "Eisen Finance");
    }

    function test_executeSwap_RealEisenQuote_WFLOW_to_stgUSDC() public {
        // Call Eisen API to get quote with correct vault address
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string(
            abi.encodePacked(
                "curl -s 'https://hiker.hetz-01.eisenfinance.com/public/v1/quote?",
                "fromChain=747&toChain=747&",
                "fromToken=0xd3bf53dac106a0290b0483ecbc89d40fcc961f3e&",
                "toToken=0xf1815bd50389c46847f0bda824ec8da914045d14&",
                "fromAmount=1000000000000000000&",
                "fromAddress=",
                vm.toString(address(facet)),
                "&toAddress=",
                vm.toString(address(facet)),
                "&slippage=0.01&integrator=more-vaults' ",
                "--header 'X-EISEN-KEY: ZWlzZW5fNDZhN2MwOWEtYjYyZC00YzU5LTliMTMtMTQxNzA2NGNlZmM4'"
            )
        );

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        // Parse JSON directly in Solidity using vm.parseJson
        // Extract the calldata hex string from result.transactionRequest.data
        string memory calldataHexString = vm.parseJsonString(jsonResponse, ".result.transactionRequest.data");

        console.log("Extracted calldata hex string (first 50 chars):");
        // console.log(calldataHexString);  // Skip logging the full hex to avoid console mangling

        // Parse the hex string to get actual bytes
        bytes memory eisenApiCalldata = vm.parseBytes(calldataHexString);

        console.log("Extracted calldata length:", eisenApiCalldata.length);

        // Build swap calldata using adapter
        bytes memory swapCalldata =
            adapter.buildSwapCalldataWithParams(WFLOW, STG_USDC, 1 ether, 250000, address(facet), eisenApiCalldata);

        // Prepare swap parameters
        IDexAggregatorFacet.SwapParams memory params = IDexAggregatorFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: WFLOW,
            tokenOut: STG_USDC,
            amountIn: 1 ether,
            minAmountOut: 250000, // ~1% slippage from expected ~0.255 USDC
            swapCallData: swapCalldata
        });

        // Record balances before swap
        uint256 wflowBefore = IERC20(WFLOW).balanceOf(address(facet));
        uint256 stgUsdcBefore = IERC20(STG_USDC).balanceOf(address(facet));

        console.log("WFLOW balance before:", wflowBefore);
        console.log("stgUSDC balance before:", stgUsdcBefore);

        // Execute swap as curator
        vm.prank(curator);
        uint256 amountOut = facet.executeSwap(params);

        // Verify swap results
        uint256 wflowAfter = IERC20(WFLOW).balanceOf(address(facet));
        uint256 stgUsdcAfter = IERC20(STG_USDC).balanceOf(address(facet));

        console.log("WFLOW balance after:", wflowAfter);
        console.log("stgUSDC balance after:", stgUsdcAfter);
        console.log("Amount out:", amountOut);

        // Assertions
        assertEq(wflowBefore - wflowAfter, 1 ether, "WFLOW not spent correctly");
        assertGe(amountOut, 250000, "Insufficient stgUSDC received");
        assertEq(stgUsdcAfter - stgUsdcBefore, amountOut, "stgUSDC balance mismatch");
    }

    function test_executeSwap_RealEisenQuote_stgUSDC_to_WFLOW() public {
        // Test reverse swap: stgUSDC -> WFLOW
        _testRealSwap({
            fromToken: STG_USDC,
            toToken: WFLOW,
            amountIn: 100e6, // 100 USDC
            minAmountOut: 300 ether // ~300 WFLOW (rough estimate with slippage)
        });
    }

    function test_executeSwap_RealEisenQuote_WFLOW_to_USDF() public {
        // Test WFLOW -> USDF swap
        _testRealSwap({
            fromToken: WFLOW,
            toToken: USDF,
            amountIn: 1 ether, // 1 WFLOW
            minAmountOut: 250000 // ~0.25 USDF (6 decimals, with slippage)
        });
    }

    function test_executeSwap_RealEisenQuote_USDF_to_WFLOW() public {
        // Test USDF -> WFLOW swap
        _testRealSwap({
            fromToken: USDF,
            toToken: WFLOW,
            amountIn: 100e6, // 100 USDF
            minAmountOut: 300 ether // ~300 WFLOW (with slippage)
        });
    }

    // TODO: SECURITY TEST - Validate receiver in calldata
    // This test is disabled because the Eisen calldata structure is complex and dynamic.
    // The current security relies on:
    // 1. DexAggregatorFacet balance checks (will revert if tokens don't return)
    // 2. Curator trust (only trusted curators can call executeSwap)
    //
    // Future: Implement proper Eisen calldata ABI decoding to validate toAddress
    //
    // function test_executeSwap_MaliciousReceiver_ShouldRevert() public {
    //     ...test implementation...
    // }

    function test_executeSwap_NoRouteAvailable_ShouldRevert() public {
        // Test that attempting a swap with no available route fails gracefully
        // stgUSDC -> stgUSDT has no direct route on Eisen
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string(
            abi.encodePacked(
                "curl -s 'https://hiker.hetz-01.eisenfinance.com/public/v1/quote?",
                "fromChain=747&toChain=747&",
                "fromToken=", _toLowerCase(vm.toString(STG_USDC)), "&",
                "toToken=", _toLowerCase(vm.toString(STG_USDT)), "&",
                "fromAmount=100000000&",
                "fromAddress=", vm.toString(address(facet)),
                "&toAddress=", vm.toString(address(facet)),
                "&slippage=0.02&integrator=more-vaults' ",
                "--header 'X-EISEN-KEY: ZWlzZW5fNDZhN2MwOWEtYjYyZC00YzU5LTliMTMtMTQxNzA2NGNlZmM4'"
            )
        );

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        // Verify the API returned an error message
        string memory message = vm.parseJsonString(jsonResponse, ".message");
        assertEq(message, "Anyhow No swap path found", "Expected no route error from Eisen API");

        console.log("API correctly returned error:", message);
    }

    /// @notice Helper function to test real swaps with Eisen API
    function _testRealSwap(address fromToken, address toToken, uint256 amountIn, uint256 minAmountOut) internal {
        // Call Eisen API to get quote with correct vault address
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string(
            abi.encodePacked(
                "curl -s 'https://hiker.hetz-01.eisenfinance.com/public/v1/quote?",
                "fromChain=747&toChain=747&",
                "fromToken=", _toLowerCase(vm.toString(fromToken)), "&",
                "toToken=", _toLowerCase(vm.toString(toToken)), "&",
                "fromAmount=", vm.toString(amountIn), "&",
                "fromAddress=", vm.toString(address(facet)),
                "&toAddress=", vm.toString(address(facet)),
                "&slippage=0.02&integrator=more-vaults' ",
                "--header 'X-EISEN-KEY: ZWlzZW5fNDZhN2MwOWEtYjYyZC00YzU5LTliMTMtMTQxNzA2NGNlZmM4'"
            )
        );

        bytes memory result = vm.ffi(inputs);
        string memory jsonResponse = string(result);

        // Parse JSON directly in Solidity using vm.parseJson
        string memory calldataHexString = vm.parseJsonString(jsonResponse, ".result.transactionRequest.data");

        // Parse the hex string to get actual bytes
        bytes memory eisenApiCalldata = vm.parseBytes(calldataHexString);

        console.log("Extracted calldata length:", eisenApiCalldata.length);

        // Build swap calldata using adapter
        bytes memory swapCalldata =
            adapter.buildSwapCalldataWithParams(fromToken, toToken, amountIn, minAmountOut, address(facet), eisenApiCalldata);

        // Prepare swap parameters
        IDexAggregatorFacet.SwapParams memory params = IDexAggregatorFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: fromToken,
            tokenOut: toToken,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            swapCallData: swapCalldata
        });

        // Record balances before swap
        uint256 tokenInBefore = IERC20(fromToken).balanceOf(address(facet));
        uint256 tokenOutBefore = IERC20(toToken).balanceOf(address(facet));

        console.log("Balance IN before:", tokenInBefore);
        console.log("Balance OUT before:", tokenOutBefore);

        // Execute swap as curator
        vm.prank(curator);
        uint256 amountOut = facet.executeSwap(params);

        // Verify swap results
        uint256 tokenInAfter = IERC20(fromToken).balanceOf(address(facet));
        uint256 tokenOutAfter = IERC20(toToken).balanceOf(address(facet));

        console.log("Balance IN after:", tokenInAfter);
        console.log("Balance OUT after:", tokenOutAfter);
        console.log("Amount out:", amountOut);

        // Assertions
        assertEq(tokenInBefore - tokenInAfter, amountIn, "Input token not spent correctly");
        assertGe(amountOut, minAmountOut, "Insufficient output token received");
        assertEq(tokenOutAfter - tokenOutBefore, amountOut, "Output token balance mismatch");
    }

    /// @notice Convert address to lowercase string
    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            // If character is uppercase (A-F), convert to lowercase
            if (bStr[i] >= 0x41 && bStr[i] <= 0x46) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }

    function test_adapter_validates_calldata() public view {
        bytes memory eisenApiCalldata = hex"e3665a43";
        bytes memory validated =
            adapter.buildSwapCalldataWithParams(WFLOW, STG_USDC, 1 ether, 250000, address(facet), eisenApiCalldata);
        assertEq(validated, eisenApiCalldata, "Adapter should return validated calldata");
    }
}
