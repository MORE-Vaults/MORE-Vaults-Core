// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MoreVaultsOftFactory} from "../../../src/factory/MoreVaultsOftFactory.sol";
import {IMoreVaultsOftFactory} from "../../../src/interfaces/IMoreVaultsOftFactory.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract MoreVaultsOftFactoryTest is Test {
    MoreVaultsOftFactory public factory;
    address public endpoint = address(1001);
    address public owner = address(1002);
    address public token;
    address public vaultsFactory = address(1003);

    function setUp() public {
        // Deploy mock token
        MockERC20 mockToken = new MockERC20("Test Token", "TT");
        token = address(mockToken);

        // Deploy factory
        factory = new MoreVaultsOftFactory();
        factory.initialize(endpoint, owner, vaultsFactory);

        vm.mockCall(
            endpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.setDelegate.selector, owner), abi.encode(true)
        );
    }

    function test_initialize_ShouldSetInitialValues() public {
        assertEq(factory.endpoint(), endpoint, "Should set correct endpoint");
        assertEq(factory.owner(), owner, "Should set correct owner");
    }

    function test_deployOFTAdapter_ShouldDeployAdapter() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        address adapter = factory.deployOFT(token, false, salt);

        assertTrue(adapter != address(0), "Adapter should be deployed");
        assertEq(factory.getOFT(token), adapter, "Should store adapter address");
        assertTrue(factory.hasOFT(token), "Should return true for existing adapter");
    }

    function test_deployOFTAdapter_ShouldRevertWithZeroToken() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        vm.expectRevert(IMoreVaultsOftFactory.ZeroAddress.selector);
        factory.deployOFT(address(0), true, salt);
    }

    function test_deployOFTAdapter_ShouldRevertIfAdapterExists() public {
        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        factory.deployOFT(token, false, salt);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsOftFactory.OFTAlreadyExists.selector, token));
        factory.deployOFT(token, false, salt);
    }

    function test_predictAdapterAddress_ShouldReturnCorrectAddress() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.predictOFTAddress(token, salt);

        vm.prank(owner);
        address actual = factory.deployOFT(token, false, salt);

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
        vm.expectRevert(IMoreVaultsOftFactory.ZeroAddress.selector);
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
        address adapter1 = factory.deployOFT(token, false, salt1);

        vm.prank(owner);
        address adapter2 = factory.deployOFT(address(token2), false, salt2);

        address[] memory adapters = factory.getDeployedOFTs();

        assertEq(adapters.length, 2, "Should return 2 adapters");
        assertEq(adapters[0], adapter1, "Should return first adapter");
        assertEq(adapters[1], adapter2, "Should return second adapter");
    }

    function test_getAdaptersCount_ShouldReturnCorrectCount() public {
        assertEq(factory.getOFTsCount(), 0, "Should start with 0 adapters");

        bytes32 salt = keccak256("test-salt");

        vm.prank(owner);
        factory.deployOFT(token, false, salt);

        assertEq(factory.getOFTsCount(), 1, "Should return 1 adapter");
    }
}
