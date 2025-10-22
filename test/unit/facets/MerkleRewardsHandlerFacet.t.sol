// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MerkleRewardsHandlerFacet} from "../../../src/facets/MerkleRewardsHandlerFacet.sol";
import {IMerkleRewardsHandlerFacet} from "../../../src/interfaces/facets/IMerkleRewardsHandlerFacet.sol";
import {IMerklDistributor} from "../../../src/interfaces/external/IMerklDistributor.sol";
import {IUniversalRewardsDistributor} from "../../../src/interfaces/external/IUniversalRewardsDistributor.sol";
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

contract MockMorphoDistributor {
    mapping(address => mapping(address => uint256)) public claimed;
    bool public shouldRevert;
    string public revertMessage;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
        revertMessage = "Claim failed";
    }

    function claim(address account, address reward, uint256 claimable, bytes32[] calldata)
        external
        returns (uint256 amount)
    {
        if (shouldRevert) revert(revertMessage);

        require(claimable > claimed[account][reward], "Claimable too low");
        amount = claimable - claimed[account][reward];
        claimed[account][reward] = claimable;

        return amount;
    }

    function root() external pure returns (bytes32) {
        return bytes32(uint256(1));
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

contract MerkleRewardsHandlerFacetTest is Test {
    MerkleRewardsHandlerFacet public facet;
    MockMerklDistributor public mockMerklDistributor;
    MockMorphoDistributor public mockMorphoDistributor;
    MockRegistry public mockRegistry;

    address public owner = address(1);
    address public curator = address(2);
    address public unauthorized = address(3);
    address public token1 = address(4);
    address public token2 = address(5);

    function setUp() public {
        // Deploy facet, mock distributors, and mock registry
        facet = new MerkleRewardsHandlerFacet();
        mockMerklDistributor = new MockMerklDistributor();
        mockMorphoDistributor = new MockMorphoDistributor();
        mockRegistry = new MockRegistry();

        // Set owner role
        MoreVaultsStorageHelper.setOwner(address(facet), owner);

        // Set curator role
        MoreVaultsStorageHelper.setCurator(address(facet), curator);

        // Set registry
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(mockRegistry));

        // Whitelist both distributors
        mockRegistry.setWhitelisted(address(mockMerklDistributor), true);
        mockRegistry.setWhitelisted(address(mockMorphoDistributor), true);
    }

    function test_initialize_shouldSetInterface() public {
        facet.initialize(abi.encode(""));

        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerkleRewardsHandlerFacet).interfaceId),
            true,
            "Supported interface should be set"
        );
    }

    function test_facetName_shouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "MerkleRewardsHandlerFacet", "Facet name should be correct");
    }

    function test_facetVersion_shouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0", "Facet version should be correct");
    }

    function test_onFacetRemoval_shouldDisableInterface() public {
        facet.initialize(abi.encode(""));
        facet.onFacetRemoval(false);

        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMerkleRewardsHandlerFacet).interfaceId),
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
        emit IMerkleRewardsHandlerFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
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
        emit IMerkleRewardsHandlerFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        vm.expectEmit(true, true, true, true);
        emit IMerkleRewardsHandlerFacet.MerklRewardsClaimed(token2, 2000e18, address(facet));
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenNotCurator() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
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
        vm.expectRevert(IMerkleRewardsHandlerFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenAmountsLengthMismatch() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](2); // Mismatched length
        bytes32[][] memory proofs = new bytes32[][](1);

        vm.prank(curator);
        vm.expectRevert(IMerkleRewardsHandlerFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenProofsLengthMismatch() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](2); // Mismatched length

        vm.prank(curator);
        vm.expectRevert(IMerkleRewardsHandlerFacet.InvalidArrayLength.selector);
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWhenClaimFails() public {
        facet.initialize(abi.encode(""));
        mockMerklDistributor.setShouldRevert(true);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert("Claim failed");
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldRevertWithReasonWhenDistributorFails() public {
        facet.initialize(abi.encode(""));
        mockMerklDistributor.setShouldRevertWithMessage("Invalid merkle proof");

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert("Invalid merkle proof");
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
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
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    function test_claimMerklRewards_shouldSucceedWithEmptyArrays() public {
        facet.initialize(abi.encode(""));

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        vm.prank(curator);
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
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
        emit IMerkleRewardsHandlerFacet.MerklRewardsClaimed(token1, 1000e18, address(facet));
        facet.claimMerklRewards(address(mockMerklDistributor), tokens, amounts, proofs);
    }

    // ========== MORPHO URD TESTS ==========

    function test_claimMorphoReward_shouldSucceed() public {
        facet.initialize(abi.encode(""));

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("proof1");
        proof[1] = keccak256("proof2");

        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerkleRewardsHandlerFacet.MorphoRewardClaimed(token1, 1000e18, address(facet));
        uint256 claimed = facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);

        assertEq(claimed, 1000e18, "Should claim full amount on first claim");
        assertEq(mockMorphoDistributor.claimed(address(facet), token1), 1000e18, "Claimed amount should be tracked");
    }

    function test_claimMorphoReward_shouldClaimDelta() public {
        facet.initialize(abi.encode(""));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof1");

        // First claim: 1000e18
        vm.prank(curator);
        uint256 firstClaim = facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);
        assertEq(firstClaim, 1000e18, "First claim should be full amount");

        // Second claim: 1500e18 total (delta: 500e18)
        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerkleRewardsHandlerFacet.MorphoRewardClaimed(token1, 500e18, address(facet));
        uint256 secondClaim = facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1500e18, proof);

        assertEq(secondClaim, 500e18, "Second claim should only claim delta");
        assertEq(mockMorphoDistributor.claimed(address(facet), token1), 1500e18, "Total claimed should be updated");
    }

    function test_claimMorphoReward_shouldRevertWhenNotCurator() public {
        facet.initialize(abi.encode(""));

        bytes32[] memory proof = new bytes32[](1);

        vm.prank(unauthorized);
        vm.expectRevert();
        facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);
    }

    function test_claimMorphoReward_shouldRevertWhenDistributorNotWhitelisted() public {
        facet.initialize(abi.encode(""));

        address notWhitelisted = address(0x999);
        bytes32[] memory proof = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, notWhitelisted));
        facet.claimMorphoReward(notWhitelisted, token1, 1000e18, proof);
    }

    function test_claimMorphoReward_shouldRevertDuringMulticall() public {
        facet.initialize(abi.encode(""));

        // Set multicall flag
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        bytes32[] memory proof = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);
    }

    function test_claimMorphoReward_shouldRevertWhenClaimFails() public {
        facet.initialize(abi.encode(""));
        mockMorphoDistributor.setShouldRevert(true);

        bytes32[] memory proof = new bytes32[](1);

        vm.prank(curator);
        vm.expectRevert("Claim failed");
        facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);
    }

    function test_claimMorphoReward_shouldSucceedAsOwner() public {
        facet.initialize(abi.encode(""));

        bytes32[] memory proof = new bytes32[](1);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IMerkleRewardsHandlerFacet.MorphoRewardClaimed(token1, 1000e18, address(facet));
        uint256 claimed = facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);

        assertEq(claimed, 1000e18, "Owner should be able to claim");
    }

    function test_claimMorphoReward_shouldHandleMultipleTokens() public {
        facet.initialize(abi.encode(""));

        bytes32[] memory proof = new bytes32[](1);

        // Claim token1
        vm.prank(curator);
        uint256 claim1 = facet.claimMorphoReward(address(mockMorphoDistributor), token1, 1000e18, proof);
        assertEq(claim1, 1000e18);

        // Claim token2
        vm.prank(curator);
        uint256 claim2 = facet.claimMorphoReward(address(mockMorphoDistributor), token2, 2000e18, proof);
        assertEq(claim2, 2000e18);

        // Verify both tracked separately
        assertEq(mockMorphoDistributor.claimed(address(facet), token1), 1000e18);
        assertEq(mockMorphoDistributor.claimed(address(facet), token2), 2000e18);
    }
}
