// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "./MoreVaultsLib.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";

/**
 * @title AccessControlLib
 * @notice Library for managing access control in diamond proxy
 */
library AccessControlLib {
    /**
     * @dev Custom errors for access control
     */
    error UnauthorizedAccess();
    error ZeroAddress();
    error SameAddress();
    error NotPendingOwner();

    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION =
        keccak256("MoreVaults.accessControl.storage");

    struct AccessControlStorage {
        address owner;
        address curator;
        address guardian;
        address moreVaultsRegistry;
        address pendingOwner;
    }

    /**
     * @dev Emitted when owner address is changed
     */
    event OwnerChanged(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Emitted when pending owner address is changed
     */
    event PendingOwnerSet(address indexed newPendingOwner);

    /**
     * @dev Emitted when curator address is changed
     */
    event CuratorChanged(
        address indexed previousCurator,
        address indexed newCurator
    );

    /**
     * @dev Emitted when guardian address is changed
     */
    event GuardianChanged(
        address indexed previousGuardian,
        address indexed newGuardian
    );

    function accessControlStorage()
        internal
        pure
        returns (AccessControlStorage storage acs)
    {
        bytes32 position = ACCESS_CONTROL_STORAGE_POSITION;
        // assigns struct storage slot to the storage position
        assembly {
            acs.slot := position
        }
    }

    /**
     * @notice Validates if caller is owner
     * @param caller Address to validate
     */
    function validateOwner(address caller) internal view {
        if (caller != accessControlStorage().owner) {
            revert UnauthorizedAccess();
        }
    }

    function validatePendingOwner(address caller) internal view {
        if (caller != accessControlStorage().pendingOwner) {
            revert UnauthorizedAccess();
        }
    }

    /**
     * @notice Validates if caller is curator
     * @param caller Address to validate
     */
    function validateCurator(address caller) internal view {
        if (
            caller != accessControlStorage().curator &&
            accessControlStorage().owner != caller
        ) {
            revert UnauthorizedAccess();
        }
    }

    /**
     * @notice Validates if caller is guardian or owner
     * @param caller Address to validate
     */
    function validateGuardian(address caller) internal view {
        if (
            accessControlStorage().guardian != caller &&
            accessControlStorage().owner != caller
        ) {
            revert UnauthorizedAccess();
        }
    }

    function validateDiamond(address caller) internal view {
        if (caller != address(this)) {
            revert UnauthorizedAccess();
        }
    }

    function setPendingOwner(address _newPendingOwner) internal {
        if (_newPendingOwner == accessControlStorage().owner) {
            revert SameAddress();
        }

        accessControlStorage().pendingOwner = _newPendingOwner;

        emit PendingOwnerSet(_newPendingOwner);
    }

    /**
     * @notice Sets new owner address
     * @param _newOwner Address of new owner
     */
    function setVaultOwner(address _newOwner) internal {
        if (_newOwner == address(0)) {
            revert ZeroAddress();
        }

        AccessControlStorage storage acs = accessControlStorage();

        if (_newOwner == acs.owner) {
            revert SameAddress();
        }

        address previousOwner = acs.owner;
        acs.owner = _newOwner;

        emit OwnerChanged(previousOwner, _newOwner);
    }

    /**
     * @notice Sets new curator address
     * @param _newCurator Address of new curator
     */
    function setVaultCurator(address _newCurator) internal {
        if (_newCurator == address(0)) {
            revert ZeroAddress();
        }

        AccessControlStorage storage acs = accessControlStorage();

        if (_newCurator == acs.curator) {
            revert SameAddress();
        }

        address previousCurator = acs.curator;
        acs.curator = _newCurator;

        emit CuratorChanged(previousCurator, _newCurator);
    }

    /**
     * @notice Sets new guardian address
     * @param _newGuardian Address of new guardian
     */
    function setVaultGuardian(address _newGuardian) internal {
        if (_newGuardian == address(0)) {
            revert ZeroAddress();
        }

        AccessControlStorage storage acs = accessControlStorage();

        if (_newGuardian == acs.guardian) {
            revert SameAddress();
        }

        address previousGuardian = acs.guardian;
        acs.guardian = _newGuardian;

        emit GuardianChanged(previousGuardian, _newGuardian);
    }

    function setMoreVaultsRegistry(address _newRegistry) internal {
        if (_newRegistry == address(0)) {
            revert ZeroAddress();
        }

        AccessControlStorage storage acs = accessControlStorage();

        if (_newRegistry == acs.moreVaultsRegistry) {
            revert SameAddress();
        }

        acs.moreVaultsRegistry = _newRegistry;
    }

    /**
     * @notice Gets current owner address
     * @return Address of current owner
     */
    function vaultOwner() internal view returns (address) {
        return accessControlStorage().owner;
    }

    function pendingOwner() internal view returns (address) {
        return accessControlStorage().pendingOwner;
    }

    /**
     * @notice Gets current curator address
     * @return Address of current curator
     */
    function vaultCurator() internal view returns (address) {
        return accessControlStorage().curator;
    }

    /**
     * @notice Gets current guardian address
     * @return Address of current guardian
     */
    function vaultGuardian() internal view returns (address) {
        return accessControlStorage().guardian;
    }

    function vaultRegistry() internal view returns (address) {
        return accessControlStorage().moreVaultsRegistry;
    }
}
