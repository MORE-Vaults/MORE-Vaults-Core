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

    event VaultDeployed(address indexed vault, address registry, address wrappedNative, IDiamondCut.FacetCut[] facets);

    event DiamondCutFacetUpdated(address indexed newDiamondCutFacet);
    event AccessControlFacetUpdated(address indexed newAccessControlFacet);
    event MaxFinalizationTimeUpdated(uint96 indexed newMaxFinalizationTime);
    event CrossChainLinkRequested(
        uint32 indexed dstChainId, address indexed initiator, address indexed vaultToLink, address remoteVault
    );
    event CrossChainLinked(uint32 indexed linkedVaultChainId, address indexed linkedVault, address indexed localVault);

    event SetFacetRestricted(address indexed _facet, bool indexed _isRestricted);

    /**
     * @notice Initialize the factory
     * @param _owner Owner address
     * @param _registry Registry contract address
     * @param _diamondCutFacet Diamond cut facet address
     * @param _accessControlFacet Access control facet address
     * @param _wrappedNative Wrapped native token address
     * @param _localEid LayerZero endpoint id for this chain
     * @param _maxFinalizationTime Maximum finalization time of block for a chain
     */
    function initialize(
        address _owner,
        address _registry,
        address _diamondCutFacet,
        address _accessControlFacet,
        address _wrappedNative,
        uint32 _localEid,
        uint96 _maxFinalizationTime
    ) external;

    /**
     * @notice Spoke requests registration on Hub
     */
    function requestRegisterSpoke(uint32 _hubEid, address _hubVault, address _spokeVault, bytes calldata _options)
        external
        payable;

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
        bytes memory accessControlFacetInitData,
        bool isHub,
        bytes32 salt
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
    function getLinkedVaults(address _facet) external returns (address[] memory vaults);

    /**
     * @notice Returns bool flag if vault linked to the facet
     * @param _facet address of the facet
     * @param _vault address of the vault
     */
    function isVaultLinked(address _facet, address _vault) external returns (bool);

    /**
     * @notice Returns facet addresses that are restricted
     * @return facets addresses of the restricted facets
     */
    function getRestrictedFacets() external returns (address[] memory facets);

    /**
     * @notice Returns hub to spokes
     * @param _chainId chain id
     * @param _hubVault hub vault
     * @return eids endpoint ids of spokes
     * @return vaults addresses of spokes
     */
    function hubToSpokes(uint32 _chainId, address _hubVault)
        external
        view
        returns (uint32[] memory eids, address[] memory vaults);

    /**
     * @notice Returns spoke to hub
     * @param _chainId chain id
     * @param _spokeVault spoke vault
     * @return eid endpoint id of hub
     * @return vault address of hub vault
     */
    function spokeToHub(uint32 _chainId, address _spokeVault) external view returns (uint32 eid, address vault);

    /**
     * @notice Checks whether a hub has a given spoke linked
     * @param _hubEid Hub endpoint id
     * @param _hubVault Hub vault address
     * @param _spokeEid Spoke endpoint id
     * @param _spokeVault Spoke vault address
     * @return bool True if the spoke is linked to the hub
     */
    function isSpokeOfHub(uint32 _hubEid, address _hubVault, uint32 _spokeEid, address _spokeVault)
        external
        view
        returns (bool);

    /**
     * @notice Checks whether a vault is a cross-chain vault
     * @param _chainId Chain id
     * @param _vault Vault address
     * @return bool True if the vault is a cross-chain vault
     */
    function isCrossChainVault(uint32 _chainId, address _vault) external view returns (bool);

    /**
     * @notice Returns local EID
     * @return local EID
     */
    function localEid() external view returns (uint32);
}
