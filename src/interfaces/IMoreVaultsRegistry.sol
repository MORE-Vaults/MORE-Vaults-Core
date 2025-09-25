// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleRegistry} from "./IOracleRegistry.sol";

/**
 * @title IVaultRegistry
 * @notice Interface for VaultRegistry contract that manages allowed facets and their selectors
 */
interface IMoreVaultsRegistry {
    error ZeroAddress();
    error FacetAlreadyExists(address facet);
    error FacetNotAllowed(address facet);
    error SelectorAlreadyExists(address facet, bytes4 selector);

    struct ProtocolFeeInfo {
        address recipient;
        uint96 fee;
    }

    /**
     * @dev Emitted when new facet is added with its selectors
     * @param facet Address of added facet
     * @param selectors Array of function selectors
     */
    event FacetAdded(address indexed facet, bytes4[] selectors);

    /**
     * @dev Emitted when facet is edited
     * @param facet Address of edited facet
     * @param selectors Array of function selectors
     * @param addOrRemove Array with flags for add/remove of selector with same index
     */
    event FacetEdited(
        address indexed facet,
        bytes4[] selectors,
        bool[] addOrRemove
    );

    /**
     * @dev Emitted when facet is removed
     * @param facet Address of removed facet
     */
    event FacetRemoved(address indexed facet);

    /**
     * @dev Emitted when oracle registry address is updated
     * @param oldOracleRegistry Previous oracle registry address
     * @param newOracleRegistry New oracle registry address
     */
    event OracleRegistryUpdated(
        address indexed oldOracleRegistry,
        address indexed newOracleRegistry
    );

    /**
     * @dev Emitted when protocol fee info is updated
     * @param vault Address of the vault
     * @param recipient Address of the protocol fee recipient
     * @param fee Protocol fee
     */
    event ProtocolFeeInfoUpdated(
        address indexed vault,
        address indexed recipient,
        uint96 fee
    );

    /**
     * @dev Emitted when protocol is whitelisted
     * @param protocol Address of the protocol
     * @param whitelisted True if protocol is whitelisted, false otherwise
     */
    event AddressWhitelisted(address indexed protocol, bool whitelisted);

    /**
     * @dev Emitted when bridge is allowed
     * @param bridge Address of the bridge
     * @param allowed True if bridge is allowed, false otherwise
     */
    event BridgeUpdated(address indexed bridge, bool allowed);

    /**
     * @dev Emitted when cross chain accounting manager is updated
     * @param manager Address of the cross chain accounting manager
     * @param isManager True if cross chain accounting manager is allowed, false otherwise
     */
    event CrossChainAccountingManagerSet(
        address indexed manager,
        bool isManager
    );

    /**
     * @dev Emitted when trusted OFT status is updated
     * @param oft Address of the OFT
     * @param trusted True if OFT is trusted, false otherwise
     */
    event TrustedOFTUpdated(address indexed oft, bool trusted);

    /**
     * @dev Emitted when default cross chain accounting manager is set
     * @param manager Address of the default cross chain accounting manager
     */
    event DefaultCrossChainAccountingManagerSet(address indexed manager);

    /**
     * @notice Initialize the registry
     * @param _owner Address of the owner
     * @param _oracle Address of the oracle
     * @param _usdStableTokenAddress Address of the USD stable token
     */
    function initialize(
        address _owner,
        address _oracle,
        address _usdStableTokenAddress
    ) external;

    /**
     * @notice returns bool flag if registry is permissionless
     * @return bool flag if registry permissionless or not
     */
    function isPermissionless() external view returns (bool);

    /**
     * @notice Add new facet with its selectors, also can add new selectors to existing facet
     * @param facet Address of the facet contract
     * @param selectors Array of function selectors
     */
    function addFacet(address facet, bytes4[] calldata selectors) external;

    /**
     * @notice Edit selectors for the facet
     * @param facet Address of the facet contract
     * @param selectors Array of function selectors
     * @param addOrRemove Array with flags for add/remove of selector with same index
     */
    function editFacet(
        address facet,
        bytes4[] calldata selectors,
        bool[] calldata addOrRemove
    ) external;

    /**
     * @notice Remove facet and all its selectors
     * @param facet Address of the facet contract
     */
    function removeFacet(address facet) external;

    /**
     * @notice Update oracle address
     * @param newOracleRegistry Address of new oracle registry
     */
    function updateOracleRegistry(address newOracleRegistry) external;

