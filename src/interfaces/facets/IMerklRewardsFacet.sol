// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

interface IMerklRewardsFacet is IGenericMoreVaultFacetInitializable {
    /**
     * @dev Custom errors
     */
    error InvalidArrayLength();

    /**
     * @dev Events
     */
    /// @notice Emitted when rewards are claimed from Merkl
    event MerklRewardsClaimed(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Claims rewards from Merkl Distributor to the vault
     * @dev Only callable by curator or owner. Always claims rewards to the vault (address(this)).
     * @dev The distributor address must be whitelisted in the MoreVaultsRegistry.
     * @param distributor Address of the Merkl Distributor contract
     * @param tokens Array of reward token addresses to claim
     * @param amounts Array of claimable amounts for each token
     * @param proofs Array of merkle proofs for each claim
     */
    function claimMerklRewards(
        address distributor,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
