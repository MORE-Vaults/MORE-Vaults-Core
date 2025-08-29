// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MoreVaultsDiamond} from "../MoreVaultsDiamond.sol";
import {DiamondCutFacet} from "../facets/DiamondCutFacet.sol";
import {IDiamondCut} from "../interfaces/facets/IDiamondCut.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {IGenericMoreVaultFacetInitializable} from "../interfaces/facets/IGenericMoreVaultFacetInitializable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";

/**
 * @title VaultsFactory
 * @notice Factory contract for deploying new vault instances
 */
contract VaultsFactory is IVaultsFactory, AccessControlUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Thrown when non-vault tries to link or unlink facet.
    error NotAuthorizedToLinkFacets(address);
    /// @dev Registry contract address
    IMoreVaultsRegistry public registry;

    /// @dev DiamondCutFacet address
    address public diamondCutFacet;

    /// @dev AccessContorlFacet address
    address public accessControlFacet;

    /// @dev Mapping vault address => is deployed by this factory
    mapping(address => bool) public isFactoryVault;

    /// @dev Array of all deployed vaults
    address[] public deployedVaults;

    /// @dev Address of the wrapped native token
    address public wrappedNative;

    /// @dev Address set of restricted facets
    EnumerableSet.AddressSet private _restrictedFacets;

    /// @dev Mapping facet address => vaults using this facet array
    mapping(address => EnumerableSet.AddressSet) private _linkedVaults;

    function initialize(
        address _registry,
        address _diamondCutFacet,
        address _accessControlFacet,
        address _wrappedNative
    ) external initializer {
        if (
            _registry == address(0) ||
            _diamondCutFacet == address(0) ||
            _accessControlFacet == address(0) ||
            _wrappedNative == address(0)
        ) revert ZeroAddress();
        _setDiamondCutFacet(_diamondCutFacet);
        _setAccessControlFacet(_accessControlFacet);

        wrappedNative = _wrappedNative;

        registry = IMoreVaultsRegistry(_registry);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Set the diamond cut facet address, that manages addition and removal of facets
     * @param _diamondCutFacet The address of the diamond cut facet
     */
    function setDiamondCutFacet(
        address _diamondCutFacet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDiamondCutFacet(_diamondCutFacet);
    }

    /**
     * @notice Set the access control facet address, that manages ownership and roles of the vault
     * @param _accessControlFacet The address of the access control facet
     */
    function setAccessControlFacet(
        address _accessControlFacet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setAccessControlFacet(_accessControlFacet);
    }

    /**
     * @notice pauses all vaults using this facet
     * @param _facet address of the facet
     */
    function pauseFacet(address _facet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address[] memory vaults = _linkedVaults[_facet].values();
        _setFacetRestricted(_facet, true);
        for (uint256 i = 0; i < vaults.length; ) {
            IVaultFacet(vaults[i]).pause();
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice sets restricted flag for facet
     * @param _facet address of facet
     * @param _isRestricted bool flag
     */
    function setFacetRestricted(
        address _facet,
        bool _isRestricted
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFacetRestricted(_facet, _isRestricted);
    }

    /**
     * @notice link the vault to the facet
     * @param _facet address of the facet
     */
    function link(address _facet) external {
        if (!isFactoryVault[msg.sender]) {
            revert NotAuthorizedToLinkFacets(msg.sender);
        }

        _linkedVaults[_facet].add(msg.sender);
    }

    /**
     * @notice unlink the vault from the facet
     * @param _facet address of the facet
     */
    function unlink(address _facet) external {
        if (!isFactoryVault[msg.sender]) {
            revert NotAuthorizedToLinkFacets(msg.sender);
        }
        _linkedVaults[_facet].remove(msg.sender);
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function deployVault(
        IDiamondCut.FacetCut[] calldata facets,
        bytes memory accessControlFacetInitData
    ) external returns (address vault) {
        // Deploy new MoreVaultsDiamond (vault)
        vault = address(
            new MoreVaultsDiamond(
                diamondCutFacet,
                accessControlFacet,
                address(registry),
                wrappedNative,
                facets,
                accessControlFacetInitData
            )
        );
        isFactoryVault[vault] = true;
        deployedVaults.push(vault);
        _linkedVaults[diamondCutFacet].add(vault);
        _linkedVaults[accessControlFacet].add(vault);
        for (uint256 i = 0; i < facets.length; ) {
            _linkedVaults[facets[i].facetAddress].add(vault);
            unchecked {
                ++i;
            }
        }
        emit VaultDeployed(vault, address(registry), wrappedNative, facets);
    }

    /**
     * @notice Get all deployed vaults
     * @return Array of vault addresses
     */
    function getDeployedVaults()
        external
        view
        override
        returns (address[] memory)
    {
        return deployedVaults;
    }

    /**
     * @notice Get number of deployed vaults
     * @return Number of vaults
     */
    function getVaultsCount() external view override returns (uint256) {
        return deployedVaults.length;
    }

    /**
     * @notice Check if address is a vault deployed by this factory
     * @param vault Address to check
     * @return bool True if vault was deployed by this factory
     */
    function isVault(address vault) external view override returns (bool) {
        return isFactoryVault[vault];
    }

    /**
     * @notice Returns vaults addresses using this facet
     * @param _facet address of the facet
     * @return vaults of the vaults that are linked to the facet
     */
    function getLinkedVaults(
        address _facet
    ) external view returns (address[] memory vaults) {
        vaults = _linkedVaults[_facet].values();
    }

    /**
     * @notice Returns facet addresses that are restricted
     * @return facets addresses of the restricted facets
     */
    function getRestrictedFacets()
        external
        view
        returns (address[] memory facets)
    {
        facets = _restrictedFacets.values();
    }

    /**
     * @notice Returns bool flag if vault linked to the facet
     * @param _facet address of the facet
     * @param _vault address of the vault
     */
    function isVaultLinked(
        address _facet,
        address _vault
    ) external view returns (bool) {
        return _linkedVaults[_facet].contains(_vault);
    }

    function _setDiamondCutFacet(address _diamondCutFacet) internal {
        if (_diamondCutFacet == address(0)) revert ZeroAddress();
        diamondCutFacet = _diamondCutFacet;
        emit DiamondCutFacetUpdated(diamondCutFacet);
    }

    function _setAccessControlFacet(address _accessControlFacet) internal {
        if (_accessControlFacet == address(0)) revert ZeroAddress();
        accessControlFacet = _accessControlFacet;
    }

    function _setFacetRestricted(address _facet, bool _isRestricted) private {
        if (_isRestricted) _restrictedFacets.add(_facet);
        else _restrictedFacets.remove(_facet);

        emit SetFacetRestricted(_facet, _isRestricted);
    }
}
