// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MerklRewardsFacet} from "../../../src/facets/MerklRewardsFacet.sol";
import {IMerklRewardsFacet} from "../../../src/interfaces/facets/IMerklRewardsFacet.sol";
import {IMerklDistributor} from "../../../src/interfaces/external/IMerklDistributor.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";

contract MockMerklDistributor {
    bool public shouldRevert;
    string public revertMessage;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
        revertMessage = "Claim failed";
    }

    function setShouldRevertWithMessage(string memory message) external {
        shouldRevert = true;
        revertMessage = message;
    }

    function claim(
        address[] calldata users,
        address[] calldata,
        uint256[] calldata,
        bytes32[][] calldata
    ) external view {
        // Verify all users are the caller (vault)
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] == msg.sender, "User must be vault");
        }
        if (shouldRevert) revert(revertMessage);
    }
}

contract MockRegistry {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address protocol, bool status) external {
        whitelisted[protocol] = status;
    }

    function isWhitelisted(address protocol) external view returns (bool) {
        return whitelisted[protocol];
    }
}

contract MerklRewardsFacetTest is Test {
    MerklRewardsFacet public facet;
    MockMerklDistributor public mockDistributor;
    MockRegistry public mockRegistry;

    address public owner = address(1);
    address public curator = address(2);
    address public unauthorized = address(3);
    address public token1 = address(4);
    address public token2 = address(5);

    function setUp() public {
        // Deploy facet, mock distributor, and mock registry
        facet = new MerklRewardsFacet();
        mockDistributor = new MockMerklDistributor();
        mockRegistry = new MockRegistry();

        // Set owner role
        MoreVaultsStorageHelper.setOwner(address(facet), owner);

        // Set curator role
        MoreVaultsStorageHelper.setCurator(address(facet), curator);

        // Set registry
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(mockRegistry));

        // Whitelist the distributor
        mockRegistry.setWhitelisted(address(mockDistributor), true);
    }

    function test_initialize_shouldSetInterface() public {
        facet.initialize(abi.encode(""));

        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerklRewardsFacet).interfaceId),
            true,
            "Supported interface should be set"
        );
    }

    function test_facetName_shouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "MerklRewardsFacet", "Facet name should be correct");
    }

    function test_facetVersion_shouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0", "Facet version should be correct");
    }

    function test_onFacetRemoval_shouldDisableInterface() public {
        facet.initialize(abi.encode(""));
        facet.onFacetRemoval(false);

        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerklRewardsFacet).interfaceId),
            "Interface should be disabled"
        );
    }

    function test_claimMerklRewards_shouldSucceed() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = keccak256("proof1");
        proofs[0][1] = keccak256("proof2");

        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerklRewardsFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldSucceedWithMultipleTokens() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](2);
        tokens[0] = token1;
        tokens[1] = token2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("proof1");
        proofs[1] = new bytes32[](1);
        proofs[1][0] = keccak256("proof2");

        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerklRewardsFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        vm.expectEmit(true, true, true, true);
        emit IMerklRewardsFacet.MerklRewardsClaimed(token2, 2000e18, address(facet));
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenNotCurator() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenDistributorNotWhitelisted() public {
        facet.initialize(abi.encode(""));

        address notWhitelisted = address(0x999);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, notWhitelisted));
        facet.claimMerklRewards(notWhitelisted, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWithInvalidArrayLength() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](2); // Mismatched length
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenAmountsLengthMismatch() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](2); // Mismatched length
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenProofsLengthMismatch() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](2); // Mismatched length

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenClaimFails() public {
        facet.initialize(abi.encode(""));
        mockDistributor.setShouldRevert(true);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert("Claim failed");
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWithReasonWhenDistributorFails() public {
        facet.initialize(abi.encode(""));
        mockDistributor.setShouldRevertWithMessage("Invalid merkle proof");

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert("Invalid merkle proof");
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertDuringMulticall() public {
        facet.initialize(abi.encode(""));

        // Set multicall flag
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldSucceedWithEmptyArrays() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        vm.prank(curator);
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldSucceedAsOwner() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IMerklRewardsFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        facet.claimMerklRewards(address(mockDistributor), tokens, amounts, proofs);
    }
}
