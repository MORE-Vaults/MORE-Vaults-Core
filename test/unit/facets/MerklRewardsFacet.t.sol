// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MerklRewardsFacet} from "../../../src/facets/MerklRewardsFacet.sol";
import {IMerklRewardsFacet} from "../../../src/interfaces/facets/IMerklRewardsFacet.sol";
import {IMerklDistributor} from "../../../src/interfaces/external/IMerklDistributor.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";

contract MockMerklDistributor {
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function claim(
        address[] calldata,
        address[] calldata,
        uint256[] calldata,
        bytes32[][] calldata
    ) external view {
        if (shouldRevert) revert("Claim failed");
    }

    function claimWithRecipient(
        address[] calldata,
        address[] calldata,
        uint256[] calldata,
        bytes32[][] calldata,
        address[] calldata,
        bytes[] memory
    ) external view {
        if (shouldRevert) revert("Claim failed");
    }
}

contract MerklRewardsFacetTest is Test {
    MerklRewardsFacet public facet;
    MockMerklDistributor public mockDistributor;

    address public owner = address(1);
    address public curator = address(2);
    address public unauthorized = address(3);
    address public token1 = address(4);
    address public token2 = address(5);

    function setUp() public {
        // Deploy facet and mock distributor
        facet = new MerklRewardsFacet();
        mockDistributor = new MockMerklDistributor();

        // Set owner role
        MoreVaultsStorageHelper.setOwner(address(facet), owner);

        // Set curator role
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
    }

    function test_initialize_shouldSetDistributorAddress() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        assertEq(
            facet.getMerklDistributor(),
            address(mockDistributor),
            "Distributor address should be set"
        );

        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerklRewardsFacet).interfaceId),
            true,
            "Supported interfaces should be set"
        );
    }

    function test_initialize_shouldRevertWithZeroAddress() public {
        vm.expectRevert(IMerklRewardsFacet.InvalidDistributorAddress.selector);
        facet.initialize(abi.encode(address(0)));
    }

    function test_facetName_shouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "MerklRewardsFacet", "Facet name should be correct");
    }

    function test_facetVersion_shouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0", "Facet version should be correct");
    }

    function test_onFacetRemoval_shouldDisableInterface() public {
        facet.initialize(abi.encode(address(mockDistributor)));
        facet.onFacetRemoval(false);

        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerklRewardsFacet).interfaceId),
            "Interface should be disabled"
        );
    }

    function test_setMerklDistributor_shouldUpdateAddress() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address newDistributor = address(0x999);

        vm.prank(address(facet));
        facet.setMerklDistributor(newDistributor);

        assertEq(
            facet.getMerklDistributor(),
            newDistributor,
            "Distributor address should be updated"
        );
    }

    function test_setMerklDistributor_shouldRevertWithZeroAddress() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        vm.prank(address(facet));
        vm.expectRevert(IMerklRewardsFacet.InvalidDistributorAddress.selector);
        facet.setMerklDistributor(address(0));
    }

    function test_setMerklDistributor_shouldRevertWhenNotDiamond() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.setMerklDistributor(address(0x999));
    }

    function test_claimMerklRewards_shouldSucceed() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address[] memory users = new address[](1);
        users[0] = address(facet);

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
        facet.claimMerklRewards(users, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenNotCurator() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.claimMerklRewards(users, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWithInvalidArrayLength() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](2); // Mismatched length
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(users, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenClaimFails() public {
        facet.initialize(abi.encode(address(mockDistributor)));
        mockDistributor.setShouldRevert(true);

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.ClaimFailed.selector);
        facet.claimMerklRewards(users, tokens, amounts, proofs);
    }

    function test_claimMerklRewardsWithRecipient_shouldSucceed() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address recipient = address(0x888);

        address[] memory users = new address[](1);
        users[0] = address(facet);

        address[] memory tokens = new address[](1);
        tokens[0] = token1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = keccak256("proof1");
        proofs[0][1] = keccak256("proof2");

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerklRewardsFacet.MerklRewardsClaimed(token1, 1000e18, recipient);
        facet.claimMerklRewardsWithRecipient(users, tokens, amounts, proofs, recipients);
    }

    function test_claimMerklRewardsWithRecipient_shouldRevertWhenNotCurator() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        address[] memory recipients = new address[](1);

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.claimMerklRewardsWithRecipient(users, tokens, amounts, proofs, recipients);
    }

    function test_claimMerklRewardsWithRecipient_shouldRevertWithInvalidArrayLength() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        address[] memory recipients = new address[](2); // Mismatched length

        vm.prank(curator);
        vm.expectRevert(IMerklRewardsFacet.InvalidArrayLength.selector);
        facet.claimMerklRewardsWithRecipient(users, tokens, amounts, proofs, recipients);
    }

    function test_claimMerklRewards_shouldRevertDuringMulticall() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        // Set multicall flag
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        facet.claimMerklRewards(users, tokens, amounts, proofs);
    }

    function test_claimMerklRewardsWithRecipient_shouldRevertDuringMulticall() public {
        facet.initialize(abi.encode(address(mockDistributor)));

        // Set multicall flag
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        address[] memory users = new address[](1);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        address[] memory recipients = new address[](1);

        vm.prank(curator);
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        facet.claimMerklRewardsWithRecipient(users, tokens, amounts, proofs, recipients);
    }
}
