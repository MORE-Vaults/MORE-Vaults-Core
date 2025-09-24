// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MoreVaultsDiamond} from "../MoreVaultsDiamond.sol";
import {IDiamondCut} from "../interfaces/facets/IDiamondCut.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {ILayerZeroReceiver} from "../interfaces/LayerZero/ILayerZeroReceiver.sol";
import {ILayerZeroEndpoint} from "../interfaces/LayerZero/ILayerZeroEndpoint.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {IConfigurationFacet} from "../interfaces/facets/IConfigurationFacet.sol";
import {IAccessControlFacet} from "../interfaces/facets/IAccessControlFacet.sol";

/**
 * @title VaultsFactory
 * @notice Factory contract for deploying new vault instances
 */
contract VaultsFactory is
    IVaultsFactory,
    AccessControlUpgradeable,
    ILayerZeroReceiver
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Thrown when non-vault tries to link or unlink facet.
    error NotAuthorizedToLinkFacets(address);
    /// @dev Thrown when non-vault tries to request cross-chain link
    error NotAVault(address);
    /// @dev Thrown when non-owner of vault tries to request cross-chain link
    error NotAnOwnerOfVault(address);
    /// @dev Thrown when max finalization time is not exceeded
    error MaxFinalizationTimeNotExceeded();
    /// @dev Thrown when non-layer zero endpoint tries to receive message
    error NotLayerZeroEndpoint(address);
    /// @dev Thrown when factory is untrusted
    error UntrustedFactory(uint16, bytes);
    /// @dev Thrown when hub cannot initiate cross-chain link
    error HubCannotInitiateLink();
    /// @dev Thrown when hub vault is not found
    error HubVaultNotFound(address);
    /// @dev Thrown when facet is restricted
    error RestrictedFacet(address);
    /// @dev Thrown when vault is already linked
    error VaultAlreadyLinked(address);

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

    /// @dev Array of times of deployment of vaults
    mapping(address => uint96) public deployedAt;

    /// @dev Address of the wrapped native token
    address public wrappedNative;

    /// @dev Address of the layer zero endpoint
    address public layerZeroEndpoint;

    /// @dev Maximum finalization time of block for a chain
    uint96 public maxFinalizationTime;

    /// @dev Mapping chain id => trusted factory address
    mapping(uint16 => address) public trustedFactory;

    /// @dev Mapping chain id => spoke vault address => hub vault info
    mapping(uint16 => mapping(address => VaultInfo)) public _spokeToHub;

    /// @dev Mapping chain id => hub vault address => spoke vault infos
    mapping(uint16 => mapping(address => VaultInfo[])) public _hubToSpokes;

    /// @dev Address set of restricted facets
    EnumerableSet.AddressSet private _restrictedFacets;

    /// @dev Mapping facet address => vaults using this facet array
    mapping(address => EnumerableSet.AddressSet) private _linkedVaults;

    function initialize(
        address _owner,
        address _registry,
        address _diamondCutFacet,
        address _accessControlFacet,
        address _wrappedNative,
        address _layerZeroEndpoint,
        uint96 _maxFinalizationTime
    ) external initializer {
        if (
            _owner == address(0) ||
            _registry == address(0) ||
            _diamondCutFacet == address(0) ||
            _accessControlFacet == address(0) ||
            _wrappedNative == address(0) ||
            _layerZeroEndpoint == address(0)
        ) revert ZeroAddress();
        _setDiamondCutFacet(_diamondCutFacet);
        _setAccessControlFacet(_accessControlFacet);
        _setLayerZeroEndpoint(_layerZeroEndpoint);
        _setMaxFinalizationTime(_maxFinalizationTime);
        wrappedNative = _wrappedNative;
        registry = IMoreVaultsRegistry(_registry);

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
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
     * @notice Set the layer zero endpoint address
     * @param _layerZeroEndpoint The address of the layer zero endpoint
     */
    function setLayerZeroEndpoint(
        address _layerZeroEndpoint
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLayerZeroEndpoint(_layerZeroEndpoint);
    }

    /**
     * @notice Set the maximum finalization time of block for a chain
     * @param _maxFinalizationTime The maximum finalization time of block for a chain
     */
    function setMaxFinalizationTime(
        uint96 _maxFinalizationTime
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMaxFinalizationTime(_maxFinalizationTime);
    }

    function setTrustedFactory(
        uint16 _chainId,
        address _factory
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTrustedFactory(_chainId, _factory);
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
        bytes memory accessControlFacetInitData,
        bool isHub,
        bytes32 salt
    ) external returns (address vault) {
        // Deploy new MoreVaultsDiamond (vault) with CREATE3
        vault = CREATE3.deployDeterministic(
            0,
            abi.encodePacked(
                type(MoreVaultsDiamond).creationCode,
                abi.encode(
                    diamondCutFacet,
                    accessControlFacet,
                    address(registry),
                    wrappedNative,
                    address(this),
                    isHub,
                    facets,
                    accessControlFacetInitData
                )
            ),
            salt
        );

        isFactoryVault[vault] = true;
        deployedVaults.push(vault);
        deployedAt[vault] = uint96(block.timestamp);
        _linkedVaults[diamondCutFacet].add(vault);
        _linkedVaults[accessControlFacet].add(vault);
        _checkRestrictedFacet(diamondCutFacet);
        _checkRestrictedFacet(accessControlFacet);
        for (uint256 i = 0; i < facets.length; ) {
            _checkRestrictedFacet(facets[i].facetAddress);
            _linkedVaults[facets[i].facetAddress].add(vault);
            unchecked {
                ++i;
            }
        }
        emit VaultDeployed(vault, address(registry), wrappedNative, facets);
    }

    /**
     * @notice Predict the address of a vault deployed with given salt (CREATE3).
     */
    function predictVaultAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt, address(this));
    }

    /**
     * @notice Request a cross-chain link
     * @param _dstChainId The destination chain ID
     * @param _dstFactory The destination factory address
     * @param _vaultToLink The local vault address
     * @param _originChainId Optional. The origin chain ID in case of hub requests link existing spoke to another spoke
     */
    function requestCrossChainLink(
        uint16 _dstChainId,
        bytes calldata _dstFactory,
        address _vaultToLink,
        address _localVault,
        uint16 _originChainId
    ) external payable {
        if (!isFactoryVault[_vaultToLink]) revert NotAVault(_vaultToLink);
        if (IAccessControlFacet(_vaultToLink).owner() != msg.sender)
            revert NotAnOwnerOfVault(msg.sender);
        if (block.timestamp - deployedAt[_vaultToLink] < maxFinalizationTime)
            revert MaxFinalizationTimeNotExceeded();
        if (trustedFactory[_dstChainId] != address(bytes20(_dstFactory)))
            revert UntrustedFactory(_dstChainId, _dstFactory);

        bool isHub = IConfigurationFacet(_localVault).isHub();

        uint16 chainId = isHub ? _originChainId : uint16(block.chainid);

        bytes memory payload = abi.encode(
            msg.sender,
            _vaultToLink,
            _localVault,
            chainId,
            isHub
        );

        ILayerZeroEndpoint.MessagingParams memory params = ILayerZeroEndpoint
            .MessagingParams(
                _dstChainId,
                bytes32(bytes20(_dstFactory)),
                payload,
                bytes(""),
                false
            );
        ILayerZeroEndpoint(layerZeroEndpoint).send{value: msg.value}(
            params,
            payable(msg.sender)
        );

        if (!isHub) {
            if (_spokeToHub[_dstChainId][_vaultToLink].vault != address(0))
                revert VaultAlreadyLinked(_vaultToLink);
            VaultInfo memory hubVaultInfo = _spokeToHub[uint16(block.chainid)][
                _localVault
            ];
            _spokeToHub[_dstChainId][_vaultToLink] = VaultInfo({
                chainId: hubVaultInfo.chainId,
                vault: hubVaultInfo.vault
            });
            _hubToSpokes[hubVaultInfo.chainId][hubVaultInfo.vault].push(
                VaultInfo({chainId: _dstChainId, vault: _vaultToLink})
            );

            emit CrossChainLinkRequested(
                _dstChainId,
                msg.sender,
                _vaultToLink,
                _localVault
            );
        } else if (isHub) {
            if (_spokeToHub[chainId][_vaultToLink].vault == address(0))
                revert HubVaultNotFound(_vaultToLink);
            _spokeToHub[_dstChainId][_vaultToLink] = VaultInfo({
                chainId: uint16(block.chainid),
                vault: _localVault
            });
            _hubToSpokes[uint16(block.chainid)][_localVault].push(
                VaultInfo({chainId: _dstChainId, vault: _vaultToLink})
            );
        }
    }

    function lzReceive(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 /*_nonce*/,
        bytes calldata _payload
    ) external {
        if (msg.sender != address(layerZeroEndpoint))
            revert NotLayerZeroEndpoint(msg.sender);
        // check source equals trusted remote
        if (trustedFactory[_srcChainId] != address(bytes20(_srcAddress)))
            revert UntrustedFactory(_srcChainId, _srcAddress);

        (
            address initiator,
            address vaultToLink, // vault on src chain
            address localVault, // vault on dst chain
            uint16 originChainId,
            bool isSenderHub
        ) = abi.decode(_payload, (address, address, address, uint16, bool));

        // Ensure dstVault is actually deployed by this factory
        if (!isFactoryVault[localVault]) revert NotAVault(localVault);

        // if sender is hub, we need to link the spoke to the spoke
        if (isSenderHub) {
            VaultInfo memory hubVaultInfo = _spokeToHub[uint16(block.chainid)][
                localVault
            ];
            if (hubVaultInfo.vault == address(0))
                revert HubVaultNotFound(localVault);

            _spokeToHub[originChainId][vaultToLink] = VaultInfo({
                chainId: hubVaultInfo.chainId,
                vault: hubVaultInfo.vault
            });
            _hubToSpokes[hubVaultInfo.chainId][hubVaultInfo.vault].push(
                VaultInfo({chainId: originChainId, vault: vaultToLink})
            );
            emit CrossChainLinked(originChainId, vaultToLink, localVault);
        } else {
            // if sender is spoke, we need to link the spoke to the hub
            _hubToSpokes[uint16(block.chainid)][localVault].push(
                VaultInfo({chainId: originChainId, vault: vaultToLink})
            );
            _spokeToHub[originChainId][vaultToLink] = VaultInfo({
                chainId: uint16(block.chainid),
                vault: localVault
            });
            emit CrossChainLinked(originChainId, vaultToLink, localVault);
        }
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

    /**
     * @inheritdoc IVaultsFactory
     */
    function hubToSpokes(
        uint16 _chainId,
        address _hubVault
    ) external view returns (VaultInfo[] memory) {
        return _hubToSpokes[_chainId][_hubVault];
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function spokeToHub(
        uint16 _chainId,
        address _spokeVault
    ) external view returns (VaultInfo memory) {
        return _spokeToHub[_chainId][_spokeVault];
    }

    function _setDiamondCutFacet(address _diamondCutFacet) internal {
        if (_diamondCutFacet == address(0)) revert ZeroAddress();
        diamondCutFacet = _diamondCutFacet;
        emit DiamondCutFacetUpdated(diamondCutFacet);
    }

    function _setAccessControlFacet(address _accessControlFacet) internal {
        if (_accessControlFacet == address(0)) revert ZeroAddress();
        accessControlFacet = _accessControlFacet;
        emit AccessControlFacetUpdated(accessControlFacet);
    }

    function _setLayerZeroEndpoint(address _layerZeroEndpoint) internal {
        if (_layerZeroEndpoint == address(0)) revert ZeroAddress();
        layerZeroEndpoint = _layerZeroEndpoint;
        emit LayerZeroEndpointUpdated(layerZeroEndpoint);
    }

    function _setMaxFinalizationTime(uint96 _maxFinalizationTime) internal {
        maxFinalizationTime = _maxFinalizationTime;
        emit MaxFinalizationTimeUpdated(_maxFinalizationTime);
    }

    function _setTrustedFactory(uint16 _chainId, address _factory) internal {
        trustedFactory[_chainId] = _factory;
        emit TrustedFactoryUpdated(_chainId, _factory);
    }

    function _setFacetRestricted(address _facet, bool _isRestricted) private {
        if (_isRestricted) _restrictedFacets.add(_facet);
        else _restrictedFacets.remove(_facet);

        emit SetFacetRestricted(_facet, _isRestricted);
    }

    function _checkRestrictedFacet(address _facet) internal view {
        if (_restrictedFacets.contains(_facet)) revert RestrictedFacet(_facet);
    }
}
