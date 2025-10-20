// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IConfigurationFacet} from "../interfaces/facets/IConfigurationFacet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ConfigurationFacet is BaseFacetInitializer, IConfigurationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
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
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IConfigurationFacet).interfaceId] = true;
        ds.maxSlippagePercent = maxSlippagePercent;
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IConfigurationFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setMaxSlippagePercent(uint256 _newPercent) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (_newPercent > 2000) revert SlippageTooHigh();
        ds.maxSlippagePercent = _newPercent;

        emit MaxSlippagePercentSet(_newPercent);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setGasLimitForAccounting(
        uint48 _availableTokenAccountingGas,
        uint48 _heldTokenAccountingGas,
        uint48 _facetAccountingGas,
        uint48 _newLimit
    ) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.GasLimit storage gl = MoreVaultsLib.moreVaultsStorage().gasLimit;
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
    function setDepositWhitelist(address[] calldata depositors, uint256[] calldata underlyingAssetCaps) external {
        if (depositors.length != underlyingAssetCaps.length) {
            revert ArraysLengthsMismatch();
        }
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib._setDepositWhitelist(depositors, underlyingAssetCaps);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function enableDepositWhitelist() external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib._setWhitelistFlag(true);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function disableDepositWhitelist() external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib._setWhitelistFlag(false);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setTimeLockPeriod(uint256 period) external {
        AccessControlLib.validateDiamond(msg.sender);
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

        for (uint256 i = 0; i < assets.length;) {
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
        AccessControlLib.validateDiamond(msg.sender);
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
    function setWithdrawalTimelock(uint64 _duration) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        ds.witdrawTimelock = _duration;
        emit WithdrawalTimelockSet(_duration);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setWithdrawalFee(uint96 _fee) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (_fee > MoreVaultsLib.MAX_FEE) revert FeeIsTooHigh();
        ds.withdrawalFee = _fee;
        emit WithdrawalFeeSet(_fee);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function updateWithdrawalQueueStatus(bool _status) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.isWithdrawalQueueEnabled = _status;
        emit WithdrawalQueueStatusSet(_status);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function setCrossChainAccountingManager(address manager) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        if (!IMoreVaultsRegistry(acs.moreVaultsRegistry).isCrossChainAccountingManager(manager)) {
            revert InvalidManager();
        }
        ds.crossChainAccountingManager = manager;

        emit CrossChainAccountingManagerSet(manager);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getWithdrawalFee() external view returns (uint96) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.withdrawalFee;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getWithdrawalQueueStatus() external view returns (bool) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.isWithdrawalQueueEnabled;
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
    function getDepositWhitelist(address depositor) external view returns (uint256) {
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

    /**
     * @inheritdoc IConfigurationFacet
     */
    function lockedTokensAmountOfAsset(address asset) external view returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.lockedTokens[asset];
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getStakingAddresses(bytes32 stakingFacetId) external view returns (address[] memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return EnumerableSet.values(ds.stakingAddresses[stakingFacetId]);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function tokensHeld(bytes32 tokenId) external view returns (address[] memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return EnumerableSet.values(ds.tokensHeld[tokenId]);
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function getWithdrawalTimelock() external view returns (uint64) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.witdrawTimelock;
    }

    /**
     * @inheritdoc IConfigurationFacet
     */
    function recoverAssets(address asset, address receiver, uint256 amount) external {
        // Prevent calls during multicall
        MoreVaultsLib.validateNotMulticall();

        // Only guardian can recover assets
        AccessControlLib.validateGuardian(msg.sender);

        // Validate inputs
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Cannot recover assets that are marked as available (vault is managing them)
        if (ds.isAssetAvailable[asset]) revert AssetIsAvailable();

        // Transfer the assets to receiver
        IERC20(asset).safeTransfer(receiver, amount);

        emit AssetsRecovered(asset, receiver, amount);
    }
}
