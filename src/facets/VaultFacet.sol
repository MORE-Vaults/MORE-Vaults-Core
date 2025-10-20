// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    MoreVaultsLib,
    BEFORE_ACCOUNTING_SELECTOR,
    BEFORE_ACCOUNTING_FAILED_ERROR,
    ACCOUNTING_FAILED_ERROR,
    BALANCE_OF_SELECTOR
} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ERC4626Upgradeable,
    SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract VaultFacet is ERC4626Upgradeable, PausableUpgradeable, IVaultFacet, BaseFacetInitializer {
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    error WithdrawSchedulerInvalidTimestamp(uint256 timestamp);
    error CantCoverWithdrawRequests(uint256, uint256);
    error InvalidSharesAmount();
    error InvalidAssetsAmount();
    error CantProcessWithdrawRequest();
    error VaultIsUsingRestrictedFacet(address);
    error WithdrawalQueueDisabled();
    error NotAHub();
    error InvalidActionType();
    error OnlyCrossChainAccountingManager();
    error SyncActionsDisabledInCrossChainVaults();
    error RequestWasntFulfilled();
    error RequestWithdrawDisabled();

    event WithdrawRequestCreated(address requester, uint256 sharesAmount, uint256 endsAt);
    event WithdrawRequestFulfilled(address requester, address receiver, uint256 sharesAmount, uint256 assetAmount);
    event WithdrawRequestDeleted(address requester);

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.MoreVaults");
    }

    function facetName() external pure returns (string memory) {
        return "VaultFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata data) external initializerFacet initializer {
        (
            string memory name,
            string memory symbol,
            address asset,
            address feeRecipient,
            uint96 fee,
            uint256 depositCapacity
        ) = abi.decode(data, (string, string, address, address, uint96, uint256));
        if (asset == address(0) || feeRecipient == address(0) || fee > MoreVaultsLib.FEE_BASIS_POINT) {
            revert InvalidParameters();
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Facet interfaces
        ds.supportedInterfaces[type(IERC20).interfaceId] = true; // ERC20 interface
        ds.supportedInterfaces[type(IERC4626).interfaceId] = true; // ERC4626 base interface
        ds.supportedInterfaces[type(IVaultFacet).interfaceId] = true; // VaultFacet (extended ERC4626)

        MoreVaultsLib._setFeeRecipient(feeRecipient);
        MoreVaultsLib._setFee(fee);
        MoreVaultsLib._setDepositCapacity(depositCapacity);
        __ERC4626_init(IERC20(asset));
        __ERC20_init(name, symbol);
        MoreVaultsLib._addAvailableAsset(asset);
        MoreVaultsLib._enableAssetToDeposit(asset);
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IVaultFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function paused() public view override(PausableUpgradeable, IVaultFacet) returns (bool) {
        return super.paused();
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function pause() external {
        if (
            AccessControlLib.vaultOwner() != msg.sender && AccessControlLib.vaultGuardian() != msg.sender
                && MoreVaultsLib.factoryAddress() != msg.sender
        ) {
            revert AccessControlLib.UnauthorizedAccess();
        }
        _pause();
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function unpause() external {
        AccessControlLib.validateGuardian(msg.sender);
        IVaultsFactory factory = IVaultsFactory(MoreVaultsLib.factoryAddress());
        address[] memory restrictedFacets = factory.getRestrictedFacets();
        for (uint256 i = 0; i < restrictedFacets.length;) {
            if (factory.isVaultLinked(restrictedFacets[i], address(this))) {
                revert VaultIsUsingRestrictedFacet(restrictedFacets[i]);
            }
            unchecked {
                ++i;
            }
        }

        _unpause();
    }

    function _beforeAccounting(address[] storage _baf) private {
        MoreVaultsLib._beforeAccounting(_baf);
    }

    function _accountAvailableAssets(
        address[] storage _assets,
        mapping(address => uint256) storage _lockedTokens,
        address _wrappedNative,
        bool _isNativeDeposit,
        uint256 _freePtr,
        bool _allowFailure
    ) private view returns (uint256 _totalAssets, bool success) {
        success = true;
        assembly {
            mstore(_freePtr, BALANCE_OF_SELECTOR)
        }
        for (uint256 i; i < _assets.length;) {
            address asset;
            uint256 toConvert;
            assembly {
                // compute slot of the assets
                mstore(0, _assets.slot)
                let slot := keccak256(0, 0x20)
                asset := sload(add(slot, i))
                mstore(add(_freePtr, 0x04), address())
                let retOffset := add(_freePtr, 0x24)
                let res := staticcall(gas(), asset, _freePtr, 0x24, retOffset, 0x20)
                if iszero(res) {
                    switch _allowFailure
                    case 1 {
                        mstore(_freePtr, ACCOUNTING_FAILED_ERROR)
                        mstore(add(_freePtr, 0x04), asset)
                        revert(_freePtr, 0x24)
                    }
                    case 0 { success := 0 }
                }
                toConvert := mload(retOffset)

                // compute lockedTokens value slot for asset
                mstore(0x00, asset)
                mstore(0x20, _lockedTokens.slot)
                slot := keccak256(0x00, 0x40)
                toConvert := add(toConvert, sload(slot))
                // if the asset is the wrapped native, add the native balance
                if eq(_wrappedNative, asset) {
                    // if the vault processes native deposits, make sure to exclude msg.value
                    switch iszero(_isNativeDeposit)
                    case 1 { toConvert := add(toConvert, selfbalance()) }
                    default { toConvert := add(toConvert, sub(selfbalance(), callvalue())) }
                }
            }
            if (!success) {
                return (0, false);
            }
            // convert to underlying
            // this function will use new free mem ptr
            _totalAssets += MoreVaultsLib.convertToUnderlying(asset, toConvert, Math.Rounding.Floor);
            unchecked {
                ++i;
            }
        }
    }

    function _accountFacets(bytes32[] storage _selectors, uint256 _totalAssets, uint256 _freePtr, bool _allowFailure)
        private
        view
        returns (uint256 newTotalAssets, bool success)
    {
        success = true;
        assembly {
            // put a debt variable on the stack
            let debt := 0
            // load facets length
            let length := sload(_selectors.slot)
            // calc beginning of the array
            mstore(0, _selectors.slot)
            let slot := keccak256(0, 0x20)
            // set return offset
            let retOffset := add(_freePtr, 0x04)
            // loop through facets
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                // read facet selector and execute staticcall
                let selector := sload(add(slot, i))
                mstore(_freePtr, selector)
                let res := staticcall(gas(), address(), _freePtr, 4, retOffset, 0x40)
                // if staticcall fails, revert with the error
                if iszero(res) {
                    switch _allowFailure
                    case 1 {
                        mstore(_freePtr, ACCOUNTING_FAILED_ERROR)
                        mstore(add(_freePtr, 0x04), selector)
                        revert(_freePtr, 0x24)
                    }
                    case 0 {
                        success := 0
                        break
                    }
                }
                // decode return values
                let decodedAmount := mload(retOffset)
                let isPositive := mload(add(retOffset, 0x20))
                // if the amount is positive, add it to the total assets else add to debt
                if isPositive { _totalAssets := add(_totalAssets, decodedAmount) }
                if iszero(isPositive) { debt := add(debt, decodedAmount) }
            }

            // after accounting is done check if total assets are greater than debt
            // else leave totalAssets unassigned as "lower" and "equal" should return 0
            if gt(_totalAssets, debt) { newTotalAssets := sub(_totalAssets, debt) }
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function totalAssets() public view override(ERC4626Upgradeable, IVaultFacet) returns (uint256 _totalAssets) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // get free mem ptr for efficient calls
        uint256 freePtr;
        assembly {
            freePtr := 0x60
        }
        // account available assets
        (_totalAssets,) = _accountAvailableAssets(
            ds.availableAssets, ds.lockedTokens, ds.wrappedNative, ds.isNativeDeposit, freePtr, true
        );
        // account facets
        (_totalAssets,) = _accountFacets(ds.facetsForAccounting, _totalAssets, freePtr, true);
    }

    function totalAssetsUsd() public returns (uint256 _totalAssets, bool success) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        _beforeAccounting(ds.beforeAccountingFacets);
        // get free mem ptr for efficient calls
        uint256 freePtr;
        assembly {
            freePtr := 0x60
        }
        // account available assets
        (_totalAssets, success) = _accountAvailableAssets(
            ds.availableAssets, ds.lockedTokens, ds.wrappedNative, ds.isNativeDeposit, freePtr, false
        );
        if (!success) {
            return (0, false);
        }
        // account facets
        (_totalAssets, success) = _accountFacets(ds.facetsForAccounting, _totalAssets, freePtr, false);
        if (!success) {
            return (0, false);
        }

        return (MoreVaultsLib.convertUnderlyingToUsd(_totalAssets, Math.Rounding.Floor), true);
    }

    /**
     * @notice override maxDeposit to check if the deposit capacity is exceeded
     * @dev Warning: the returned value can be slightly higher since accrued fee are not included.
     */
    function maxDeposit(
        address // receiver
    ) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 assetsInVault = totalAssets();
        if (ds.depositCapacity == 0) {
            return type(uint256).max;
        }
        if (assetsInVault > ds.depositCapacity) {
            return 0;
        } else {
            return ds.depositCapacity - assetsInVault;
        }
    }

    /**
     * @notice override maxMint to check if the deposit capacity is exceeded
     * @dev Warning: the returned value can be slightly higher since accrued fee are not included.
     */
    function maxMint(
        address // receiver
    ) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 assetsInVault = totalAssets();
        if (ds.depositCapacity == 0) {
            return type(uint256).max;
        }
        if (assetsInVault > ds.depositCapacity) {
            return 0;
        } else {
            return _convertToShares(ds.depositCapacity - assetsInVault, Math.Rounding.Floor);
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function getWithdrawalRequest(address _owner) public view returns (uint256 shares, uint256 timelockEndsAt) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[_owner];

        return (request.shares, request.timelockEndsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function clearRequest() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[msg.sender];

        delete request.shares;
        delete request.timelockEndsAt;

        emit WithdrawRequestDeleted(msg.sender);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function requestRedeem(uint256 _shares) external {
        MoreVaultsLib.validateNotMulticall();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        if (!ds.isHub) {
            revert NotAHub();
        }
        if (!ds.isWithdrawalQueueEnabled) {
            revert WithdrawalQueueDisabled();
        }

        if (_shares == 0) {
            revert InvalidSharesAmount();
        }

        uint256 maxRedeem_ = maxRedeem(msg.sender);
        if (_shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(msg.sender, _shares, maxRedeem_);
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[msg.sender];
        request.shares = _shares;
        uint256 endsAt = block.timestamp + ds.witdrawTimelock;
        request.timelockEndsAt = endsAt;

        emit WithdrawRequestCreated(msg.sender, _shares, endsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function requestWithdraw(uint256 _assets) external {
        MoreVaultsLib.validateNotMulticall();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (!ds.isWithdrawalQueueEnabled) {
            revert WithdrawalQueueDisabled();
        }
        if (_assets == 0) {
            revert InvalidAssetsAmount();
        }

        if (!ds.isHub) {
            revert NotAHub();
        }
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        if (factory.isCrossChainVault(factory.localEid(), address(this)) && !ds.oraclesCrossChainAccounting) {
            revert RequestWithdrawDisabled();
        }
        _beforeAccounting(ds.beforeAccountingFacets);
        uint256 newTotalAssets = totalAssets();
        _accrueInterest(newTotalAssets, uint64(block.timestamp));

        uint256 shares = _convertToSharesWithTotals(_assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

        if (shares == 0) {
            revert InvalidSharesAmount();
        }

        uint256 maxRedeem_ = maxRedeem(msg.sender);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxRedeem_);
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[msg.sender];

        request.shares = shares;

        uint256 endsAt = block.timestamp + ds.witdrawTimelock;
        request.timelockEndsAt = endsAt;

        emit WithdrawRequestCreated(msg.sender, shares, endsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 shares)
    {
        MoreVaultsLib.validateNotMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        (uint256 newTotalAssets, address msgSender, uint64 timestamp) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, timestamp);
        _validateCapacity(receiver, newTotalAssets, assets);

        ds.lastTotalAssets = newTotalAssets;

        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);
        _deposit(msgSender, receiver, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function mint(uint256 shares, address receiver)
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 assets)
    {
        MoreVaultsLib.validateNotMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        (uint256 newTotalAssets, address msgSender, uint64 timestamp) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, timestamp);
        ds.lastTotalAssets = newTotalAssets;

        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Ceil);
        _validateCapacity(receiver, newTotalAssets, assets);
        _deposit(msgSender, receiver, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 shares)
    {
        MoreVaultsLib.validateNotMulticall();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        (uint256 newTotalAssets, address msgSender, uint64 timestamp) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, timestamp);

        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 assets)
    {
        MoreVaultsLib.validateNotMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        (uint256 newTotalAssets, address msgSender, uint64 timestamp) = _getInfoForAction(ds);
        _accrueInterest(newTotalAssets, timestamp);

        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function deposit(address[] calldata tokens, uint256[] calldata assets, address receiver)
        external
        payable
        whenNotPaused
        returns (uint256 shares)
    {
        MoreVaultsLib.validateNotMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (msg.value > 0) {
            ds.isNativeDeposit = true;
        }
        (uint256 newTotalAssets, address msgSender, uint64 timestamp) = _getInfoForAction(ds);
        _accrueInterest(newTotalAssets, timestamp);

        ds.lastTotalAssets = newTotalAssets;

        if (assets.length != tokens.length) {
            revert ArraysLengthsDontMatch(tokens.length, assets.length);
        }

        uint256 totalConvertedAmount;
        for (uint256 i; i < tokens.length;) {
            MoreVaultsLib.validateAssetDepositable(tokens[i]);
            totalConvertedAmount += MoreVaultsLib.convertToUnderlying(tokens[i], assets[i], Math.Rounding.Floor);
            unchecked {
                ++i;
            }
        }
        if (msg.value > 0) {
            MoreVaultsLib.validateAssetDepositable(ds.wrappedNative);
            totalConvertedAmount += MoreVaultsLib.convertToUnderlying(ds.wrappedNative, msg.value, Math.Rounding.Floor);
        }

        _validateCapacity(receiver, newTotalAssets, totalConvertedAmount);

        shares = _convertToSharesWithTotals(totalConvertedAmount, totalSupply(), newTotalAssets, Math.Rounding.Floor);
        _deposit(msgSender, receiver, tokens, assets, shares);

        ds.lastTotalAssets = ds.lastTotalAssets + totalConvertedAmount;
        if (ds.isNativeDeposit) {
            ds.isNativeDeposit = false;
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function setFee(uint96 _fee) external {
        AccessControlLib.validateDiamond(msg.sender);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        (uint256 newTotalAssets,, uint64 timestamp) = _getInfoForAction(ds);
        _accrueInterest(newTotalAssets, timestamp);

        ds.lastTotalAssets = newTotalAssets;

        MoreVaultsLib._setFee(_fee);
    }

    /**
     * @notice Convert assets to shares
     * @dev Convert assets to shares
     * @param assets The assets to convert
     * @param newTotalSupply The total supply of the vault
     * @param newTotalAssets The total assets of the vault
     * @param rounding The rounding mode
     * @return The shares
     */
    function _convertToSharesWithTotals(
        uint256 assets,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, rounding);
    }

    /**
     * @notice Convert shares to assets
     * @dev Convert shares to assets
     * @param shares The shares to convert
     * @param newTotalSupply The total supply of the vault
     * @param newTotalAssets The total assets of the vault
     * @param rounding The rounding mode
     * @return The assets
     */
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), rounding);
    }

    /**
     * @notice Deposit assets to the vault
     * @dev Deposit assets to the vault and mint the shares
     * @param caller The address of the caller
     * @param receiver The address of the receiver
     * @param assets The assets to deposit
     * @param shares The shares to mint
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        super._deposit(caller, receiver, assets, shares);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.lastTotalAssets = ds.lastTotalAssets + assets;
    }

    /**
     * @notice Deposit assets to the vault
     * @dev Deposit assets to the vault and mint the shares
     * @param caller The address of the caller
     * @param receiver The address of the receiver
     * @param tokens The tokens to deposit
     * @param assets The assets to deposit
     * @param shares The shares to mint
     */
    function _deposit(
        address caller,
        address receiver,
        address[] calldata tokens,
        uint256[] calldata assets,
        uint256 shares
    ) internal {
        for (uint256 i; i < assets.length;) {
            SafeERC20.safeTransferFrom(IERC20(tokens[i]), caller, address(this), assets[i]);
            unchecked {
                ++i;
            }
        }
        _mint(receiver, shares);

        emit Deposit(caller, receiver, tokens, assets, shares);
    }

    /**
     * @notice Accrue the interest of the vault
     * @dev Calculate the interest of the vault and mint the fee shares
     * @param _totalAssets The total assets of the vault
     */
    function _accrueInterest(uint256 _totalAssets, uint64 _timestamp) internal {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 feeShares;
        feeShares = _accruedFeeShares(_totalAssets);
        _checkVaultHealth(_totalAssets, totalSupply());

        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();

        // if the timestamp is less than the last accrued interest timestamp, that means the interest has already been accrued
        // it needs to prevent multiple fee accruals if cross chain accounting is used
        if (_timestamp <= ds.lastAccruedInterestTimestamp) {
            return;
        }
        ds.lastAccruedInterestTimestamp = _timestamp;
        ds.lastTotalAssets = _totalAssets;

        (address protocolFeeRecipient, uint96 protocolFee) =
            IMoreVaultsRegistry(acs.moreVaultsRegistry).protocolFeeInfo(address(this));

        emit AccrueInterest(_totalAssets, feeShares);

        if (feeShares == 0) return;

        if (protocolFee != 0) {
            uint256 protocolFeeShares = feeShares.mulDiv(protocolFee, MoreVaultsLib.FEE_BASIS_POINT);
            _mint(protocolFeeRecipient, protocolFeeShares);
            unchecked {
                feeShares -= protocolFeeShares;
            }
        }

        _mint(ds.feeRecipient, feeShares);
    }

    /**
     * @notice Accrue the interest of the vault
     * @dev Calculate the interest of the vault and the fee shares
     * @param _totalAssets The total assets of the vault
     * @return feeShares The fee shares
     */
    function _accruedFeeShares(uint256 _totalAssets) internal view returns (uint256 feeShares) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 lastTotalAssets = ds.lastTotalAssets;
        uint256 totalInterest = _totalAssets > lastTotalAssets ? _totalAssets - lastTotalAssets : 0;

        uint96 fee = ds.fee;
        if (totalInterest != 0 && fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(fee, MoreVaultsLib.FEE_BASIS_POINT);
            feeShares =
                feeAssets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), _totalAssets - feeAssets, Math.Rounding.Floor);
        }
    }

    /**
     * @notice Validate the capacity of the vault
     * @dev If the deposit capacity is 0, the vault is not limited by the deposit capacity
     * @param receiver The address of the receiver
     * @param newTotalAssets The total assets of the vault
     * @param newAssets The assets to deposit
     */
    function _validateCapacity(address receiver, uint256 newTotalAssets, uint256 newAssets) internal view {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        if (ds.isWhitelistEnabled) {
            uint256 userDepositedAssets =
                _convertToAssetsWithTotals(balanceOf(receiver), totalSupply(), newTotalAssets, Math.Rounding.Ceil);
            if (ds.depositWhitelist[receiver] < userDepositedAssets + newAssets) {
                revert ERC4626ExceededMaxDeposit(
                    receiver,
                    newAssets,
                    ds.depositWhitelist[receiver] > userDepositedAssets
                        ? ds.depositWhitelist[receiver] - userDepositedAssets
                        : 0
                );
            }
        }

        uint256 depositCapacity = ds.depositCapacity;
        if (depositCapacity == 0) {
            return;
        }
        if (newTotalAssets + newAssets > depositCapacity) {
            uint256 maxToDeposit;
            if (newTotalAssets < depositCapacity) {
                maxToDeposit = depositCapacity - newTotalAssets;
            }
            revert ERC4626ExceededMaxDeposit(receiver, newAssets, maxToDeposit);
        }
    }

    /**
     * @notice Check if the vault is healthy
     * @dev If the total assets is 0 and the total supply is greater than 0, then the debt is greater than
     * the assets and the vault is unhealthy
     * @param _totalAssets The total assets of the vault
     * @param _totalSupply The total supply of the vault
     */
    function _checkVaultHealth(uint256 _totalAssets, uint256 _totalSupply) internal pure {
        if (_totalAssets == 0 && _totalSupply > 0) {
            revert VaultDebtIsGreaterThanAssets();
        }
    }

    /**
     * @notice Get the decimals offset
     * @dev Get the decimals offset
     * @return The decimals offset
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 2;
    }

    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 newTotalAssets = totalAssets();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 ts = totalSupply();
        uint256 lastTotalAssets = ds.lastTotalAssets;

        uint256 totalInterest = newTotalAssets > lastTotalAssets ? (newTotalAssets - lastTotalAssets) : 0;
        uint256 feeShares;
        if (totalInterest != 0 && ds.fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(ds.fee, MoreVaultsLib.FEE_BASIS_POINT);
            feeShares = feeAssets.mulDiv(ts + 10 ** _decimalsOffset(), newTotalAssets - feeAssets, Math.Rounding.Floor);
        }

        uint256 simTotalSupply = ts + feeShares;

        return _convertToSharesWithTotals(assets, simTotalSupply, newTotalAssets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 newTotalAssets = totalAssets();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 ts = totalSupply();
        uint256 lastTotalAssets = ds.lastTotalAssets;

        uint256 totalInterest = newTotalAssets > lastTotalAssets ? (newTotalAssets - lastTotalAssets) : 0;
        uint256 feeShares;
        if (totalInterest != 0 && ds.fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(ds.fee, MoreVaultsLib.FEE_BASIS_POINT);
            feeShares = feeAssets.mulDiv(ts + 10 ** _decimalsOffset(), newTotalAssets - feeAssets, Math.Rounding.Floor);
        }

        uint256 simTotalSupply = ts + feeShares;
        return _convertToAssetsWithTotals(shares, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 newTotalAssets = totalAssets();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 ts = totalSupply();
        uint256 lastTotalAssets = ds.lastTotalAssets;

        uint256 totalInterest = newTotalAssets > lastTotalAssets ? (newTotalAssets - lastTotalAssets) : 0;
        uint256 feeShares;
        if (totalInterest != 0 && ds.fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(ds.fee, MoreVaultsLib.FEE_BASIS_POINT);
            feeShares = feeAssets.mulDiv(ts + 10 ** _decimalsOffset(), newTotalAssets - feeAssets, Math.Rounding.Floor);
        }

        uint256 simTotalSupply = ts + feeShares;

        // Calculate withdrawal fee
        uint256 withdrawalFeeAmount = 0;
        if (ds.withdrawalFee > 0) {
            withdrawalFeeAmount = assets.mulDiv(ds.withdrawalFee, MoreVaultsLib.FEE_BASIS_POINT, Math.Rounding.Floor);
        }

        uint256 netAssets = assets - withdrawalFeeAmount;

        return _convertToSharesWithTotals(netAssets, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 newTotalAssets = totalAssets();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        uint256 ts = totalSupply();
        uint256 lastTotalAssets = ds.lastTotalAssets;

        uint256 totalInterest = newTotalAssets > lastTotalAssets ? (newTotalAssets - lastTotalAssets) : 0;
        uint256 feeShares;
        if (totalInterest != 0 && ds.fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(ds.fee, MoreVaultsLib.FEE_BASIS_POINT);
            feeShares = feeAssets.mulDiv(ts + 10 ** _decimalsOffset(), newTotalAssets - feeAssets, Math.Rounding.Floor);
        }

        uint256 simTotalSupply = ts + feeShares;

        uint256 assets = _convertToAssetsWithTotals(shares, simTotalSupply, newTotalAssets, Math.Rounding.Floor);

        // Calculate withdrawal fee
        uint256 withdrawalFeeAmount = 0;
        if (ds.withdrawalFee > 0) {
            withdrawalFeeAmount = assets.mulDiv(ds.withdrawalFee, MoreVaultsLib.FEE_BASIS_POINT, Math.Rounding.Floor);
        }

        return assets - withdrawalFeeAmount;
    }

    function _getInfoForAction(MoreVaultsLib.MoreVaultsStorage storage ds)
        internal
        returns (uint256 totalAssets_, address msgSender_, uint64 timestamp_)
    {
        if (!ds.isHub) {
            revert NotAHub();
        }
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        if (factory.isCrossChainVault(factory.localEid(), address(this)) && !ds.oraclesCrossChainAccounting) {
            bytes32 guid = ds.finalizationGuid;
            if (guid == 0) {
                revert SyncActionsDisabledInCrossChainVaults();
            } else {
                totalAssets_ = ds.guidToCrossChainRequestInfo[guid].totalAssets;
                msgSender_ = ds.guidToCrossChainRequestInfo[guid].initiator;
                timestamp_ = ds.guidToCrossChainRequestInfo[guid].timestamp;
            }
        } else {
            _beforeAccounting(ds.beforeAccountingFacets);
            totalAssets_ = totalAssets();
            msgSender_ = _msgSender();
            timestamp_ = uint64(block.timestamp);
        }
    }

    function _handleWithdrawal(
        MoreVaultsLib.MoreVaultsStorage storage ds,
        uint256 newTotalAssets,
        address msgSender,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal {
        // calculate withdrawal fee
        uint256 withdrawalFeeAmount;
        if (ds.withdrawalFee > 0) {
            withdrawalFeeAmount = assets.mulDiv(ds.withdrawalFee, MoreVaultsLib.FEE_BASIS_POINT, Math.Rounding.Floor);
        }

        uint256 netAssets = assets - withdrawalFeeAmount;

        ds.lastTotalAssets = newTotalAssets > assets ? newTotalAssets - assets : 0;

        _withdraw(msgSender, receiver, owner, netAssets, shares);

        // mint fee shares to fee recipient if withdrawal fee is applied
        if (withdrawalFeeAmount > 0) {
            uint256 feeShares =
                _convertToSharesWithTotals(withdrawalFeeAmount, totalSupply(), newTotalAssets, Math.Rounding.Floor);
            _mint(ds.feeRecipient, feeShares);
        }

        emit WithdrawRequestFulfilled(owner, receiver, shares, netAssets);
    }
}
