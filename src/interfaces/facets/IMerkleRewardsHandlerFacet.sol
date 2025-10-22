// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

interface IMerkleRewardsHandlerFacet is IGenericMoreVaultFacetInitializable {
    /**
     * @dev Custom errors
     */
    error InvalidArrayLength();

    /**
     * @dev Events
     */
    /// @notice Emitted when rewards are claimed from Merkl Protocol
    event MerklRewardsClaimed(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Emitted when rewards are claimed from Morpho URD
    event MorphoRewardClaimed(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Claims rewards from Merkl Protocol Distributor to the vault
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

    /**
     * @notice Claims rewards from Morpho Universal Rewards Distributor to the vault
     * @dev Only callable by curator or owner. Always claims rewards to the vault (address(this)).
     * @dev The distributor address must be whitelisted in the MoreVaultsRegistry.
     * @param distributor Address of the Morpho URD contract
     * @param reward Address of the reward token to claim
     * @param claimable Total claimable amount (not the delta)
     * @param proof Merkle proof for verification
     * @return amount The actual amount of tokens claimed (delta between claimable and already claimed)
     */
    function claimMorphoReward(
        address distributor,
        address reward,
        uint256 claimable,
        bytes32[] calldata proof
    ) external returns (uint256 amount);
}
