// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoreVaultsRegistry} from "./IMoreVaultsRegistry.sol";
import {IDiamondCut} from "./facets/IDiamondCut.sol";

interface IVaultsFactory {
    error InvalidSelector(address facet, bytes4 selector);
    error ZeroAddress();
    error EmptyFacets();
    error InvalidTimeLock();
    error InvalidFee();

    event VaultDeployed(
        address indexed vault,
        address registry,
        address wrappedNative,
        IDiamondCut.FacetCut[] facets
    );

    event DiamondCutFacetUpdated(address indexed newDiamondCutFacet);

    event SetFacetRestricted(
        address indexed _facet,
        bool indexed _isRestricted
    );

    /**
     * @notice Initialize the factory
     * @param _registry Registry contract address
     * @param _diamondCutFacet Diamond cut facet address
     * @param _wrappedNative Wrapped native token address
     */
    function initialize(
        address _registry,
        address _diamondCutFacet,
        address _accessControlFacet,
        address _wrappedNative
    ) external;

    /**
     * @notice Get registry contract address
     * @return address Registry address
     */
    function registry() external view returns (IMoreVaultsRegistry);

    /**
     * @notice Check if vault was deployed by this factory
     * @param vault Address to check
     * @return bool True if vault was deployed by this factory
     */
    function isFactoryVault(address vault) external view returns (bool);

    /**
     * @notice Get vault by index
     * @param index Index of vault
     * @return address Vault address
     */
    function deployedVaults(uint256 index) external view returns (address);

    /**
     * @notice Deploy new vault instance
     * @param facetCuts Array of facets to add
     * @param accessControlFacetInitData encoded data that contains addresses of owner, curator and guardian
     * @return vault Address of deployed vault
     */
    function deployVault(
        IDiamondCut.FacetCut[] calldata facetCuts,
        bytes memory accessControlFacetInitData
    ) external returns (address vault);

    /**
     * @notice link the vault to the facet
     * @param facet address of the facet
     */
    function link(address facet) external;

    /**
     * @notice unlink the vault from the facet
     * @param facet address of the facet
     */
    function unlink(address facet) external;

    /**
     * @notice pauses all vaults using this facet
     * @param facet address of the facet
     */
    function pauseFacet(address facet) external;

    /**
     * @notice sets restricted flag for facet
     * @param _facet address of facet
     * @param _isRestricted bool flag
     */
    function setFacetRestricted(address _facet, bool _isRestricted) external;

    /**
     * @notice Get all deployed vaults
     * @return Array of vault addresses
     */
    function getDeployedVaults() external view returns (address[] memory);

    /**
     * @notice Get number of deployed vaults
     * @return Number of vaults
     */
    function getVaultsCount() external view returns (uint256);

    /**
     * @notice Check if address is a vault deployed by this factory
     * @param vault Address to check
     * @return bool True if vault was deployed by this factory
     */
    function isVault(address vault) external view returns (bool);

    /**
     * @notice Returns vaults addresses using this facet
     * @param _facet address of the facet
     */
    function getLinkedVaults(
        address _facet
    ) external returns (address[] memory vaults);

    /**
     * @notice Returns bool flag if vault linked to the facet
     * @param _facet address of the facet
     * @param _vault address of the vault
     */
    function isVaultLinked(
        address _facet,
        address _vault
    ) external returns (bool);

    /**
     * @notice Returns facet addresses that are restricted
     * @return facets addresses of the restricted facets
     */
    function getRestrictedFacets() external returns (address[] memory facets);
}
