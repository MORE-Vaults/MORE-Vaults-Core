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
 */
contract MerklRewardsFacet is BaseFacetInitializer, IMerklRewardsFacet {
    /// @notice Storage position for MerklRewardsFacet
    bytes32 private constant MERKL_REWARDS_STORAGE_POSITION = keccak256("MoreVaults.storage.MerklRewardsFacet");

    struct MerklRewardsStorage {
        address merklDistributor;
    }

    function merklRewardsStorage() internal pure returns (MerklRewardsStorage storage ms) {
        bytes32 position = MERKL_REWARDS_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

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
     * @notice Initialize the facet with Merkl Distributor address
     * @param data ABI-encoded Merkl Distributor address
     */
    function initialize(bytes calldata data) external initializerFacet {
        address distributor = abi.decode(data, (address));
        if (distributor == address(0)) revert InvalidDistributorAddress();

        MerklRewardsStorage storage ms = merklRewardsStorage();
        ms.merklDistributor = distributor;

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerklRewardsFacet).interfaceId] = true;

        emit MerklDistributorSet(distributor);
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IMerklRewardsFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IMerklRewardsFacet
     */
    function claimMerklRewards(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        // Prevent calls during multicall
        MoreVaultsLib.validateNotMulticall();

        // Only curator or owner can claim rewards
        AccessControlLib.validateCurator(msg.sender);

        // Validate array lengths
        if (users.length != tokens.length || tokens.length != amounts.length || amounts.length != proofs.length) {
            revert InvalidArrayLength();
        }

        MerklRewardsStorage storage ms = merklRewardsStorage();
        if (ms.merklDistributor == address(0)) revert InvalidDistributorAddress();

        // Call Merkl Distributor to claim rewards
        try IMerklDistributor(ms.merklDistributor).claim(users, tokens, amounts, proofs) {
            // Emit events for each claimed reward
            for (uint256 i = 0; i < tokens.length;) {
                emit MerklRewardsClaimed(tokens[i], amounts[i], address(this));
                unchecked {
                    ++i;
                }
            }
        } catch {
            revert ClaimFailed();
        }
    }

    /**
     * @inheritdoc IMerklRewardsFacet
     */
    function claimMerklRewardsWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients
    ) external {
        // Prevent calls during multicall
        MoreVaultsLib.validateNotMulticall();

        // Only curator or owner can claim rewards
        AccessControlLib.validateCurator(msg.sender);

        // Validate array lengths
        if (
            users.length != tokens.length || tokens.length != amounts.length || amounts.length != proofs.length
                || proofs.length != recipients.length
        ) {
            revert InvalidArrayLength();
        }

        MerklRewardsStorage storage ms = merklRewardsStorage();
        if (ms.merklDistributor == address(0)) revert InvalidDistributorAddress();

        // Empty datas array for claimWithRecipient
        bytes[] memory datas = new bytes[](tokens.length);

        // Call Merkl Distributor to claim rewards with custom recipients
        try IMerklDistributor(ms.merklDistributor).claimWithRecipient(
            users, tokens, amounts, proofs, recipients, datas
        ) {
            // Emit events for each claimed reward
            for (uint256 i = 0; i < tokens.length;) {
                emit MerklRewardsClaimed(tokens[i], amounts[i], recipients[i]);
                unchecked {
                    ++i;
                }
            }
        } catch {
            revert ClaimFailed();
        }
    }

    /**
     * @inheritdoc IMerklRewardsFacet
     */
    function setMerklDistributor(address distributor) external {
        AccessControlLib.validateDiamond(msg.sender);

        if (distributor == address(0)) revert InvalidDistributorAddress();

        MerklRewardsStorage storage ms = merklRewardsStorage();
        ms.merklDistributor = distributor;

        emit MerklDistributorSet(distributor);
    }

    /**
     * @inheritdoc IMerklRewardsFacet
     */
    function getMerklDistributor() external view returns (address) {
        MerklRewardsStorage storage ms = merklRewardsStorage();
        return ms.merklDistributor;
    }
}
