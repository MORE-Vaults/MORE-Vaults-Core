// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IMerklDistributor
 * @notice Interface for Merkl's Distributor contract
 * @dev Deployed at 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae on most chains
 */
interface IMerklDistributor {
    /**
     * @notice Claims rewards from Merkl
     * @param users Array of user addresses eligible for rewards
     * @param tokens Array of reward token addresses
     * @param amounts Array of claimable amounts
     * @param proofs Array of merkle proofs for verification
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    /**
     * @notice Claims rewards from Merkl with custom recipients
     * @param users Array of user addresses eligible for rewards
     * @param tokens Array of reward token addresses
     * @param amounts Array of claimable amounts
     * @param proofs Array of merkle proofs for verification
     * @param recipients Array of addresses to receive the rewards
     * @param datas Array of optional callback data
     */
    function claimWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients,
        bytes[] memory datas
    ) external;
}
