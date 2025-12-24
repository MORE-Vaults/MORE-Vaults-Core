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
    ERC20Upgradeable,
    SafeERC20,
    LowLevelCall, 
    Memory,
    IERC20Metadata
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

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.VaultFacetV1.0.1");
    }

    function facetName() external pure returns (string memory) {
        return "VaultFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.1";
    }

    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Facet interfaces
        ds.supportedInterfaces[type(IERC20).interfaceId] = true; // ERC20 interface
        ds.supportedInterfaces[type(IERC4626).interfaceId] = true; // ERC4626 base interface
        ds.supportedInterfaces[type(IVaultFacet).interfaceId] = true; // VaultFacet (extended ERC4626)

        if (super.asset() == address(0)) {
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
            MoreVaultsLib._setFeeRecipient(feeRecipient);
            MoreVaultsLib._setFee(fee);
            MoreVaultsLib._setDepositCapacity(depositCapacity);
            _initERC4626Directly(IERC20(asset));
            _initERC20Directly(name, symbol);
            MoreVaultsLib._addAvailableAsset(asset);
            MoreVaultsLib._enableAssetToDeposit(asset);
        }
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IERC20).interfaceId] = false;
        ds.supportedInterfaces[type(IERC4626).interfaceId] = false;
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
        if (AccessControlLib.vaultOwner() != msg.sender && AccessControlLib.vaultGuardian() != msg.sender) {
            revert AccessControlLib.UnauthorizedAccess();
        }
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
                if isPositive {
                    let newTotal := add(_totalAssets, decodedAmount)
                    if lt(newTotal, _totalAssets) {
                        mstore(0, 0x08c379a0)
                        mstore(4, 0x20)
                        mstore(36, 17)
                        mstore(68, "Accounting overflow")
                        revert(0, 100)
                    }
                    _totalAssets := newTotal
                }
                if iszero(isPositive) {
                    let newDebt := add(debt, decodedAmount)
                    if lt(newDebt, debt) {
                        mstore(0, 0x08c379a0)
                        mstore(4, 0x20)
                        mstore(36, 17)
                        mstore(68, "Accounting overflow")
                        revert(0, 100)
                    }
                    debt := newDebt
                }
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
    function maxDeposit(address user) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _maxDepositInAssets(user);
    }

    /**
     * @notice override maxMint to check if the deposit capacity is exceeded
     * @dev Warning: the returned value can be slightly higher since accrued fee are not included.
     */
    function maxMint(address user) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 _maxDeposit = _maxDepositInAssets(user);
        if (_maxDeposit == type(uint256).max || _maxDeposit == 0) {
            return _maxDeposit;
        }
        return _convertToShares(_maxDeposit, Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        return super.maxRedeem(owner);
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
        _accrueInterest(newTotalAssets, msg.sender);

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

        (uint256 newTotalAssets, address msgSender) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, receiver);
        _validateCapacity(msgSender, newTotalAssets, assets);

        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Floor);
        _deposit(msgSender, receiver, assets, shares);

        // Update user's HWMpS after deposit (using new total assets after deposit)
        uint256 totalAssetsAfterDeposit = newTotalAssets + assets;
        _updateUserHWMpS(totalAssetsAfterDeposit, receiver);
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

        (uint256 newTotalAssets, address msgSender) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, receiver);

        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Ceil);
        _validateCapacity(msgSender, newTotalAssets, assets);
        _deposit(msgSender, receiver, assets, shares);

        // Update user's HWMpS after mint (using new total assets after deposit)
        uint256 totalAssetsAfterDeposit = newTotalAssets + assets;
        _updateUserHWMpS(totalAssetsAfterDeposit, receiver);
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
        (uint256 newTotalAssets, address msgSender) = _getInfoForAction(ds);

        _accrueInterest(newTotalAssets, owner);

        shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);

        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(msgSender, owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        // Calculate withdrawal fee to determine net assets
        uint256 netAssets = _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);

        // Update user's HWMpS after withdrawal (using calculated total assets after withdrawal)
        uint256 totalAssetsAfterWithdrawal = newTotalAssets > netAssets ? newTotalAssets - netAssets : 0;
        _updateUserHWMpS(totalAssetsAfterWithdrawal, owner);
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

        (uint256 newTotalAssets, address msgSender) = _getInfoForAction(ds);

        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(msgSender, owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        _accrueInterest(newTotalAssets, owner);

        assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

        uint256 netAssets = _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);

        // Update user's HWMpS after redeem (using calculated total assets after withdrawal)
        uint256 totalAssetsAfterWithdrawal = newTotalAssets > netAssets ? newTotalAssets - netAssets : 0;
        _updateUserHWMpS(totalAssetsAfterWithdrawal, owner);
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
        (uint256 newTotalAssets, address msgSender) = _getInfoForAction(ds);
        _accrueInterest(newTotalAssets, receiver);

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

        _validateCapacity(msgSender, newTotalAssets, totalConvertedAmount);

        shares = _convertToSharesWithTotals(totalConvertedAmount, totalSupply(), newTotalAssets, Math.Rounding.Floor);
        _deposit(msgSender, receiver, tokens, assets, shares);

        if (ds.isNativeDeposit) {
            ds.isNativeDeposit = false;
        }

        // Update user's HWMpS after deposit
        uint256 totalAssetsAfterDeposit = newTotalAssets + totalConvertedAmount;
        _updateUserHWMpS(totalAssetsAfterDeposit, receiver);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function setFee(uint96 _fee) external {
        AccessControlLib.validateDiamond(msg.sender);

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
        _changeDepositCap(ds, caller, assets, true);
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

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _changeDepositCap(ds, caller, convertToAssets(shares), true);

        emit Deposit(caller, receiver, tokens, assets, shares);
    }

    /**
     * @notice Accrue the interest of the vault
     * @dev Calculate the interest of the vault and mint the fee shares
     * @param _totalAssets The total assets of the vault
     * @param _user The address of the user for per-user fee calculation (address(0) for global/legacy mode)
     */
    function _accrueInterest(uint256 _totalAssets, address _user) internal {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 feeShares;
        if (_user == address(0)) {
            revert ZeroAddress();
        }
        feeShares = _accruedFeeSharesPerUser(_totalAssets, _user);
        _checkVaultHealth(_totalAssets, totalSupply());

        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();

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
     * @notice Accrue the interest of the vault (legacy version without user parameter)
     * @dev Calculate the interest of the vault and mint the fee shares
     * @param _totalAssets The total assets of the vault
     */
    function _accrueInterest(uint256 _totalAssets) internal {
        _accrueInterest(_totalAssets, address(0));
    }

    /**
     * @notice Calculate fee shares for a specific user based on their High-Water Mark per Share
     * @dev Calculate the fee shares for a user's position only if current price per share exceeds their HWMpS
     * @param _totalAssets The total assets of the vault
     * @param _user The address of the user
     * @return feeShares The fee shares for this user's position
     */
    function _accruedFeeSharesPerUser(uint256 _totalAssets, address _user) internal view returns (uint256 feeShares) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            return 0;
        }

        // Calculate current price per share (with decimals offset)
        uint256 currentPricePerShare =
            _totalAssets.mulDiv(10 ** _decimalsOffset(), totalSupply_ + 10 ** _decimalsOffset(), Math.Rounding.Floor);

        // Get user's High-Water Mark per Share
        uint256 userHWMpS = ds.userHighWaterMarkPerShare[_user];

        // If current price is not higher than HWMpS, no fee is accrued
        if (currentPricePerShare <= userHWMpS) {
            return 0;
        }

        // Calculate user's current position value
        uint256 userShares = balanceOf(_user);
        if (userShares == 0) {
            return 0;
        }

        // Calculate profit above HWMpS for this user
        uint256 userAssetsAtHWM = userShares.mulDiv(userHWMpS, 10 ** _decimalsOffset(), Math.Rounding.Floor);
        uint256 userCurrentAssets =
            userShares.mulDiv(currentPricePerShare, 10 ** _decimalsOffset(), Math.Rounding.Floor);
        uint256 userProfit = userCurrentAssets > userAssetsAtHWM ? userCurrentAssets - userAssetsAtHWM : 0;

        if (userProfit == 0) {
            return 0;
        }

        uint96 fee = ds.fee;
        if (fee == 0) {
            return 0;
        }

        // Calculate fee assets for this user's profit
        uint256 feeAssets = userProfit.mulDiv(fee, MoreVaultsLib.FEE_BASIS_POINT);

        // Convert fee assets to fee shares
        if (feeAssets >= _totalAssets) {
            return 0;
        }
        feeShares =
            feeAssets.mulDiv(totalSupply_ + 10 ** _decimalsOffset(), _totalAssets - feeAssets, Math.Rounding.Floor);
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
            if (ds.depositWhitelist[receiver] < newAssets) {
                revert ERC4626ExceededMaxDeposit(receiver, newAssets, ds.depositWhitelist[receiver]);
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

    function _changeDepositCap(
        MoreVaultsLib.MoreVaultsStorage storage ds,
        address receiver,
        uint256 assets,
        bool isDecrease
    ) internal {
        if (ds.isWhitelistEnabled) {
            ds.depositWhitelist[receiver] =
                isDecrease ? ds.depositWhitelist[receiver] - assets : ds.depositWhitelist[receiver] + assets;
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
     * @notice Update user's High-Water Mark per Share
     * @dev Updates the user's HWMpS to the current price per share if it's higher
     * @param _totalAssets The total assets of the vault
     * @param _user The address of the user
     */
    function _updateUserHWMpS(uint256 _totalAssets, address _user) internal {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            return;
        }

        // Calculate current price per share (with decimals offset)
        uint256 currentPricePerShare =
            _totalAssets.mulDiv(10 ** _decimalsOffset(), totalSupply_ + 10 ** _decimalsOffset(), Math.Rounding.Floor);

        // Update HWMpS if current price is higher
        uint256 userHWMpS = ds.userHighWaterMarkPerShare[_user];
        if (currentPricePerShare > userHWMpS) {
            ds.userHighWaterMarkPerShare[_user] = currentPricePerShare;
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
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        uint256 newTotalAssets = totalAssets();
        uint256 ts = totalSupply();

        // Calculate fee shares for the caller based on their HWMpS (before deposit)
        uint256 feeShares = _accruedFeeSharesPerUser(newTotalAssets, msg.sender);

        uint256 simTotalSupply = ts + feeShares;

        return _convertToSharesWithTotals(assets, simTotalSupply, newTotalAssets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        uint256 newTotalAssets = totalAssets();
        uint256 ts = totalSupply();

        // Calculate fee shares for the caller based on their HWMpS (before mint)
        uint256 feeShares = _accruedFeeSharesPerUser(newTotalAssets, msg.sender);

        uint256 simTotalSupply = ts + feeShares;
        return _convertToAssetsWithTotals(shares, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        uint256 newTotalAssets = totalAssets();
        uint256 ts = totalSupply();

        // Calculate fee shares for the caller based on their HWMpS (before withdrawal)
        uint256 feeShares = _accruedFeeSharesPerUser(newTotalAssets, msg.sender);

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
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        uint256 newTotalAssets = totalAssets();
        uint256 ts = totalSupply();

        // Calculate fee shares for the caller based on their HWMpS (before redeem)
        uint256 feeShares = _accruedFeeSharesPerUser(newTotalAssets, msg.sender);

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
        returns (uint256 totalAssets_, address msgSender_)
    {
        if (!ds.isHub) {
            revert NotAHub();
        }
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        if (factory.isCrossChainVault(factory.localEid(), address(this)) && !ds.oraclesCrossChainAccounting) {
            bytes32 guid = ds.finalizationGuid;
            if (guid == 0) {
                revert SyncActionsDisabledInThisVault();
            } else {
                totalAssets_ = ds.guidToCrossChainRequestInfo[guid].totalAssets;
                msgSender_ = ds.guidToCrossChainRequestInfo[guid].initiator;
            }
        } else {
            _beforeAccounting(ds.beforeAccountingFacets);
            totalAssets_ = totalAssets();
            msgSender_ = _msgSender();
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
    ) internal returns (uint256 netAssets) {
        // calculate withdrawal fee
        uint256 withdrawalFeeAmount;
        if (ds.withdrawalFee > 0) {
            withdrawalFeeAmount = assets.mulDiv(ds.withdrawalFee, MoreVaultsLib.FEE_BASIS_POINT, Math.Rounding.Floor);
        }

        netAssets = assets - withdrawalFeeAmount;

        _changeDepositCap(ds, msgSender, assets, false);

        _withdraw(msgSender, receiver, owner, netAssets, shares);

        // mint fee shares to fee recipient if withdrawal fee is applied
        if (withdrawalFeeAmount > 0) {
            uint256 feeShares = _convertToSharesWithTotals(
                withdrawalFeeAmount, totalSupply(), newTotalAssets - assets, Math.Rounding.Floor
            );
            _mint(ds.feeRecipient, feeShares);
        }

        emit WithdrawRequestFulfilled(owner, receiver, shares, netAssets);
    }

    function _maxDepositInAssets(address user) internal view returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        _validateERC4626Compatible(ds);
        uint256 assetsInVault = totalAssets();
        if (ds.depositCapacity == 0 && !ds.isWhitelistEnabled) {
            return type(uint256).max;
        }
        if (assetsInVault > ds.depositCapacity) {
            return 0;
        } else {
            uint256 maxToDeposit = ds.depositCapacity - assetsInVault;
            if (ds.isWhitelistEnabled) {
                maxToDeposit = Math.min(maxToDeposit, ds.depositWhitelist[user]);
            }
            return maxToDeposit;
        }
    }

    function _validateERC4626Compatible(MoreVaultsLib.MoreVaultsStorage storage ds) internal view {
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        if (factory.isCrossChainVault(factory.localEid(), address(this)) && !ds.oraclesCrossChainAccounting) {
            revert NotAnERC4626CompatibleVault();
        }
    }

    /**
     * @dev Initializes ERC4626 storage directly, bypassing the onlyInitializing modifier
     * @param asset_ Address of the underlying asset
     */
    function _initERC4626Directly(IERC20 asset_) private {
        // Use the same storage location as in ERC4626Upgradeable
        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
        bytes32 storageLocation = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
        
        (bool success, uint8 assetDecimals) = _tryGetAssetDecimalsLocal(asset_);

        ERC4626Upgradeable.ERC4626Storage storage $;
        assembly {
            $.slot := storageLocation
        }

        $._underlyingDecimals = success ? assetDecimals : 18;
        $._asset = asset_;
    }

    /**
     * @dev Attempts to get decimals from the asset
     * @param asset_ Address of the asset
     * @return ok Success of the operation
     * @return assetDecimals Number of decimals of the asset
     */
    function _tryGetAssetDecimalsLocal(IERC20 asset_) private view returns (bool ok, uint8 assetDecimals) {
        Memory.Pointer ptr = Memory.getFreeMemoryPointer();
        (bool success, bytes32 returnedDecimals,) = LowLevelCall.staticcallReturn64Bytes(
            address(asset_), abi.encodeCall(IERC20Metadata.decimals, ())
        );
        Memory.setFreeMemoryPointer(ptr);

        return
            (success && LowLevelCall.returnDataSize() >= 32 && uint256(returnedDecimals) <= type(uint8).max)
                ? (true, uint8(uint256(returnedDecimals)))
                : (false, 0);
    }

    /**
     * @dev Initializes ERC20 storage directly, bypassing the onlyInitializing modifier
     * @param name_ Token name
     * @param symbol_ Token symbol
     */
    function _initERC20Directly(string memory name_, string memory symbol_) private {
        // Use the same storage location as in ERC20Upgradeable
        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
        bytes32 storageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
        
        ERC20Upgradeable.ERC20Storage storage $;
        assembly {
            $.slot := storageLocation
        }
        
        $._name = name_;
        $._symbol = symbol_;
    }
}
