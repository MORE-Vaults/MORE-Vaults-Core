// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EisenAdapter} from "../../../src/dex-aggregator/EisenAdapter.sol";
import {IDexAdapter} from "../../../src/interfaces/IDexAdapter.sol";

contract EisenAdapterTest is Test {
    EisenAdapter adapter;

    address constant TOKEN_A = address(0x1);
    address constant TOKEN_B = address(0x2);
    address constant RECEIVER = address(0x3);

    function setUp() public {
        adapter = new EisenAdapter();
    }

    function test_adapterName_ShouldReturnCorrectName() public view {
        assertEq(adapter.adapterName(), "Eisen Finance");
    }

    function test_getRouterAddress_ShouldRevert() public {
        vm.expectRevert(IDexAdapter.RouterNotSet.selector);
        adapter.getRouterAddress();
    }

    function test_getQuoterAddress_ShouldRevert() public {
        vm.expectRevert(IDexAdapter.QuoterNotAvailable.selector);
        adapter.getQuoterAddress();
    }

    function test_isChainSupported_ShouldAlwaysReturnTrue() public view {
        assertTrue(adapter.isChainSupported(1)); // Ethereum
        assertTrue(adapter.isChainSupported(8453)); // Base
        assertTrue(adapter.isChainSupported(747)); // Flow
        assertTrue(adapter.isChainSupported(999999)); // Random chain
    }

    function test_getSupportedChains_ShouldReturnEmptyArray() public view {
        uint256[] memory chains = adapter.getSupportedChains();
        assertEq(chains.length, 0);
    }

    function test_getQuote_ShouldRevert() public {
        vm.expectRevert(IDexAdapter.QuoterNotAvailable.selector);
        adapter.getQuote(TOKEN_A, TOKEN_B, 1 ether);
    }

    function test_estimateGas_ShouldReturnEstimate() public view {
        uint256 gasEstimate = adapter.estimateGas(TOKEN_A, TOKEN_B, 1 ether);
        assertEq(gasEstimate, 300000);
    }

    function test_buildSwapCalldata_ShouldRevert() public {
        vm.expectRevert("EisenAdapter: Use buildSwapCalldataWithParams with API data");
        adapter.buildSwapCalldata(TOKEN_A, TOKEN_B, 1 ether, 0.99 ether, RECEIVER);
    }

    function test_buildSwapCalldataWithParams_ShouldReturnCalldata() public view {
        bytes memory apiCalldata = hex"1234567890abcdef";

        bytes memory result =
            adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_B, 1 ether, 0.99 ether, RECEIVER, apiCalldata);

        assertEq(result, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfTokenInIsZero() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidToken.selector);
        adapter.buildSwapCalldataWithParams(address(0), TOKEN_B, 1 ether, 0.99 ether, RECEIVER, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfTokenOutIsZero() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidToken.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, address(0), 1 ether, 0.99 ether, RECEIVER, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfSameToken() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidToken.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_A, 1 ether, 0.99 ether, RECEIVER, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfAmountInIsZero() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidAmount.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_B, 0, 0.99 ether, RECEIVER, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfMinAmountOutIsZero() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidAmount.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_B, 1 ether, 0, RECEIVER, apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfReceiverIsZero() public {
        bytes memory apiCalldata = hex"1234567890abcdef";

        vm.expectRevert(IDexAdapter.InvalidReceiver.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_B, 1 ether, 0.99 ether, address(0), apiCalldata);
    }

    function test_buildSwapCalldataWithParams_ShouldRevertIfCalldataIsEmpty() public {
        bytes memory apiCalldata = "";

        vm.expectRevert(IDexAdapter.InvalidSwapPath.selector);
        adapter.buildSwapCalldataWithParams(TOKEN_A, TOKEN_B, 1 ether, 0.99 ether, RECEIVER, apiCalldata);
    }

    function test_validateSwapParams_ShouldReturnTrueForValidParams() public view {
        assertTrue(adapter.validateSwapParams(TOKEN_A, TOKEN_B, 1 ether, 0.99 ether));
    }

    function test_validateSwapParams_ShouldReturnFalseIfTokenInIsZero() public view {
        assertFalse(adapter.validateSwapParams(address(0), TOKEN_B, 1 ether, 0.99 ether));
    }

    function test_validateSwapParams_ShouldReturnFalseIfTokenOutIsZero() public view {
        assertFalse(adapter.validateSwapParams(TOKEN_A, address(0), 1 ether, 0.99 ether));
    }

    function test_validateSwapParams_ShouldReturnFalseIfSameToken() public view {
        assertFalse(adapter.validateSwapParams(TOKEN_A, TOKEN_A, 1 ether, 0.99 ether));
    }

    function test_validateSwapParams_ShouldReturnFalseIfAmountInIsZero() public view {
        assertFalse(adapter.validateSwapParams(TOKEN_A, TOKEN_B, 0, 0.99 ether));
    }

    function test_validateSwapParams_ShouldReturnFalseIfMinAmountOutIsZero() public view {
        assertFalse(adapter.validateSwapParams(TOKEN_A, TOKEN_B, 1 ether, 0));
    }

    function test_decodeSwapResult_ShouldReturnZero() public view {
        bytes memory result = hex"1234567890abcdef";
        assertEq(adapter.decodeSwapResult(result), 0);
    }
}
