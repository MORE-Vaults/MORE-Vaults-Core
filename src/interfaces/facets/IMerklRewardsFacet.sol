// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

interface IMerklRewardsFacet is IGenericMoreVaultFacetInitializable {
    /**
     * @dev Custom errors
     */
    error InvalidProofLength();
    error InvalidArrayLength();
    error ClaimFailed();
    error ClaimFailedWithReason(string reason);
    error InvalidDistributorAddress();

    /**
     * @dev Events
     */
    /// @notice Emitted when rewards are claimed from Merkl
    event MerklRewardsClaimed(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Emitted when the Merkl Distributor address is updated
    event MerklDistributorSet(address indexed distributor);

    /**
     * @notice Claims rewards from Merkl Distributor
     * @dev Only callable by curator or owner. Claims rewards to the vault.
     * @param users Array of user addresses (typically the vault address)
     * @param tokens Array of reward token addresses to claim
     * @param amounts Array of claimable amounts for each token
     * @param proofs Array of merkle proofs for each claim
     */
    function claimMerklRewards(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    /**
     * @notice Claims rewards from Merkl Distributor with custom recipient
     * @dev Only callable by curator or owner. Allows specifying a custom recipient for rewards.
     * @param users Array of user addresses (typically the vault address)
     * @param tokens Array of reward token addresses to claim
     * @param amounts Array of claimable amounts for each token
     * @param proofs Array of merkle proofs for each claim
     * @param recipients Array of recipient addresses for each claim
     */
    function claimMerklRewardsWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients
    ) external;

    /**
     * @notice Sets the Merkl Distributor contract address
     * @dev Only callable by owner through submitActions and timelocked
     * @param distributor The address of the Merkl Distributor contract
     */
    function setMerklDistributor(address distributor) external;

    /**
     * @notice Gets the current Merkl Distributor address
     * @return The address of the Merkl Distributor contract
     */
    function getMerklDistributor() external view returns (address);
}
