// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MerkleRewardsHandlerFacet} from "../../src/facets/MerkleRewardsHandlerFacet.sol";
import {IMerkleRewardsHandlerFacet} from "../../src/interfaces/facets/IMerkleRewardsHandlerFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title MerkleRewardsHandlerFacetForkTest
 * @notice Fork tests for MerkleRewardsHandlerFacet against the REAL Merkl distributor on Ethereum mainnet.
 *
 * @dev Strategy:
 *      1. Fork Ethereum mainnet where Merkl is live with 119 active campaigns.
 *      2. Deploy a fresh facet and set it up as a vault.
 *      3. Compute a single-leaf merkle tree with our facet as the claimant.
 *      4. Inject that root directly into the Merkl distributor via vm.store (slot 101).
 *      5. Call claimMerklRewards — the real Merkl distributor verifies our proof end-to-end.
 *
 *      Leaf encoding (Merkl single-hash standard):
 *        leaf = keccak256(abi.encode(user, token, amount))
 *      Single-leaf tree → root == leaf, proof == [].
 *
 * @dev Storage slot 101 = tree.merkleRoot inside the Merkl proxy (confirmed via storage scan).
 *      The Merkl distributor uses classic OZ Upgradeable storage starting at slot 101 for its
 *      first user-defined variable (after AccessControl + ERC165 __gaps).
 *
 * @dev To run:
 *      forge test --match-path test/fork/MerkleRewardsHandlerFacet.fork.t.sol \
 *        --fork-url https://eth.drpc.org -vvv
 */
contract MerkleRewardsHandlerFacetForkTest is Test {

    // Ethereum mainnet chain ID
    uint256 constant ETH_CHAIN_ID = 1;

    // Real Merkl distributor on Ethereum mainnet
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // Storage slot for tree.merkleRoot inside the Merkl proxy (found via storage scan)
    uint256 constant MERKL_ROOT_SLOT = 101;

    // Real reward token — WETH on Ethereum (standard, deal-friendly)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Claim amount for our custom single-leaf tree
    uint256 constant CLAIM_AMOUNT = 1 ether;

    MerkleRewardsHandlerFacet facet;
    address mockRegistry;
    address curator;

    // The leaf and root we'll inject — computed in setUp
    bytes32 merkleRoot;

    function setUp() public {
        require(block.chainid == ETH_CHAIN_ID, "Must fork Ethereum mainnet");

        facet = new MerkleRewardsHandlerFacet();
        mockRegistry = makeAddr("mockRegistry");
        curator = makeAddr("curator");

        // Wire up vault storage
        MoreVaultsStorageHelper.setOwner(address(facet), address(this));
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), mockRegistry);

        // WETH is an available asset (required by the isAssetAvailable check)
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), assets);

        // Whitelist Merkl distributor in the mock registry
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, MERKL_DISTRIBUTOR),
            abi.encode(true)
        );

        // Build a single-leaf merkle tree for our facet:
        //   leaf = keccak256(abi.encode(user, token, amount))
        // Single-leaf tree → root == leaf, proof == []
        merkleRoot = keccak256(abi.encode(address(facet), WETH, CLAIM_AMOUNT));

        // Inject our custom root into the real Merkl distributor
        vm.store(MERKL_DISTRIBUTOR, bytes32(MERKL_ROOT_SLOT), merkleRoot);

        // Fund the Merkl distributor with WETH to cover the payout
        deal(WETH, MERKL_DISTRIBUTOR, CLAIM_AMOUNT * 10);

        console.log("Facet address:  ", address(facet));
        console.log("Merkle root:    "); console.logBytes32(merkleRoot);
    }

    // =========================================================================
    // Happy path — real Merkl verification + real WETH transfer
    // =========================================================================

    function test_claimMerklRewards_realMerklDistributor_WETH() public {
        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        tokens[0]  = WETH;
        amounts[0] = CLAIM_AMOUNT;
        proofs[0]  = new bytes32[](0); // single-leaf tree → empty proof

        uint256 balanceBefore = IERC20(WETH).balanceOf(address(facet));

        vm.prank(curator);
        vm.expectEmit(true, true, true, true);
        emit IMerkleRewardsHandlerFacet.MerklRewardsClaimed(WETH, CLAIM_AMOUNT, address(facet));
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);

        uint256 balanceAfter = IERC20(WETH).balanceOf(address(facet));

        console.log("WETH balance before:", balanceBefore);
        console.log("WETH balance after: ", balanceAfter);

        assertEq(balanceAfter - balanceBefore, CLAIM_AMOUNT, "WETH not received from Merkl");
    }

    function test_claimMerklRewards_idempotent_second_claim_transfers_zero() public {
        // First claim
        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = WETH; amounts[0] = CLAIM_AMOUNT; proofs[0] = new bytes32[](0);

        vm.prank(curator);
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);

        uint256 balanceAfterFirst = IERC20(WETH).balanceOf(address(facet));

        // Second claim with same proof — Merkl delta = 0, no transfer
        vm.prank(curator);
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);

        uint256 balanceAfterSecond = IERC20(WETH).balanceOf(address(facet));
        assertEq(balanceAfterFirst, balanceAfterSecond, "Balance should not change on second claim");
    }

    // =========================================================================
    // Validation / revert tests (against real distributor + real token)
    // =========================================================================

    function test_claimMerklRewards_revert_tokenNotAvailable() public {
        address unknownToken = makeAddr("unknownToken");
        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = unknownToken; amounts[0] = CLAIM_AMOUNT; proofs[0] = new bytes32[](0);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IMerkleRewardsHandlerFacet.UnsupportedAsset.selector, unknownToken)
        );
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_revert_wrongProof() public {
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("wrong");

        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = WETH; amounts[0] = CLAIM_AMOUNT; proofs[0] = badProof;

        vm.prank(curator);
        vm.expectRevert();
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_revert_distributorNotWhitelisted() public {
        address fakeDistributor = makeAddr("fakeDistributor");

        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = WETH; amounts[0] = CLAIM_AMOUNT; proofs[0] = new bytes32[](0);

        vm.prank(curator);
        vm.expectRevert();
        facet.claimMerklRewards(fakeDistributor, tokens, amounts, proofs);
    }

    function test_claimMerklRewards_revert_notCurator() public {
        address[] memory tokens  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = WETH; amounts[0] = CLAIM_AMOUNT; proofs[0] = new bytes32[](0);

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        facet.claimMerklRewards(MERKL_DISTRIBUTOR, tokens, amounts, proofs);
    }
}
