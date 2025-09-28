// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MoreVaultsDiamond} from "../MoreVaultsDiamond.sol";
import {IDiamondCut} from "../interfaces/facets/IDiamondCut.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {
    OAppUpgradeable,
    Origin,
    MessagingFee
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OAppOptionsType3Upgradeable} from
    "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {IConfigurationFacet} from "../interfaces/facets/IConfigurationFacet.sol";
import {IAccessControlFacet} from "../interfaces/facets/IAccessControlFacet.sol";

/**
 * @title VaultsFactory
 * @notice Factory contract for deploying new vault instances
 */
contract VaultsFactory is IVaultsFactory, OAppUpgradeable, OAppOptionsType3Upgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @dev Thrown when non-vault tries to link or unlink facet.
    error NotAuthorizedToLinkFacets(address);
    /// @dev Thrown when non-vault tries to request cross-chain link
    error NotAVault(address);
    /// @dev Thrown when non-owner of vault tries to request cross-chain link
    error NotAnOwnerOfVault(address);
    /// @dev Thrown when max finalization time is not exceeded
    error MaxFinalizationTimeNotExceeded();
    /// @dev Thrown when hub cannot initiate cross-chain link
    error HubCannotInitiateLink();
    /// @dev Thrown when facet is restricted
    error RestrictedFacet(address);
    /// @dev Thrown when hub owner and spoke owner do not match
    error OwnersMismatch(address hubOwner, address spokeOwner);
    /// @dev Thrown on unknown message type
    error UnknownMsgType();

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

    /// @dev Local LayerZero endpoint id (EID) for this chain
    uint32 public localEid;

    /// @dev Maximum finalization time of block for a chain
    uint96 public maxFinalizationTime;

    /// @dev Mapping spoke eid => spoke vault => packed hub (eid|address)
    mapping(uint32 => mapping(address => bytes32)) private _spokeToHub;

    /// @dev Mapping hub eid => hub vault => set of spokes (encoded as bytes32)
    mapping(uint32 => mapping(address => EnumerableSet.Bytes32Set)) private _hubToSpokesSet;

    /// @dev Address set of restricted facets
    EnumerableSet.AddressSet private _restrictedFacets;

    /// @dev Mapping facet address => vaults using this facet array
    mapping(address => EnumerableSet.AddressSet) private _linkedVaults;

    // ===== Cross-chain messaging (LayerZero v2, EIDs) =====
    uint16 private constant MSG_TYPE_REGISTER_SPOKE = 1;
    uint16 private constant MSG_TYPE_SPOKE_ADDED = 2;
    uint16 private constant MSG_TYPE_BOOTSTRAP = 3;

    uint256 private _multiSendFee; // used to support multi-send in a single tx

    constructor(address _endpoint) OAppUpgradeable(_endpoint) {}

    function initialize(
        address _owner,
        address _registry,
        address _diamondCutFacet,
        address _accessControlFacet,
        address _wrappedNative,
        uint32 _localEid,
        uint96 _maxFinalizationTime
    ) external initializer {
        if (
            _owner == address(0) || _registry == address(0) || _diamondCutFacet == address(0)
                || _accessControlFacet == address(0) || _wrappedNative == address(0) || _localEid == 0
        ) revert ZeroAddress();
        _setDiamondCutFacet(_diamondCutFacet);
        _setAccessControlFacet(_accessControlFacet);
        _setMaxFinalizationTime(_maxFinalizationTime);
        wrappedNative = _wrappedNative;
        registry = IMoreVaultsRegistry(_registry);
        localEid = _localEid;

        __OApp_init(_owner);
        __Ownable_init(_owner);
    }

    /**
     * @notice Set the diamond cut facet address, that manages addition and removal of facets
     * @param _diamondCutFacet The address of the diamond cut facet
     */
    function setDiamondCutFacet(address _diamondCutFacet) external onlyOwner {
        _setDiamondCutFacet(_diamondCutFacet);
    }

    /**
     * @notice Set the access control facet address, that manages ownership and roles of the vault
     * @param _accessControlFacet The address of the access control facet
     */
    function setAccessControlFacet(address _accessControlFacet) external onlyOwner {
        _setAccessControlFacet(_accessControlFacet);
    }

    /**
     * @notice Set the maximum finalization time of block for a chain
     * @param _maxFinalizationTime The maximum finalization time of block for a chain
     */
    function setMaxFinalizationTime(uint96 _maxFinalizationTime) external onlyOwner {
        _setMaxFinalizationTime(_maxFinalizationTime);
    }

    /// @notice Set trusted factory peer for LayerZero by endpoint id (EID)
    function setTrustedFactory(uint32 _eid, bytes32 _peer) external onlyOwner {
        setPeer(_eid, _peer);
    }

    /**
     * @notice pauses all vaults using this facet
     * @param _facet address of the facet
     */
    function pauseFacet(address _facet) external onlyOwner {
        address[] memory vaults = _linkedVaults[_facet].values();
        _setFacetRestricted(_facet, true);
        for (uint256 i = 0; i < vaults.length;) {
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
    function setFacetRestricted(address _facet, bool _isRestricted) external onlyOwner {
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
        for (uint256 i = 0; i < facets.length;) {
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

    function _encodeSpokeKey(uint32 eid, address vault) internal pure returns (bytes32) {
        return bytes32((uint256(eid) << 160) | uint160(vault));
    }

    function _decodeSpokeKey(bytes32 key) internal pure returns (uint32 eid, address vault) {
        vault = address(uint160(uint256(key)));
        eid = uint32(uint256(key) >> 160);
    }

    /// @notice Spoke requests registration on Hub. EIDs must be used (not EVM chainId)
    /// @param _hubEid LayerZero endpoint id of hub chain
    /// @param _hubVault Address of hub vault on hub chain (local to hub)
    /// @param _spokeVault Address of spoke vault on current chain
    /// @param _options LZ options (type3). Can be empty; enforced options may apply
    function requestRegisterSpoke(uint32 _hubEid, address _hubVault, address _spokeVault, bytes calldata _options)
        external
        payable
    {
        if (!isFactoryVault[_spokeVault]) revert NotAVault(_spokeVault);
        if (IAccessControlFacet(_spokeVault).owner() != msg.sender) {
            revert NotAnOwnerOfVault(msg.sender);
        }
        if (block.timestamp - deployedAt[_spokeVault] < maxFinalizationTime) {
            revert MaxFinalizationTimeNotExceeded();
        }

        address spokeOwner = IAccessControlFacet(_spokeVault).owner();
        bytes memory payload = abi.encode(MSG_TYPE_REGISTER_SPOKE, _spokeVault, _hubVault, spokeOwner);

        bytes memory options = combineOptions(_hubEid, MSG_TYPE_REGISTER_SPOKE, _options);
        MessagingFee memory fee = _quote(_hubEid, payload, options, false);
        // exact native payment for single message
        require(msg.value == fee.nativeFee, "LZ: invalid fee");
        _lzSend(_hubEid, payload, options, fee, msg.sender);
        emit CrossChainLinkRequested(_hubEid, msg.sender, _spokeVault, _hubVault);
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /* _guid */
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        // OAppReceiver already validated endpoint and peer
        (uint16 msgType, bytes memory rest) = abi.decode(_message, (uint16, bytes));

        if (msgType == MSG_TYPE_REGISTER_SPOKE) {
            (address spokeVault, address hubVault, address spokeOwner) = abi.decode(rest, (address, address, address));

            // Ensure dst hub vault is actually deployed by this factory and is hub
            if (!isFactoryVault[hubVault]) revert NotAVault(hubVault);
            if (!IConfigurationFacet(hubVault).isHub()) {
                revert HubCannotInitiateLink();
            }

            // owners must match: spoke owner (from trusted peer) and local hub owner
            address hubOwner = IAccessControlFacet(hubVault).owner();
            if (hubOwner != spokeOwner) {
                revert OwnersMismatch(hubOwner, spokeOwner);
            }

            uint32 hubEid = localEid;
            uint32 spokeEid = _origin.srcEid;

            // Idempotent: write packed hub if absent
            if (_spokeToHub[spokeEid][spokeVault] == bytes32(0)) {
                _spokeToHub[spokeEid][spokeVault] = _encodeSpokeKey(hubEid, hubVault);
            }

            // Append to hub->spokes set (idempotent)
            _hubToSpokesSet[hubEid][hubVault].add(_encodeSpokeKey(spokeEid, spokeVault));

            emit CrossChainLinked(spokeEid, spokeVault, hubVault);
        } else if (msgType == MSG_TYPE_SPOKE_ADDED) {
            // optional: update local caches on spokes when hub broadcasts new peers
            (uint32 hubEid, address hubVault, uint32 newSpokeEid, address newSpokeVault) =
                abi.decode(rest, (uint32, address, uint32, address));
            // track that this spoke knows about new peer under its hub
            // append if not present
            _hubToSpokesSet[hubEid][hubVault].add(_encodeSpokeKey(newSpokeEid, newSpokeVault));
        } else if (msgType == MSG_TYPE_BOOTSTRAP) {
            // Merge-only bootstrap: add missing spokes; do not remove existing ones
            (uint32 hubEid, address hubVault, bytes32[] memory others) = abi.decode(rest, (uint32, address, bytes32[]));
            for (uint256 i = 0; i < others.length; i++) {
                _hubToSpokesSet[hubEid][hubVault].add(others[i]);
            }
        } else {
            revert UnknownMsgType();
        }
    }

    /// @notice Hub: send BOOTSTRAP snapshot to a single spoke (list of all known spokes)
    function hubSendBootstrap(uint32 _dstEid, address _hubVault, bytes calldata _options) external payable onlyOwner {
        if (!isFactoryVault[_hubVault]) revert NotAVault(_hubVault);
        if (!IConfigurationFacet(_hubVault).isHub()) {
            revert HubCannotInitiateLink();
        }

        // build snapshot as packed keys
        bytes32[] memory spokes = _hubToSpokesSet[localEid][_hubVault].values();
        bytes memory payload = abi.encode(MSG_TYPE_BOOTSTRAP, localEid, _hubVault, spokes);
        bytes memory options = combineOptions(_dstEid, MSG_TYPE_BOOTSTRAP, _options);
        MessagingFee memory fee = _quote(_dstEid, payload, options, false);
        require(msg.value == fee.nativeFee, "LZ: invalid fee");
        _lzSend(_dstEid, payload, options, fee, msg.sender);
    }

    /// @notice Hub: broadcast SPOKE_ADDED to the specified destination EIDs
    function hubBroadcastSpokeAdded(
        address _hubVault,
        uint32 _newSpokeEid,
        address _newSpokeVault,
        uint32[] calldata _dstEids,
        bytes calldata _options
    ) external payable onlyOwner {
        if (!isFactoryVault[_hubVault]) revert NotAVault(_hubVault);
        if (!IConfigurationFacet(_hubVault).isHub()) {
            revert HubCannotInitiateLink();
        }

        bytes memory payload = abi.encode(MSG_TYPE_SPOKE_ADDED, localEid, _hubVault, _newSpokeEid, _newSpokeVault);

        _multiSendFee = msg.value;
        for (uint256 i = 0; i < _dstEids.length; i++) {
            bytes memory options = combineOptions(_dstEids[i], MSG_TYPE_SPOKE_ADDED, _options);
            MessagingFee memory fee = _quote(_dstEids[i], payload, options, false);
            // On last iteration flush remaining budget so Endpoint refunds remainder to msg.sender
            if (i + 1 == _dstEids.length) {
                // Make _payNative send all remaining budget; it will be refunded by Endpoint
                fee.nativeFee = _multiSendFee;
            }
            _lzSend(_dstEids[i], payload, options, fee, msg.sender);
        }
        _multiSendFee = 0;
    }

    // Support multiple _lzSend calls per tx by allocating from a shared native fee budget.
    function _payNative(uint256 _nativeFee) internal override returns (uint256) {
        // Check if it is multi send or not.
        if (_multiSendFee == 0) {
            if (msg.value != _nativeFee) revert NotEnoughNative(msg.value);
            return _nativeFee;
        }
        if (_multiSendFee < _nativeFee) revert NotEnoughNative(_multiSendFee);
        unchecked {
            _multiSendFee -= _nativeFee;
        }
        return _nativeFee;
    }

    /**
     * @notice Get all deployed vaults
     * @return Array of vault addresses
     */
    function getDeployedVaults() external view override returns (address[] memory) {
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
    function getLinkedVaults(address _facet) external view returns (address[] memory vaults) {
        vaults = _linkedVaults[_facet].values();
    }

    /**
     * @notice Returns facet addresses that are restricted
     * @return facets addresses of the restricted facets
     */
    function getRestrictedFacets() external view returns (address[] memory facets) {
        facets = _restrictedFacets.values();
    }

    /**
     * @notice Returns bool flag if vault linked to the facet
     * @param _facet address of the facet
     * @param _vault address of the vault
     */
    function isVaultLinked(address _facet, address _vault) external view returns (bool) {
        return _linkedVaults[_facet].contains(_vault);
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function hubToSpokes(uint32 _chainId, address _hubVault)
        external
        view
        returns (uint32[] memory eids, address[] memory vaults)
    {
        bytes32[] memory values = _hubToSpokesSet[_chainId][_hubVault].values();
        eids = new uint32[](values.length);
        vaults = new address[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            (uint32 eid_, address vault_) = _decodeSpokeKey(values[i]);
            eids[i] = eid_;
            vaults[i] = vault_;
        }
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function isSpokeOfHub(uint32 _hubEid, address _hubVault, uint32 _spokeEid, address _spokeVault)
        external
        view
        returns (bool)
    {
        return _hubToSpokesSet[_hubEid][_hubVault].contains(_encodeSpokeKey(_spokeEid, _spokeVault));
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function isCrossChainVault(uint32 _chainId, address _vault) external view returns (bool) {
        return _hubToSpokesSet[_chainId][_vault].length() > 0;
    }

    /**
     * @inheritdoc IVaultsFactory
     */
    function spokeToHub(uint32 _chainId, address _spokeVault) external view returns (uint32 eid, address vault) {
        bytes32 value = _spokeToHub[_chainId][_spokeVault];
        if (value == bytes32(0)) return (0, address(0));
        (eid, vault) = _decodeSpokeKey(value);
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

    function _setMaxFinalizationTime(uint96 _maxFinalizationTime) internal {
        maxFinalizationTime = _maxFinalizationTime;
        emit MaxFinalizationTimeUpdated(_maxFinalizationTime);
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
