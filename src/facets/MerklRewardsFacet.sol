// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IMerklRewardsFacet} from "../interfaces/facets/IMerklRewardsFacet.sol";
import {IMerklDistributor} from "../interfaces/external/IMerklDistributor.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

/**
 * @title MerklRewardsFacet
 * @notice Facet for claiming rewards from Merkl protocol
 * @dev Allows curator/owner to claim Merkl rewards earned by the vault
 * @dev Follows the same pattern as ERC4626Facet - validates distributor addresses via registry
 */
contract MerklRewardsFacet is BaseFacetInitializer, IMerklRewardsFacet {
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.MerklRewardsFacet");
    }

    function facetName() external pure returns (string memory) {
        return "MerklRewardsFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Initialize the facet
     */
    function initialize(bytes calldata /* data */) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerklRewardsFacet).interfaceId] = true;
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerklRewardsFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IMerklRewardsFacet
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
}
