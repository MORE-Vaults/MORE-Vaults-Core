// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title BaseVaultsRegistry
 * @notice Base registry contract that stores information about allowed facets and their selectors
 */
abstract contract BaseVaultsRegistry is
    IMoreVaultsRegistry,
    AccessControlUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Aave price oracle address
    IOracleRegistry public oracle;

    /// @dev Mapping selector => facet address (показывает какому фасету принадлежит селектор)
    mapping(bytes4 => address) public selectorToFacet;

    /// @dev Mapping of facet address => all selectors
    mapping(address => bytes4[]) public facetSelectors;

    /// @dev List of all allowed facets
    EnumerableSet.AddressSet internal _facetsList;

    /// @dev USD stable token address
    address public usdStableTokenAddress;

    /// @dev Protocol fee info
    mapping(address => ProtocolFeeInfo) internal _protocolFeeInfo;

    /// @dev Whitelisted addresses of protocols that vault can interact with
    mapping(address => bool) private _whitelisted;

    /// @dev Initialize function
    function initialize(
        address _oracle,
        address _usdStableTokenAddress
    ) external virtual initializer {
        if (_oracle == address(0)) revert ZeroAddress();

        __AccessControl_init();
        oracle = IOracleRegistry(_oracle);
        usdStableTokenAddress = _usdStableTokenAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isPermissionless() external view virtual returns (bool);

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function updateOracleRegistry(
        address newOracleRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracleRegistry == address(0)) revert ZeroAddress();

        address oldOracleRegistry = address(oracle);
        oracle = IOracleRegistry(newOracleRegistry);

        emit OracleRegistryUpdated(oldOracleRegistry, newOracleRegistry);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function setProtocolFeeInfo(
        address vault,
        address recipient,
        uint96 fee
    ) external virtual;

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function facetsList(uint256 index) external view returns (address) {
        return _facetsList.at(index);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function getFacetSelectors(
        address facet
    ) external view returns (bytes4[] memory) {
        return facetSelectors[facet];
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function getAllowedFacets() external view returns (address[] memory) {
        return _facetsList.values();
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function protocolFeeInfo(
        address vault
    ) external view virtual returns (address, uint96);

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function getDenominationAsset() external view returns (address) {
        if (oracle.BASE_CURRENCY() == address(0)) return usdStableTokenAddress;
        return oracle.BASE_CURRENCY();
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function getDenominationAssetDecimals() external view returns (uint8) {
        address denominationAsset = oracle.BASE_CURRENCY();
        if (denominationAsset == address(0))
            return IERC20Metadata(usdStableTokenAddress).decimals();
        else return IERC20Metadata(denominationAsset).decimals();
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isFacetAllowed(address facet) external view returns (bool) {
        return _isFacetAllowed(facet);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function addFacet(
        address facet,
        bytes4[] calldata selectors
    ) external virtual;

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function editFacet(
        address facet,
        bytes4[] calldata selectors,
        bool[] calldata addOrRemove
    ) external virtual {}

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function removeFacet(address facet) external virtual;

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function addToWhitelist(address protocol) external virtual;

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function removeFromWhitelist(address protocol) external virtual;

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isWhitelisted(
        address protocol
    ) external view virtual returns (bool);

    /**
     * @notice Set whitelisted status for protocol
     * @param protocol Address of the protocol
     * @param whitelisted True if protocol is whitelisted, false otherwise
     */
    function _setWhitelisted(
        address protocol,
        bool whitelisted
    ) internal onlyRole(DEFAULT_ADMIN_ROLE) {
        _whitelisted[protocol] = whitelisted;
        emit AddressWhitelisted(protocol, whitelisted);
    }

    /**
     * @notice Check if protocol is whitelisted
     * @param protocol Address of the protocol
     * @return True if protocol is whitelisted, false otherwise
     */
    function _isWhitelisted(address protocol) internal view returns (bool) {
        return _whitelisted[protocol];
    }

    /**
     * @notice Internal function to check if facet is allowed
     * @param facet Address to check
     * @return bool True if facet is allowed
     */
    function _isFacetAllowed(
        address facet
    ) internal view virtual returns (bool);
}
