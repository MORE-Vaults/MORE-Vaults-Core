// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IAccessControlFacet} from "../interfaces/facets/IAccessControlFacet.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

contract AccessControlFacet is BaseFacetInitializer, IAccessControlFacet {
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.AccessControlFacetV1.0.1");
    }

    function facetName() external pure returns (string memory) {
        return "AccessControlFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.1";
    }

    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        if (AccessControlLib.vaultOwner() == address(0)) {
            (address _owner, address _curator, address _guardian) = abi.decode(data, (address, address, address));
            AccessControlLib.setVaultOwner(_owner);
            AccessControlLib.setVaultCurator(_curator);
            AccessControlLib.setVaultGuardian(_guardian);
        }

        ds.supportedInterfaces[type(IAccessControlFacet).interfaceId] = true; // AccessControlFacet
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IAccessControlFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function transferOwnership(address _newOwner) external {
        AccessControlLib.validateDiamond(msg.sender);
        AccessControlLib.setPendingOwner(_newOwner);
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function acceptOwnership() external {
        AccessControlLib.validatePendingOwner(msg.sender);
        AccessControlLib.setVaultOwner(msg.sender);
        AccessControlLib.setPendingOwner(address(0));
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function transferCuratorship(address _newCurator) external {
        AccessControlLib.validateDiamond(msg.sender);
        AccessControlLib.setVaultCurator(_newCurator);
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function transferGuardian(address _newGuardian) external {
        AccessControlLib.validateDiamond(msg.sender);
        AccessControlLib.setVaultGuardian(_newGuardian);
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function owner() external view returns (address) {
        return AccessControlLib.vaultOwner();
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function pendingOwner() external view returns (address) {
        return AccessControlLib.pendingOwner();
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function curator() external view returns (address) {
        return AccessControlLib.vaultCurator();
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function guardian() external view returns (address) {
        return AccessControlLib.vaultGuardian();
    }

    /**
     * @inheritdoc IAccessControlFacet
     */
    function moreVaultsRegistry() external view returns (address) {
        return AccessControlLib.vaultRegistry();
    }
}