    /**
     * @notice Set protocol fee info
     * @param vault Address of the vault
     * @param recipient Address of the protocol fee recipient
     * @param fee Protocol fee
     */
    function setProtocolFeeInfo(
        address vault,
        address recipient,
        uint96 fee
    ) external;

    /**
     * @notice Set selector allowed
     * @param vault Address of the vault
     * @param selector Function selector
     * @param allowed True if selector is allowed, false otherwise
     * @param mask Mask for the selector
     */
    function setSelectorAndMask(
        address vault,
        bytes4 selector,
        bool allowed,
        bytes memory mask
    ) external;

    function setDefaultCrossChainAccountingManager(address manager) external;

    /**
     * @notice Get all selectors for facet
     * @param facet Address of the facet contract
     * @return Array of selectors
     */
    function getFacetSelectors(
        address facet
    ) external view returns (bytes4[] memory);

    /**
     * @notice Get list of all allowed facets
     * @return Array of facet addresses
     */
    function getAllowedFacets() external view returns (address[] memory);

    /**
     * @notice Get protocol fee info
     * @param vault Address of the vault
     * @return address Address of the protocol fee recipient
     * @return uint96 Protocol fee
     */
    function protocolFeeInfo(
        address vault
    ) external view returns (address, uint96);

    /**
     * @notice Get oracle address
     * @return IOracleRegistry Oracle registry contract
     */
    function oracle() external view returns (IOracleRegistry);

    /**
     * @notice Get facet address for selector
     * @param selector Function selector
     * @return address Facet address
     */
    function selectorToFacet(bytes4 selector) external view returns (address);

    /**
     * @notice Get facet address by index
     * @param index Index in facets list
     * @return address Facet address
     */
    function facetsList(uint256 index) external view returns (address);

    /**
     * @notice Get denomination asset decimals
     * @return uint8 Decimals of denomination asset
     */
    function getDenominationAssetDecimals() external view returns (uint8);

    /**
     * @notice Get denomination asset
     * @return address Denomination asset
     */
    function getDenominationAsset() external view returns (address);

    /**
     * @notice Check if facet is allowed
     * @param facet Address to check
     * @return bool True if facet is allowed
     */
    function isFacetAllowed(address facet) external view returns (bool);

    /**
     * @notice Add protocol to whitelist
     * @param protocol Address of the protocol
     */
    function addToWhitelist(address protocol) external;

    /**
     * @notice Remove protocol from whitelist
     * @param protocol Address of the protocol
     */
    function removeFromWhitelist(address protocol) external;

    /**
     * @notice Check if protocol is whitelisted
     * @param protocol Address of the protocol
     * @return bool True if protocol is whitelisted
     */
    function isWhitelisted(address protocol) external view returns (bool);

    /**
     * @notice Add bridge to allowed list
     * @param bridge Address of the bridge
     * @param allowed True if bridge is allowed, false otherwise
     */
    function setBridge(address bridge, bool allowed) external;

    /**
     * @notice Check if bridge is allowed
     * @param bridge Address of the bridge
     * @return bool True if bridge is allowed
     */
    function isBridgeAllowed(address bridge) external view returns (bool);

    /**
     * @notice Check if selector is allowed
     * @param vault Address of the vault
     * @param selector Function selector
     * @return bool True if selector is allowed
     * @return bytes Mask for the selector
     */
    function selectorInfo(
        address vault,
        bytes4 selector
    ) external view returns (bool, bytes memory);

    /**
     * @notice Batch set trust status for multiple OFT tokens
     * @param ofts Array of OFT token addresses
     * @param trusted Array of trust statuses (must match ofts length)
     */
    function setTrustedOFTs(
        address[] calldata ofts,
        bool[] calldata trusted
    ) external;

    /**
     * @notice Check if an OFT token is trusted for bridging
     * @param oft Address of the OFT token to check
     * @return bool True if the token is trusted, false otherwise
     */
    function isTrustedOFT(address oft) external view returns (bool);

    /**
     * @notice Get all trusted OFT tokens
     * @return address[] Array of trusted OFT addresses
     */
    function getTrustedOFTs() external view returns (address[] memory);

    /**
     * @notice Check if an address is a cross chain accounting manager
     * @param manager Address of the manager to check
     * @return bool True if the address is a cross chain accounting manager, false otherwise
     */
    function isCrossChainAccountingManager(
        address manager
    ) external view returns (bool);

    /**
     * @notice Get default cross chain accounting manager
     * @return address Default cross chain accounting manager
     */
    function defaultCrossChainAccountingManager()
        external
        view
        returns (address);
}
