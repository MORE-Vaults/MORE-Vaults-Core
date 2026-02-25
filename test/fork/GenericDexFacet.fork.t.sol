// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {GenericDexFacet} from "../../src/facets/GenericDexFacet.sol";
import {IGenericDexFacet} from "../../src/interfaces/facets/IGenericDexFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title GenericDexFacetForkTest
 * @notice Fork tests for GenericDexFacet using Eisen Finance on Flow EVM mainnet
 * @dev To run:
 *      forge test --match-path test/fork/GenericDexFacet.fork.t.sol \
 *        --fork-url https://mainnet.evm.nodes.onflow.org --ffi -vvv
 *
 * @dev executeSwap/executeBatchSwap require msg.sender == address(this) (validateDiamond),
 *      so all swap calls use vm.prank(address(facet)) to simulate a self-call
 *      as would happen via the diamond's MulticallFacet.
 */
contract GenericDexFacetForkTest is Test {
    GenericDexFacet public facet;

    // Flow EVM mainnet chain ID
    uint256 constant FLOW_CHAIN_ID = 747;

    // Real tokens on Flow EVM
    address constant WFLOW    = 0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e;
    address constant STG_USDC = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
    address constant USDF     = 0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED;
    address constant STG_USDT = 0x674843C06FF83502ddb4D37c2E09C01cdA38cbc8;

    // Eisen Finance forwarder on Flow EVM
    address constant EISEN_FORWARDER = 0x85EFA14c12F5fE42Ff9D7Da460A71088b26bEa31;

    // Eisen API key (public integrator key)
    string constant EISEN_API_KEY = "ZWlzZW5fNDZhN2MwOWEtYjYyZC00YzU5LTliMTMtMTQxNzA2NGNlZmM4";

    address mockRegistry;

    function setUp() public {
        require(block.chainid == FLOW_CHAIN_ID, "Must fork Flow EVM mainnet");

        facet = new GenericDexFacet();
        mockRegistry = makeAddr("mockRegistry");

        // Wire storage slots
        MoreVaultsStorageHelper.setOwner(address(facet), address(this));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), mockRegistry);

        // Register all tokens we'll swap as available assets
        address[] memory availableAssets = new address[](4);
        availableAssets[0] = WFLOW;
        availableAssets[1] = STG_USDC;
        availableAssets[2] = USDF;
        availableAssets[3] = STG_USDT;
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);

        // Whitelist Eisen forwarder in the mock registry
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, EISEN_FORWARDER),
            abi.encode(true)
        );

        // Fund the facet (simulates vault holding tokens)
        deal(WFLOW,    address(facet), 100 ether);
        deal(STG_USDC, address(facet), 1000e6);
        deal(USDF,     address(facet), 1000e6);
        deal(STG_USDT, address(facet), 1000e6);
    }

    // =========================================================================
    // executeSwap — single swap tests
    // =========================================================================

    // 1 WFLOW ≈ $0.036 → ~35000 USDC units (6 dec). Min set with ~30% buffer.
    function test_executeSwap_WFLOW_to_stgUSDC() public {
        _testSwap(WFLOW, STG_USDC, 1 ether, 20000);
    }

    // 100 USDC → ~2700 WFLOW at current price. Min set with ~30% buffer.
    function test_executeSwap_stgUSDC_to_WFLOW() public {
        _testSwap(STG_USDC, WFLOW, 100e6, 1500 ether);
    }

    // 1 WFLOW ≈ $0.036 → ~35000 USDF units (6 dec). Min set with ~30% buffer.
    function test_executeSwap_WFLOW_to_USDF() public {
        _testSwap(WFLOW, USDF, 1 ether, 20000);
    }

    // =========================================================================
    // executeBatchSwap — multiple swaps in one call
    // =========================================================================

    // Two independent WFLOW swaps: WFLOW→stgUSDC and WFLOW→USDF
    // Using WFLOW as tokenIn for both avoids balance conflicts between swaps.
    function test_executeBatchSwap_two_swaps() public {
        bytes memory calldata1 = _fetchEisenCalldata(WFLOW, STG_USDC, 1 ether);
        bytes memory calldata2 = _fetchEisenCalldata(WFLOW, USDF,     1 ether);

        IGenericDexFacet.SwapParams[] memory swaps = new IGenericDexFacet.SwapParams[](2);
        swaps[0] = IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn:        WFLOW,
            tokenOut:       STG_USDC,
            maxAmountIn:    1 ether,
            minAmountOut:   20000,
            swapCallData:   calldata1
        });
        swaps[1] = IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn:        WFLOW,
            tokenOut:       USDF,
            maxAmountIn:    1 ether,
            minAmountOut:   20000,
            swapCallData:   calldata2
        });

        uint256 wflowBefore   = IERC20(WFLOW).balanceOf(address(facet));
        uint256 stgUsdcBefore = IERC20(STG_USDC).balanceOf(address(facet));
        uint256 usdfBefore    = IERC20(USDF).balanceOf(address(facet));

        vm.prank(address(facet));
        uint256[] memory amountsOut = facet.executeBatchSwap(
            IGenericDexFacet.BatchSwapParams({swaps: swaps})
        );

        assertEq(amountsOut.length, 2);
        assertEq(wflowBefore - IERC20(WFLOW).balanceOf(address(facet)), 2 ether, "2 WFLOW not spent");
        assertGe(amountsOut[0], 20000, "Insufficient stgUSDC from swap 1");
        assertEq(IERC20(STG_USDC).balanceOf(address(facet)) - stgUsdcBefore, amountsOut[0]);
        assertGe(amountsOut[1], 20000, "Insufficient USDF from swap 2");
        assertEq(IERC20(USDF).balanceOf(address(facet)) - usdfBefore, amountsOut[1]);

        console.log("Batch swap 1 out (stgUSDC):", amountsOut[0]);
        console.log("Batch swap 2 out (USDF):   ", amountsOut[1]);
    }

    // =========================================================================
    // Validation / revert tests
    // =========================================================================

    function test_executeSwap_revert_tokenIn_not_available() public {
        address unknownToken = makeAddr("unknownToken");

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.InvalidTokenIn.selector, unknownToken));
        facet.executeSwap(IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: unknownToken,
            tokenOut: STG_USDC,
            maxAmountIn: 1 ether,
            minAmountOut: 200000,
            swapCallData: hex""
        }));
    }

    function test_executeSwap_revert_tokenOut_not_available() public {
        address unknownToken = makeAddr("unknownToken");

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.InvalidTokenOut.selector, unknownToken));
        facet.executeSwap(IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: WFLOW,
            tokenOut: unknownToken,
            maxAmountIn: 1 ether,
            minAmountOut: 200000,
            swapCallData: hex""
        }));
    }

    function test_executeSwap_revert_caller_not_diamond() public {
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert();
        facet.executeSwap(IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: WFLOW,
            tokenOut: STG_USDC,
            maxAmountIn: 1 ether,
            minAmountOut: 200000,
            swapCallData: hex""
        }));
    }

    function test_executeSwap_revert_slippage_exceeded() public {
        bytes memory swapCalldata = _fetchEisenCalldata(WFLOW, STG_USDC, 1 ether);

        // Set an unreachable minAmountOut (10000 USDC for 1 WFLOW)
        vm.prank(address(facet));
        vm.expectRevert();
        facet.executeSwap(IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: WFLOW,
            tokenOut: STG_USDC,
            maxAmountIn: 1 ether,
            minAmountOut: 10000e6,
            swapCallData: swapCalldata
        }));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Fetches Eisen swap calldata via FFI and executes the swap, asserting results.
    function _testSwap(address fromToken, address toToken, uint256 amountIn, uint256 minAmountOut) internal {
        bytes memory swapCalldata = _fetchEisenCalldata(fromToken, toToken, amountIn);

        uint256 balanceInBefore  = IERC20(fromToken).balanceOf(address(facet));
        uint256 balanceOutBefore = IERC20(toToken).balanceOf(address(facet));

        console.log("Balance IN  before:", balanceInBefore);
        console.log("Balance OUT before:", balanceOutBefore);

        vm.prank(address(facet));
        uint256 amountOut = facet.executeSwap(IGenericDexFacet.SwapParams({
            targetContract: EISEN_FORWARDER,
            tokenIn: fromToken,
            tokenOut: toToken,
            maxAmountIn: amountIn,
            minAmountOut: minAmountOut,
            swapCallData: swapCalldata
        }));

        uint256 balanceInAfter  = IERC20(fromToken).balanceOf(address(facet));
        uint256 balanceOutAfter = IERC20(toToken).balanceOf(address(facet));

        console.log("Balance IN  after:", balanceInAfter);
        console.log("Balance OUT after:", balanceOutAfter);
        console.log("Amount out:", amountOut);

        assertEq(balanceInBefore - balanceInAfter, amountIn, "tokenIn not fully spent");
        assertGe(amountOut, minAmountOut, "amountOut below minAmountOut");
        assertEq(balanceOutAfter - balanceOutBefore, amountOut, "tokenOut balance mismatch");
    }

    /// @dev Calls the Eisen Finance API via FFI and returns the swap calldata bytes.
    function _fetchEisenCalldata(address fromToken, address toToken, uint256 amountIn)
        internal
        returns (bytes memory)
    {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string(abi.encodePacked(
            "curl -s 'https://hiker.hetz-01.eisenfinance.com/public/v1/quote?",
            "fromChain=747&toChain=747&",
            "fromToken=", _toLower(vm.toString(fromToken)), "&",
            "toToken=",   _toLower(vm.toString(toToken)),   "&",
            "fromAmount=", vm.toString(amountIn), "&",
            "fromAddress=", vm.toString(address(facet)),
            "&toAddress=",  vm.toString(address(facet)),
            "&slippage=0.02&integrator=more-vaults' ",
            "--header 'X-EISEN-KEY: ", EISEN_API_KEY, "'"
        ));

        bytes memory raw = vm.ffi(inputs);
        string memory json = string(raw);
        string memory calldataHex = vm.parseJsonString(json, ".result.transactionRequest.data");
        bytes memory calldata_ = vm.parseBytes(calldataHex);

        console.log("Eisen calldata length:", calldata_.length);
        return calldata_;
    }

    /// @dev Converts an address string (0xABCD...) to lowercase hex.
    function _toLower(string memory str) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        bytes memory lower = new bytes(b.length);
        for (uint256 i = 0; i < b.length; i++) {
            lower[i] = (b[i] >= 0x41 && b[i] <= 0x46) ? bytes1(uint8(b[i]) + 32) : b[i];
        }
        return string(lower);
    }
}
