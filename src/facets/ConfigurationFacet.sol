// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IConfigurationFacet} from "../interfaces/facets/IConfigurationFacet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

contract ConfigurationFacet is BaseFacetInitializer, IConfigurationFacet {
    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.ConfigurationFacet");
    }

    function facetName() external pure returns (string memory) {
        return "ConfigurationFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata data) external initializerFacet {
        uint256 maxSlippagePercent = abi.decode(data, (uint256));
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IConfigurationFacet).interfaceId] = true;
        ds.maxSlippagePercent = maxSlippagePercent;
    }

    function onFacetRemoval(address, bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IConfigurationFacet).interfaceId] = false;
    }

    function setMaxSlippagePercent(uint256 _newPercent) external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.maxSlippagePercent = _newPercent;
    }

    function setGasLimitForAccounting(
        uint48 _availableTokenAccountingGas,
        uint48 _heldTokenAccountingGas,
        uint48 _facetAccountingGas,
        uint48 _newLimit
    ) external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib.GasLimit storage gl = MoreVaultsLib
            .moreVaultsStorage()
            .gasLimit;
        gl.availableTokenAccountingGas = _availableTokenAccountingGas;
        gl.heldTokenAccountingGas = _heldTokenAccountingGas;
        gl.facetAccountingGas = _facetAccountingGas;
        gl.value = _newLimit;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setFeeRecipient(address recipient) external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib._setFeeRecipient(recipient);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setDepositCapacity(uint256 capacity) external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._setDepositCapacity(capacity);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setDepositWhitelist(
        address[] calldata depositors,
        uint256[] calldata underlyingAssetCaps
    ) external {
        if (depositors.length != underlyingAssetCaps.length) {
            revert ArraysLengthsMismatch();
        }
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._setDepositWhitelist(depositors, underlyingAssetCaps);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function enableDepositWhitelist() external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._setWhitelistFlag(true);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function disableDepositWhitelist() external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._setWhitelistFlag(false);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setTimeLockPeriod(uint256 period) external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib._setTimeLockPeriod(period);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function addAvailableAsset(address asset) external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._addAvailableAsset(asset);
        MoreVaultsLib.checkGasLimitOverflow();
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function addAvailableAssets(address[] calldata assets) external {
        AccessControlLib.validateCurator(msg.sender);

        for (uint256 i = 0; i < assets.length; ) {
            MoreVaultsLib._addAvailableAsset(assets[i]);
            unchecked {
                ++i;
            }
        }
        MoreVaultsLib.checkGasLimitOverflow();
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function enableAssetToDeposit(address asset) external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._enableAssetToDeposit(asset);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function disableAssetToDeposit(address asset) external {
        AccessControlLib.validateCurator(msg.sender);
        MoreVaultsLib._disableAssetToDeposit(asset);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function isAssetDepositable(address asset) external view returns (bool) {
        return MoreVaultsLib.moreVaultsStorage().isAssetDepositable[asset];
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function isAssetAvailable(address asset) external view returns (bool) {
        return MoreVaultsLib.moreVaultsStorage().isAssetAvailable[asset];
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getAvailableAssets() external view returns (address[] memory) {
        return MoreVaultsLib.moreVaultsStorage().availableAssets;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getDepositableAssets() external view returns (address[] memory) {
        return MoreVaultsLib.moreVaultsStorage().depositableAssets;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function fee() external view returns (uint96) {
        return MoreVaultsLib.moreVaultsStorage().fee;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function feeRecipient() external view returns (address) {
        return MoreVaultsLib.moreVaultsStorage().feeRecipient;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function depositCapacity() external view returns (uint256) {
        return MoreVaultsLib.moreVaultsStorage().depositCapacity;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function timeLockPeriod() external view returns (uint256) {
        return MoreVaultsLib.moreVaultsStorage().timeLockPeriod;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getDepositWhitelist(
        address depositor
    ) external view returns (uint256) {
        return MoreVaultsLib.moreVaultsStorage().depositWhitelist[depositor];
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function isDepositWhitelistEnabled() external view returns (bool) {
        return MoreVaultsLib.moreVaultsStorage().isWhitelistEnabled;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function isHub() external view returns (bool) {
        return MoreVaultsLib.moreVaultsStorage().isHub;
    }
}
