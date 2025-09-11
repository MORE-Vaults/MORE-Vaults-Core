// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib, BEFORE_ACCOUNTING_SELECTOR, BEFORE_ACCOUNTING_FAILED_ERROR, ACCOUNTING_FAILED_ERROR, BALANCE_OF_SELECTOR} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGenericMoreVaultFacet} from "../interfaces/facets/IGenericMoreVaultFacet.sol";
import {ERC4626Upgradeable, SafeERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract VaultFacet is
    ERC4626Upgradeable,
    PausableUpgradeable,
    IVaultFacet,
    BaseFacetInitializer
{
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    error WithdrawSchedulerInvalidTimestamp(uint256 timestamp);
    error CantCoverWithdrawRequests(uint256, uint256);
    error InvalidSharesAmount();
    error InvalidAssetsAmount();
    error CantProcessWithdrawRequest();
    error VaultIsUsingRestrictedFacet(address);
    error NotAHub();

    event WithdrawRequestCreated(
        address requester,
        uint256 sharesAmount,
        uint256 endsAt
    );
    event WithdrawRequestFulfilled(
        address requester,
        address receiver,
        uint256 sharesAmount,
        uint256 assetAmount
    );
    event WithdrawRequestDeleted(address requester);

    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.MoreVaults");
    }

    function facetName() external pure returns (string memory) {
        return "VaultFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(
        bytes calldata data
    ) external initializerFacet initializer {
        (
            string memory name,
            string memory symbol,
            address asset,
            address feeRecipient,
            uint96 fee,
            uint256 depositCapacity
        ) = abi.decode(
                data,
                (string, string, address, address, uint96, uint256)
            );
        if (
            asset == address(0) ||
            feeRecipient == address(0) ||
            fee > MoreVaultsLib.FEE_BASIS_POINT
        ) revert InvalidParameters();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

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

    function onFacetRemoval(address, bool) external override {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IVaultFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function paused()
        public
        view
        override(PausableUpgradeable, IVaultFacet)
        returns (bool)
    {
        return super.paused();
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function pause() external {
        if (
            AccessControlLib.vaultOwner() != msg.sender && // TODO: add Guardian
            MoreVaultsLib.factoryAddress() != msg.sender
        ) {
            revert AccessControlLib.UnauthorizedAccess();
        }
        _pause();
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function unpause() external {
        AccessControlLib.validateOwner(msg.sender); // TODO: add Guardian
        IVaultsFactory factory = IVaultsFactory(MoreVaultsLib.factoryAddress());
        address[] memory restrictedFacets = factory.getRestrictedFacets();
        for (uint256 i = 0; i < restrictedFacets.length; ) {
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
        assembly {
            let freePtr := mload(0x40)
            let length := sload(_baf.slot)
            mstore(0, _baf.slot)
            let slot := keccak256(0, 0x20)
            mstore(freePtr, BEFORE_ACCOUNTING_SELECTOR)
            for {
                let i := 0
            } lt(i, length) {
                i := add(i, 1)
            } {
                let facet := sload(add(slot, i))
                let res := delegatecall(gas(), facet, freePtr, 4, 0, 0) // call facets for acounting, ignore return values
                // if delegatecall fails, revert with the error
                if iszero(res) {
                    mstore(freePtr, BEFORE_ACCOUNTING_FAILED_ERROR)
                    mstore(add(freePtr, 0x04), facet)
                    revert(freePtr, 0x24)
                }
            }
        }
    }

    function _accountAvailableAssets(
        address[] storage _assets,
        mapping(address => uint256) storage _lockedTokens,
        address _wrappedNative,
        bool _isNativeDeposit,
        uint256 _freePtr
    ) private view returns (uint256 _totalAssets) {
        assembly {
            mstore(_freePtr, BALANCE_OF_SELECTOR)
        }
        for (uint i; i < _assets.length; ) {
            address asset;
            uint256 toConvert;
            assembly {
                // compute slot of the assets
                mstore(0, _assets.slot)
                let slot := keccak256(0, 0x20)
                asset := sload(add(slot, i))
                mstore(add(_freePtr, 0x04), address())
                let retOffset := add(_freePtr, 0x24)
                let res := staticcall(
                    gas(),
                    asset,
                    _freePtr,
                    0x24,
                    retOffset,
                    0x20
                )
                if iszero(res) {
                    mstore(_freePtr, ACCOUNTING_FAILED_ERROR)
                    mstore(add(_freePtr, 0x04), asset)
                    revert(retOffset, 0x24)
                }
                toConvert := mload(retOffset)

                // compute lockedTokens value slot for asset
                mstore(0, _lockedTokens.slot)
                mstore(0x20, asset)
                slot := keccak256(0, 0x40)
                toConvert := add(toConvert, sload(slot))
                // if the asset is the wrapped native, add the native balance
                if eq(_wrappedNative, asset) {
                    // if the vault processes native deposits, make sure to exclude msg.value
                    switch iszero(_isNativeDeposit)
                    case 1 {
                        toConvert := add(toConvert, selfbalance())
                    }
                    default {
                        toConvert := add(
                            toConvert,
                            sub(selfbalance(), callvalue())
                        )
                    }
                }
            }
            // convert to underlying
            // this function will use new free mem ptr
            _totalAssets += MoreVaultsLib.convertToUnderlying(
                asset,
                toConvert,
                Math.Rounding.Floor
            );
            unchecked {
                ++i;
            }
        }
    }

    function _accountFacets(
        bytes32[] storage _selectors,
        uint256 _totalAssets,
        uint256 _freePtr
    ) private view returns (uint256 totalAssets_) {
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
            for {
                let i := 0
            } lt(i, length) {
                i := add(i, 1)
            } {
                // read facet selector and execute staticcall
                let selector := sload(add(slot, i))
                mstore(_freePtr, selector)
                let res := staticcall(
                    gas(),
                    address(),
                    _freePtr,
                    4,
                    retOffset,
                    0x40
                )
                // if staticcall fails, revert with the error
                if iszero(res) {
                    mstore(_freePtr, ACCOUNTING_FAILED_ERROR)
                    mstore(add(_freePtr, 0x04), selector)
                    revert(_freePtr, 0x24)
                }
                // decode return values
                let decodedAmount := mload(retOffset)
                let isPositive := mload(add(retOffset, 0x20))
                // if the amount is positive, add it to the total assets else add to debt
                if isPositive {
                    _totalAssets := add(_totalAssets, decodedAmount)
                }
                if iszero(isPositive) {
                    debt := add(debt, decodedAmount)
                }
            }

            // after accounting is done check if total assets are greater than debt
            // else leave totalAssets unassigned as "lower" and "equal" should return 0
            if gt(_totalAssets, debt) {
                totalAssets_ := sub(_totalAssets, debt)
            }
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function totalAssets()
        public
        view
        override(ERC4626Upgradeable, IVaultFacet)
        returns (uint256 _totalAssets)
    {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        // get free mem ptr for efficient calls
        uint256 freePtr;
        assembly {
            freePtr := 0x60
        }
        // account available assets
        _totalAssets = _accountAvailableAssets(
            ds.availableAssets,
            ds.lockedTokens,
            ds.wrappedNative,
            ds.isNativeDeposit,
            freePtr
        );
        // account facets
        _totalAssets = _accountFacets(
            ds.facetsForAccounting,
            _totalAssets,
            freePtr
        );
    }

    /**
     * @notice override maxDeposit to check if the deposit capacity is exceeded
     * @dev Warning: the returned value can be slightly higher since accrued fee are not included.
     */
    function maxDeposit(
        address // receiver
    ) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
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
     * @inheritdoc IVaultFacet
     */
    function lockedTokensAmountOfAsset(
        address asset
    ) external view returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return ds.lockedTokens[asset];
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function getStakingAddresses(
        bytes32 stakingFacetId
    ) external view returns (address[] memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return EnumerableSet.values(ds.stakingAddresses[stakingFacetId]);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function tokensHeld(
        bytes32 tokenId
    ) external view returns (address[] memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return EnumerableSet.values(ds.tokensHeld[tokenId]);
    }

    /**
     * @notice override maxMint to check if the deposit capacity is exceeded
     * @dev Warning: the returned value can be slightly higher since accrued fee are not included.
     */
    function maxMint(
        address // receiver
    ) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        uint256 assetsInVault = totalAssets();
        if (ds.depositCapacity == 0) {
            return type(uint256).max;
        }
        if (assetsInVault > ds.depositCapacity) {
            return 0;
        } else {
            return
                _convertToShares(
                    ds.depositCapacity - assetsInVault,
                    Math.Rounding.Floor
                );
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function getWithdrawalRequest(
        address _owner
    ) public view returns (uint256 shares, uint256 timelockEndsAt) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[
            _owner
        ];

        return (request.shares, request.timelockEndsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function getWithdrawalTimelock() external view returns (uint64) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return ds.timelockDuration;
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function setWithdrawalTimelock(uint64 _duration) external {
        AccessControlLib.validateCurator(msg.sender); // TODO: only owner can set timelock
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        ds.timelockDuration = _duration;
        // TODO: add timelock to change timelock duration
        emit WithdrawalTimelockSet(_duration);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function clearRequest() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[
            msg.sender
        ];

        delete request.shares;
        delete request.timelockEndsAt;

        emit WithdrawRequestDeleted(msg.sender);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function requestRedeem(uint256 _shares) external {
        MoreVaultsLib.validateMulticall();
        if (_shares == 0) {
            revert InvalidSharesAmount();
        }

        uint256 maxRedeem_ = maxRedeem(msg.sender);
        if (_shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(msg.sender, _shares, maxRedeem_);
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[
            msg.sender
        ];
        request.shares = _shares;
        uint256 endsAt = block.timestamp + ds.timelockDuration;
        request.timelockEndsAt = endsAt;

        emit WithdrawRequestCreated(msg.sender, _shares, endsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function requestWithdraw(uint256 _assets) external {
        MoreVaultsLib.validateMulticall();
        if (_assets == 0) {
            revert InvalidAssetsAmount();
        }

        uint256 newTotalAssets = _accrueInterest();

        uint256 shares = _convertToSharesWithTotals(
            _assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );

        if (shares == 0) {
            revert InvalidSharesAmount();
        }

        uint256 maxRedeem_ = maxRedeem(msg.sender);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxRedeem_);
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[
            msg.sender
        ];

        request.shares = shares;

        uint256 endsAt = block.timestamp + ds.timelockDuration;
        request.timelockEndsAt = endsAt;

        emit WithdrawRequestCreated(msg.sender, shares, endsAt);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 shares)
    {
        MoreVaultsLib.validateMulticall();
        uint256 newTotalAssets = _accrueInterest();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }
        _validateCapacity(receiver, newTotalAssets, assets);

        ds.lastTotalAssets = newTotalAssets;

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function mint(
        uint256 shares,
        address receiver
    )
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 assets)
    {
        MoreVaultsLib.validateMulticall();
        uint256 newTotalAssets = _accrueInterest();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        ds.lastTotalAssets = newTotalAssets;

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );
        _validateCapacity(receiver, newTotalAssets, assets);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 shares)
    {
        MoreVaultsLib.validateMulticall();
        uint256 newTotalAssets = _accrueInterest();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );

        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        ds.lastTotalAssets = newTotalAssets > assets
            ? newTotalAssets - assets
            : 0;

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        emit WithdrawRequestFulfilled(owner, receiver, shares, assets);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        virtual
        override(ERC4626Upgradeable, IVaultFacet)
        whenNotPaused
        returns (uint256 assets)
    {
        MoreVaultsLib.validateMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }
        bool isWithdrawable = MoreVaultsLib.withdrawFromRequest(owner, shares);

        if (!isWithdrawable) {
            revert CantProcessWithdrawRequest();
        }

        uint256 maxRedeem_ = maxRedeem(owner);
        if (shares > maxRedeem_) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem_);
        }

        uint256 newTotalAssets = _accrueInterest();

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );

        ds.lastTotalAssets = newTotalAssets > assets
            ? newTotalAssets - assets
            : 0;

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        emit WithdrawRequestFulfilled(owner, receiver, shares, assets);
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function deposit(
        address[] calldata tokens,
        uint256[] calldata assets,
        address receiver
    ) external payable whenNotPaused returns (uint256 shares) {
        MoreVaultsLib.validateMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }
        if (msg.value > 0) {
            ds.isNativeDeposit = true;
        }
        uint256 newTotalAssets = _accrueInterest();

        ds.lastTotalAssets = newTotalAssets;

        if (assets.length != tokens.length)
            revert ArraysLengthsDontMatch(tokens.length, assets.length);

        uint256 totalConvertedAmount;
        for (uint i; i < tokens.length; ) {
            MoreVaultsLib.validateAssetDepositable(tokens[i]);
            totalConvertedAmount += MoreVaultsLib.convertToUnderlying(
                tokens[i],
                assets[i],
                Math.Rounding.Floor
            );
            unchecked {
                ++i;
            }
        }
        if (msg.value > 0) {
            MoreVaultsLib.validateAssetDepositable(ds.wrappedNative);
            totalConvertedAmount += MoreVaultsLib.convertToUnderlying(
                ds.wrappedNative,
                msg.value,
                Math.Rounding.Floor
            );
        }

        _validateCapacity(receiver, newTotalAssets, totalConvertedAmount);

        shares = _convertToSharesWithTotals(
            totalConvertedAmount,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );
        _deposit(_msgSender(), receiver, tokens, assets, shares);

        ds.lastTotalAssets = ds.lastTotalAssets + totalConvertedAmount;
        if (ds.isNativeDeposit) {
            ds.isNativeDeposit = false;
        }
    }

    /**
     * @inheritdoc IVaultFacet
     */
    function setFee(uint96 _fee) external {
        AccessControlLib.validateOwner(msg.sender);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isHub) {
            revert NotAHub();
        }
        uint256 newTotalAssets = _accrueInterest();

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
        return
            assets.mulDiv(
                newTotalSupply + 10 ** _decimalsOffset(),
                newTotalAssets + 1,
                rounding
            );
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
        return
            shares.mulDiv(
                newTotalAssets + 1,
                newTotalSupply + 10 ** _decimalsOffset(),
                rounding
            );
    }

    /**
     * @notice Deposit assets to the vault
     * @dev Deposit assets to the vault and mint the shares
     * @param caller The address of the caller
     * @param receiver The address of the receiver
     * @param assets The assets to deposit
     * @param shares The shares to mint
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        super._deposit(caller, receiver, assets, shares);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
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
        for (uint i; i < assets.length; ) {
            SafeERC20.safeTransferFrom(
                IERC20(tokens[i]),
                caller,
                address(this),
                assets[i]
            );
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
     * @return newTotalAssets The new total assets of the vault
     */
    function _accrueInterest() internal returns (uint256 newTotalAssets) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        _beforeAccounting(ds.beforeAccountingFacets);

        uint256 feeShares;
        (feeShares, newTotalAssets) = _accruedFeeShares();
        _checkVaultHealth(newTotalAssets, totalSupply());

        AccessControlLib.AccessControlStorage storage acs = AccessControlLib
            .accessControlStorage();

        ds.lastTotalAssets = newTotalAssets;

        (
            address protocolFeeRecipient,
            uint96 protocolFee
        ) = IMoreVaultsRegistry(acs.moreVaultsRegistry).protocolFeeInfo(
                address(this)
            );

        emit AccrueInterest(newTotalAssets, feeShares);

        if (feeShares == 0) return newTotalAssets;

        if (protocolFee != 0) {
            uint256 protocolFeeShares = feeShares.mulDiv(
                protocolFee,
                MoreVaultsLib.FEE_BASIS_POINT
            );
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
     * @return feeShares The fee shares
     * @return newTotalAssets The new total assets of the vault
     */
    function _accruedFeeShares()
        internal
        view
        returns (uint256 feeShares, uint256 newTotalAssets)
    {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        newTotalAssets = totalAssets();

        uint256 lastTotalAssets = ds.lastTotalAssets;
        uint256 totalInterest = newTotalAssets > lastTotalAssets
            ? newTotalAssets - lastTotalAssets
            : 0;

        uint96 fee = ds.fee;
        if (totalInterest != 0 && fee != 0) {
            uint256 feeAssets = totalInterest.mulDiv(
                fee,
                MoreVaultsLib.FEE_BASIS_POINT
            );
            feeShares = feeAssets.mulDiv(
                totalSupply() + 10 ** _decimalsOffset(),
                newTotalAssets - feeAssets,
                Math.Rounding.Floor
            );
        }
    }

    /**
     * @notice Validate the capacity of the vault
     * @dev If the deposit capacity is 0, the vault is not limited by the deposit capacity
     * @param receiver The address of the receiver
     * @param newTotalAssets The total assets of the vault
     * @param newAssets The assets to deposit
     */
    function _validateCapacity(
        address receiver,
        uint256 newTotalAssets,
        uint256 newAssets
    ) internal view {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        if (ds.isWhitelistEnabled) {
            uint256 userDepositedAssets = _convertToAssetsWithTotals(
                balanceOf(receiver),
                totalSupply(),
                newTotalAssets,
                Math.Rounding.Ceil
            );
            if (
                ds.depositWhitelist[receiver] < userDepositedAssets + newAssets
            ) {
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
    function _checkVaultHealth(
        uint256 _totalAssets,
        uint256 _totalSupply
    ) internal pure {
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
}
