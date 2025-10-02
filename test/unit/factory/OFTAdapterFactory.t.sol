// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {OFTAdapterFactory} from "../../../src/factory/OFTAdapterFactory.sol";
import {IOFTAdapterFactory} from "../../../src/interfaces/IOFTAdapterFactory.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract OFTAdapterFactoryTest is Test {
    OFTAdapterFactory public factory;
    address public endpoint = address(1001);
    address public owner = address(1002);
    address public token;

    function setUp() public {
        // Deploy mock token
        MockERC20 mockToken = new MockERC20("Test Token", "TT");
        token = address(mockToken);

        // Deploy factory
        factory = new OFTAdapterFactory(endpoint, owner);

        vm.mockCall(
            endpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.setDelegate.selector, owner), abi.encode(true)
        );
    }

    function test_constructor_ShouldSetInitialValues() public {
        assertEq(factory.endpoint(), endpoint, "Should set correct endpoint");
        assertEq(factory.owner(), owner, "Should set correct owner");
    }

    function test_deployOFTAdapter_ShouldDeployAdapter() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        address adapter = factory.deployOFTAdapter(token, salt);

        assertTrue(adapter != address(0), "Adapter should be deployed");
        assertEq(factory.getAdapter(token), adapter, "Should store adapter address");
        assertTrue(factory.hasAdapter(token), "Should return true for existing adapter");
    }

    function test_deployOFTAdapter_ShouldRevertWithZeroToken() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        vm.expectRevert(IOFTAdapterFactory.ZeroAddress.selector);
        factory.deployOFTAdapter(address(0), salt);
    }

    function test_deployOFTAdapter_ShouldRevertIfAdapterExists() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        factory.deployOFTAdapter(token, salt);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOFTAdapterFactory.AdapterAlreadyExists.selector, token));
        factory.deployOFTAdapter(token, salt);
    }

    function test_predictAdapterAddress_ShouldReturnCorrectAddress() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.predictAdapterAddress(token, salt);

        vm.prank(owner);
        address actual = factory.deployOFTAdapter(token, salt);

        assertEq(predicted, actual, "Predicted address should match actual");
    }

    function test_setEndpoint_ShouldRevertWhenNotOwner() public {
        address newEndpoint = address(2001);

        vm.prank(address(999));
        vm.expectRevert();
        factory.setEndpoint(newEndpoint);
    }

    function test_setEndpoint_ShouldRevertWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IOFTAdapterFactory.ZeroAddress.selector);
        factory.setEndpoint(address(0));
    }

    function test_setEndpoint_ShouldUpdateEndpoint() public {
        address newEndpoint = address(2001);

        vm.prank(owner);
        factory.setEndpoint(newEndpoint);

        assertEq(factory.endpoint(), newEndpoint, "Should update endpoint");
    }

    function test_transferOwnership_ShouldRevertWhenNotOwner() public {
        address newOwner = address(2002);

        vm.prank(address(999));
        vm.expectRevert();
        factory.transferOwnership(newOwner);
    }

    function test_transferOwnership_ShouldRevertWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        factory.transferOwnership(address(0));
    }

    function test_transferOwnership_ShouldUpdateOwner() public {
        address newOwner = address(2002);

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        assertEq(factory.owner(), newOwner, "Should update owner");
    }

    function test_getDeployedAdapters_ShouldReturnAllAdapters() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        MockERC20 token2 = new MockERC20("Token 2", "T2");

        vm.prank(owner);
        address adapter1 = factory.deployOFTAdapter(token, salt1);

        vm.prank(owner);
        address adapter2 = factory.deployOFTAdapter(address(token2), salt2);

        address[] memory adapters = factory.getDeployedAdapters();

        assertEq(adapters.length, 2, "Should return 2 adapters");
        assertEq(adapters[0], adapter1, "Should return first adapter");
        assertEq(adapters[1], adapter2, "Should return second adapter");
    }

    function test_getAdaptersCount_ShouldReturnCorrectCount() public {
        assertEq(factory.getAdaptersCount(), 0, "Should start with 0 adapters");

        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        factory.deployOFTAdapter(token, salt);

        assertEq(factory.getAdaptersCount(), 1, "Should return 1 adapter");
    }
}
