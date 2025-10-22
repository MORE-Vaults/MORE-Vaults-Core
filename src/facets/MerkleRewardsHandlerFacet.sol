// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IMerkleRewardsHandlerFacet} from "../interfaces/facets/IMerkleRewardsHandlerFacet.sol";
import {IMerklDistributor} from "../interfaces/external/IMerklDistributor.sol";
import {IUniversalRewardsDistributor} from "../interfaces/external/IUniversalRewardsDistributor.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

/**
 * @title MerkleRewardsHandlerFacet
 * @notice Facet for claiming merkle-based rewards from multiple protocols
 * @dev Supports both Merkl Protocol and Morpho Universal Rewards Distributor
 * @dev Allows curator/owner to claim rewards earned by the vault
 * @dev Follows the same pattern as ERC4626Facet - validates distributor addresses via registry
 */
contract MerkleRewardsHandlerFacet is BaseFacetInitializer, IMerkleRewardsHandlerFacet {
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.MerkleRewardsHandlerFacet");
    }

    function facetName() external pure returns (string memory) {
        return "MerkleRewardsHandlerFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Initialize the facet
     */
    function initialize(bytes calldata /* data */) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerkleRewardsHandlerFacet).interfaceId] = true;
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerkleRewardsHandlerFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IMerkleRewardsHandlerFacet
     */
    function claimMerklRewards(
        address distributor,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        // Prevent calls during multicall
        MoreVaultsLib.validateNotMulticall();

        // Only curator or owner can claim rewards
        AccessControlLib.validateCurator(msg.sender);

        // Validate distributor is whitelisted in registry
        MoreVaultsLib.validateAddressWhitelisted(distributor);

        // Validate array lengths
        if (tokens.length != amounts.length || amounts.length != proofs.length) {
            revert InvalidArrayLength();
        }

        // Build users array internally - always claim to the vault
        address[] memory users = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length;) {
            users[i] = address(this);
            unchecked {
                ++i;
            }
        }

        // Call Merkl Distributor to claim rewards
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);

        // Emit events for each claimed reward
        for (uint256 i = 0; i < tokens.length;) {
            emit MerklRewardsClaimed(tokens[i], amounts[i], address(this));
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IMerkleRewardsHandlerFacet
     */
    function claimMorphoReward(
        address distributor,
        address reward,
        uint256 claimable,
        bytes32[] calldata proof
    ) external returns (uint256 amount) {
        // Prevent calls during multicall
        MoreVaultsLib.validateNotMulticall();

        // Only curator or owner can claim rewards
        AccessControlLib.validateCurator(msg.sender);

        // Validate distributor is whitelisted in registry
        MoreVaultsLib.validateAddressWhitelisted(distributor);

        // Call Morpho URD to claim rewards
        // The distributor will calculate: amount = claimable - claimed[vault][reward]
        amount = IUniversalRewardsDistributor(distributor).claim(address(this), reward, claimable, proof);

        // Emit event for claimed reward
        emit MorphoRewardClaimed(reward, amount, address(this));
    }
}
