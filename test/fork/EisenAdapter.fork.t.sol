// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EisenAdapter} from "../../src/dex-aggregator/EisenAdapter.sol";
import {DexAggregatorFacet} from "../../src/facets/DexAggregatorFacet.sol";
import {IDexAggregatorFacet} from "../../src/interfaces/facets/IDexAggregatorFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title EisenAdapterForkTest
 * @notice Fork tests for EisenAdapter on Flow EVM
 * @dev These tests require:
 *      1. FLOW_RPC_URL environment variable
 *      2. Call to Eisen API to get real quote data
 *      3. Sufficient token balances for testing
 *
 *      To run: forge test --match-path test/fork/EisenAdapter.fork.t.sol --fork-url $FLOW_RPC_URL -vvv
 */
contract EisenAdapterForkTest is Test {
    EisenAdapter adapter;
    DexAggregatorFacet facet;

    // Flow EVM chain ID
    uint256 constant FLOW_CHAIN_ID = 747;

    // Eisen router on Flow
    address constant EISEN_ROUTER = 0x90BA9922Ae475D0DD91a6BF20dcD0FB872Bc18B0;

    // Real tokens on Flow EVM
    address constant WFLOW = 0xd3bF53DAc106A0290B0483EcBC89d40FcC961f3e; // Wrapped FLOW
    address constant STG_USDC = 0xF1815bd50389C46847F0BDa824EC8Da914045d14; // Stargate USDC

    address curator;
    address vault;

    function setUp() public {
        // Check we're on Flow
        require(block.chainid == FLOW_CHAIN_ID, "Must fork Flow EVM");

        adapter = new EisenAdapter();
        facet = new DexAggregatorFacet();

        curator = makeAddr("curator");
        vault = address(this); // Simulate vault as test contract
    }

    /**
     * @notice Test the complete flow of getting a quote and executing a swap
     * @dev This is a template test. To make it work:
     *      1. Update WFLOW and USDC addresses with real Flow tokens
     *      2. Call Eisen API to get real quote data:
     *         GET https://hiker.hetz-01.eisenfinance.com/public/v1/quote
     *         with parameters:
     *         - fromChain=747
     *         - fromToken=<WFLOW_ADDRESS>
     *         - toToken=<USDC_ADDRESS>
     *         - fromAmount=1000000000000000000
     *         - fromAddress=<vault_address>
     *      3. Extract transactionRequest.data from API response
     *      4. Use that data in the test below
     */
    function test_executeSwap_WithRealEisenQuote() public {
        // Skip if not on Flow fork
        if (block.chainid != FLOW_CHAIN_ID) {
            vm.skip(true);
        }

        // Real calldata from Eisen API quote (WFLOW -> stgUSDC on Flow)
        // Quote: 1 WFLOW (~$0.258) -> ~0.255 stgUSDC
        bytes memory eisenApiCalldata = hex"e3665a430000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000bb8000000000000000000000000d3bf53dac106a0290b0483ecbc89d40fcc961f3e000000000000000000000000daf87a186345f26d107d000fad351e79ff696d2c00000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000066435f1040100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000003db3a000000000000000000000000000000000000000000000000000000000003e532000000000000000000000000000000000000000000000000000001d1a94a20000000000000000000000000000000000000000000000000000000000000000140000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa9604500000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000000000000000000003000000000000000000000000d3bf53dac106a0290b0483ecbc89d40fcc961f3e0000000000000000000000002aabea2058b5ac2d339b163c6ab6f2b6d53aabed000000000000000000000000f1815bd50389c46847f0bda824ec8da914045d14000000000000000000000000000000000000000000000000000000000000000800010000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000010001000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000012453e9d16c0000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000d3bf53dac106a0290b0483ecbc89d40fcc961f3e00000000000000000000000029372c22459a4e373851798bfd6808e71ea34a710000000000000000000000002aabea2058b5ac2d339b163c6ab6f2b6d53aabed00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001a471e699c2000000000000000000000000000000000000000000000000000000000003eef600000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000030000000000000000000000002aabea2058b5ac2d339b163c6ab6f2b6d53aabed00000000000000000000000020ca5d1c8623ba6ac8f02e41ccaffe7bb6c92b57000000000000000000000000f1815bd50389c46847f0bda824ec8da914045d140000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        // Build swap calldata using adapter
        bytes memory swapCalldata =
            adapter.buildSwapCalldataWithParams(WFLOW, STG_USDC, 1 ether, 252730, vault, eisenApiCalldata);

        // Prepare swap parameters for facet
        // Note: Router address from API is 0x85efa14c12f5fe42ff9d7da460a71088b26bea31 (Forwarder)
        // But we use the Route Proxy documented: 0x90BA9922Ae475D0DD91a6BF20dcD0FB872Bc18B0
        address eisenForwarder = 0x85EFA14c12F5fE42Ff9D7Da460A71088b26bEa31;

        IDexAggregatorFacet.SwapParams memory params = IDexAggregatorFacet.SwapParams({
            targetContract: eisenForwarder, // Use forwarder from API response
            tokenIn: WFLOW,
            tokenOut: STG_USDC,
            amountIn: 1 ether,
            minAmountOut: 252730, // toAmountMin from API (1% slippage)
            swapCallData: swapCalldata
        });

        // Deal tokens to vault
        deal(WFLOW, vault, 10 ether);

        // Record balances before swap
        uint256 wflowBefore = IERC20(WFLOW).balanceOf(vault);
        uint256 stgUsdcBefore = IERC20(STG_USDC).balanceOf(vault);

        // Execute swap through facet
        // Note: This will fail without proper facet setup (storage, access control, etc.)
        // In a real scenario, this would be called through a properly initialized vault
        vm.prank(curator);
        uint256 amountOut = facet.executeSwap(params);

        // Verify swap results
        uint256 wflowAfter = IERC20(WFLOW).balanceOf(vault);
        uint256 stgUsdcAfter = IERC20(STG_USDC).balanceOf(vault);

        assertEq(wflowBefore - wflowAfter, 1 ether, "WFLOW not spent correctly");
        assertGe(amountOut, 252730, "Insufficient stgUSDC received (min from API)");
        assertEq(stgUsdcAfter - stgUsdcBefore, amountOut, "stgUSDC balance mismatch");
    }

    /**
     * @notice Example of how to call Eisen API off-chain to get quote
     * @dev This is pseudocode showing the API call structure:
     *
     * ```javascript
     * const response = await fetch(
     *   'https://hiker.hetz-01.eisenfinance.com/public/v1/quote?' +
     *   new URLSearchParams({
     *     fromChain: '747',
     *     toChain: '747',
     *     fromToken: WFLOW_ADDRESS,
     *     toToken: USDC_ADDRESS,
     *     fromAmount: '1000000000000000000',
     *     fromAddress: vaultAddress,
     *     toAddress: vaultAddress,
     *     slippage: '0.01',
     *     integrator: 'more-vaults'
     *   }),
     *   {
     *     headers: {
     *       'X-EISEN-KEY': process.env.EISEN_API_KEY
     *     }
     *   }
     * );
     *
     * const data = await response.json();
     * const router = data.result.transactionRequest.to;  // 0x90BA9922Ae475D0DD91a6BF20dcD0FB872Bc18B0
     * const calldata = data.result.transactionRequest.data;  // Use this in test
     * const expectedOutput = data.result.estimate.toAmount;
     * ```
     */
    function test_apiCallExample() public pure {
        // This is just documentation - see comment above
    }
}
