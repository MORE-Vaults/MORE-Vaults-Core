// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {BaseVaultsRegistry, EnumerableSet} from "./BaseVaultsRegistry.sol";

/**
 * @title VaultsRegistry
 * @notice Registry contract that stores information about allowed facets and their selectors
 */
contract VaultsRegistry is BaseVaultsRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidFee();
    error SelectorDidntExist(bytes4);
    error ArrayLengthMismatch();

    struct SelectorInfo {
        bool allowed;
        bytes mask;
    }

    /// @dev Mapping of facet address => is allowed
    mapping(address => bool) private _allowedFacets;
    mapping(address => mapping(bytes4 => SelectorInfo)) private _selectorInfo;

    /// @dev Mapping of bridge address => is allowed
    mapping(address => bool) private _bridgeAllowed;
    /// @dev Mapping of cross chain accounting manager address => is allowed
    mapping(address => bool) private _isCrossChainAccountingManager;

    /// @dev Cross chain accounting manager
    address public defaultCrossChainAccountingManager;

    uint96 private constant MAX_PROTOCOL_FEE = 5000; // 50%

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isPermissionless() external pure override returns (bool) {
        return false;
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function addFacet(address facet, bytes4[] calldata selectors) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (facet == address(0)) revert ZeroAddress();

        if (!_allowedFacets[facet]) {
            _allowedFacets[facet] = true;
            _facetsList.add(facet);
        }

        for (uint256 i = 0; i < selectors.length;) {
            bytes4 selector = selectors[i];
            if (selectorToFacet[selector] != address(0)) {
                revert SelectorAlreadyExists(selectorToFacet[selector], selector);
            }

            selectorToFacet[selector] = facet;
            facetSelectors[facet].push(selector);

            unchecked {
                ++i;
            }
        }

        emit FacetAdded(facet, selectors);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function editFacet(address facet, bytes4[] calldata selectors, bool[] calldata addOrRemove)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (facet == address(0)) revert ZeroAddress();
        if (!_allowedFacets[facet]) revert FacetNotAllowed(facet);
        if (selectors.length != addOrRemove.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < selectors.length;) {
            bytes4 selector = selectors[i];
            if (addOrRemove[i]) {
                if (selectorToFacet[selector] != address(0)) {
                    revert SelectorAlreadyExists(selectorToFacet[selector], selector);
                }

                selectorToFacet[selector] = facet;
                facetSelectors[facet].push(selector);
            } else {
                if (selectorToFacet[selector] == address(0)) {
                    revert SelectorDidntExist(selector);
                }
                selectorToFacet[selector] = address(0);

                bytes4[] storage _facetSelectorsArray = facetSelectors[facet];
                for (uint256 j = 0; j < _facetSelectorsArray.length;) {
                    if (_facetSelectorsArray[j] == selector) {
                        _facetSelectorsArray[j] = _facetSelectorsArray[_facetSelectorsArray.length - 1];
                        _facetSelectorsArray.pop();
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }
        if (facetSelectors[facet].length == 0) {
            _allowedFacets[facet] = false;
            _facetsList.remove(facet);
        }

        emit FacetEdited(facet, selectors, addOrRemove);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function removeFacet(address facet) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_allowedFacets[facet]) revert FacetNotAllowed(facet);

        // Remove from allowed facets
        _allowedFacets[facet] = false;

        // Remove from facets list
        _facetsList.remove(facet);

        // Remove all selectors
        bytes4[] memory selectors = facetSelectors[facet];
        for (uint256 i = 0; i < selectors.length;) {
            delete selectorToFacet[selectors[i]];
            unchecked {
                ++i;
            }
        }
        delete facetSelectors[facet];

        emit FacetRemoved(facet);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function setProtocolFeeInfo(address vault, address recipient, uint96 fee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (fee > MAX_PROTOCOL_FEE) revert InvalidFee();

        _protocolFeeInfo[vault] = ProtocolFeeInfo({recipient: recipient, fee: fee});

        emit ProtocolFeeInfoUpdated(vault, recipient, fee);
    }

    function setSelectorAndMask(address vault, bytes4 selector, bool allowed, bytes memory mask)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _selectorInfo[vault][selector] = SelectorInfo({allowed: allowed, mask: mask});
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function protocolFeeInfo(address vault) external view override returns (address, uint96) {
        return (_protocolFeeInfo[vault].recipient, _protocolFeeInfo[vault].fee);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function addToWhitelist(address protocol) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setWhitelisted(protocol, true);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function removeFromWhitelist(address protocol) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setWhitelisted(protocol, false);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isWhitelisted(address protocol) external view override returns (bool) {
        return _isWhitelisted(protocol);
    }

    function selectorInfo(address vault, bytes4 selector) external view returns (bool, bytes memory) {
        return (_selectorInfo[vault][selector].allowed, _selectorInfo[vault][selector].mask);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function setBridge(address bridge, bool allowed) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _bridgeAllowed[bridge] = allowed;
        emit BridgeUpdated(bridge, allowed);
    }

    function setIsCrossChainAccountingManager(address manager, bool isManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _isCrossChainAccountingManager[manager] = isManager;

        emit CrossChainAccountingManagerSet(manager, isManager);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function setDefaultCrossChainAccountingManager(address manager) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultCrossChainAccountingManager = manager;

        emit DefaultCrossChainAccountingManagerSet(manager);
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isBridgeAllowed(address bridge) external view virtual returns (bool) {
        return _bridgeAllowed[bridge];
    }

    /**
     * @inheritdoc IMoreVaultsRegistry
     */
    function isCrossChainAccountingManager(address manager) external view returns (bool) {
        return _isCrossChainAccountingManager[manager];
    }

    /**
     * @notice Internal function to check if facet is allowed
     * @param facet Address to check
     * @return bool True if facet is allowed
     */
    function _isFacetAllowed(address facet) internal view override returns (bool) {
        return _allowedFacets[facet];
    }
}
