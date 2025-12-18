// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlLib} from "./AccessControlLib.sol";
import {IDiamondCut} from "../interfaces/facets/IDiamondCut.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {IAggregatorV2V3Interface} from "../interfaces/Chainlink/IAggregatorV2V3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {
    IGenericMoreVaultFacet,
    IGenericMoreVaultFacetInitializable
} from "../interfaces/facets/IGenericMoreVaultFacetInitializable.sol";

bytes32 constant BEFORE_ACCOUNTING_SELECTOR = 0xa85367f800000000000000000000000000000000000000000000000000000000;
bytes32 constant BEFORE_ACCOUNTING_FAILED_ERROR = 0xc5361f8d00000000000000000000000000000000000000000000000000000000;
bytes32 constant ACCOUNTING_FAILED_ERROR = 0x712f778400000000000000000000000000000000000000000000000000000000;
bytes32 constant BALANCE_OF_SELECTOR = 0x70a0823100000000000000000000000000000000000000000000000000000000;
bytes32 constant TOTAL_ASSETS_SELECTOR = 0x01e1d11400000000000000000000000000000000000000000000000000000000;
bytes32 constant TOTAL_ASSETS_RUN_FAILED = 0xb5a7047700000000000000000000000000000000000000000000000000000000;

library MoreVaultsLib {
    error InitializationFunctionReverted(address _initializationContractAddress, bytes _calldata);
    error UnsupportedAsset(address);
    error FacetNotAllowed(address facet);
    error SelectorNotAllowed(bytes4 selector);
    error InvalidSelectorForFacet(bytes4 selector, address facet);
    error IncorrectFacetCutAction(uint8 action);
    error ContractDoesntHaveCode(string errorMessage);
    error ZeroAddress();
    error ImmutableFunction();
    error FunctionDoesNotExist();
    error NoSelectorsInFacetToCut();
    error FunctionAlreadyExists(address oldFacetAddress, bytes4 selector);
    error OraclePriceIsOld();
    error OraclePriceIsNegative();
    error InvalidFee();
    error AssetAlreadyAvailable();
    error InvalidAddress();
    error NoOracleForAsset();
    error FacetHasBalance(uint256 amount);
    error AccountingFailed(bytes32 selector);
    error UnsupportedProtocol(address protocol);
    error AccountingGasLimitExceeded(uint256 limit, uint256 consumption);
    error RestrictedActionInsideMulticall();
    error OnFacetRemovalFailed(address facet, bytes data);
    error FacetNameFailed(address facet);

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;

    // 32 bytes keccak hash of a string to use as a diamond storage location.
    bytes32 constant MORE_VAULTS_STORAGE_POSITION = keccak256("MoreVaults.diamond.storage");

    uint96 constant FEE_BASIS_POINT = 10000; // 100%

    uint96 constant MAX_FEE = 5000; // 50%

    struct ERC4626Storage {
        IERC20 _asset;
        uint8 _underlyingDecimals;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant ERC4626StorageLocation = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in facetFunctionSelectors.functionSelectors array
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in facetAddresses array
    }

    struct PendingActions {
        bytes[] actionsData;
        uint256 pendingUntil;
    }

    struct GasLimit {
        uint48 availableTokenAccountingGas;
        uint48 heldTokenAccountingGas;
        uint48 facetAccountingGas;
        uint48 stakingTokenAccountingGas;
        uint48 nestedVaultsGas;
        uint48 value;
    }

    struct WithdrawRequest {
        uint256 timelockEndsAt;
        uint256 shares;
    }

    enum TokenType {
        HeldToken,
        StakingToken
    }

    enum ActionType {
        DEPOSIT,
        MINT,
        WITHDRAW,
        REDEEM,
        MULTI_ASSETS_DEPOSIT
    }

    struct CrossChainRequestInfo {
        address initiator;
        uint64 timestamp;
        ActionType actionType;
        bytes actionCallData;
        bool fulfilled;
        bool finalized;
        uint256 totalAssets;
        uint256 finalizationResult;
        uint256 minAmountOut; // Minimum expected result amount for slippage check (0 = check not required)
    }

    struct MoreVaultsStorage {
        // maps function selector to the facet address and
        // the position of the selector in the facetFunctionSelectors.selectors array
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        // maps facet addresses to function selectors
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        // facet addresses
        address[] facetAddresses;
        bytes32[] facetsForAccounting;
        // Used to query if a contract implements an interface.
        // Used to implement ERC-165.
        mapping(bytes4 => bool) supportedInterfaces;
        mapping(address => bool) isAssetAvailable;
        address[] availableAssets;
        mapping(address => bool) isAssetDepositable;
        mapping(bytes32 => EnumerableSet.AddressSet) tokensHeld;
        address wrappedNative;
        address feeRecipient;
        uint96 fee;
        uint256 depositCapacity;
        uint256 lastTotalAssets;
        uint256 actionNonce;
        mapping(uint256 => PendingActions) pendingActions;
        uint256 timeLockPeriod;
        mapping(bytes32 => EnumerableSet.AddressSet) stakingAddresses;
        mapping(address => uint256) lockedTokens;
        address minter;
        bool isNativeDeposit;
        address[] beforeAccountingFacets;
        mapping(address => address) stakingTokenToGauge;
        mapping(address => address) stakingTokenToMultiRewards;
        GasLimit gasLimit;
        mapping(TokenType => EnumerableSet.Bytes32Set) vaultExternalAssets;
        uint64 witdrawTimelock;
        mapping(address => WithdrawRequest) withdrawalRequests;
        uint256 maxSlippagePercent;
        bool isMulticall;
        address factory;
        mapping(address => uint256) curvePoolLength;
        mapping(address => uint256) availableToDeposit;
        mapping(address => bool) isNecessaryToCheckLock;
        bool isWhitelistEnabled;
        address[] depositableAssets;
        bool isHub;
        bool oraclesCrossChainAccounting;
        address crossChainAccountingManager;
        mapping(bytes32 => CrossChainRequestInfo) guidToCrossChainRequestInfo;
        bytes32 finalizationGuid;
        bool isWithdrawalQueueEnabled;
        uint96 withdrawalFee;
        mapping(address => uint256) userHighWaterMarkPerShare;
        uint256 pendingNative;
        uint32 maxWithdrawalDelay;
        /// @dev Locked tokens per external contract per token address
        /// For deposits: lockedTokensPerContract[vault][asset] = amount
        /// For redeems: lockedTokensPerContract[vault][shareToken] = shares
        mapping(address contract_ => mapping(address token => uint256)) lockedTokensPerContract;
        mapping(address => uint256) initialDepositCapPerUser;
    }

    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut);
    event FeeSet(uint96 previousFee, uint96 newFee);
    event FeeRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event AssetToManageAdded(address indexed asset);
    event AssetToDepositEnabled(address indexed asset);
    event AssetToDepositDisabled(address indexed asset);
    event TimeLockPeriodSet(uint256 previousPeriod, uint256 newPeriod);
    event DepositCapacitySet(uint256 previousCapacity, uint256 newCapacity);

    function moreVaultsStorage() internal pure returns (MoreVaultsStorage storage ds) {
        bytes32 position = MORE_VAULTS_STORAGE_POSITION;
        // assigns struct storage slot to the storage position
        assembly {
            ds.slot := position
        }
    }

    function getERC4626Storage() internal pure returns (ERC4626Storage storage $) {
        assembly {
            $.slot := ERC4626StorageLocation
        }
    }

    function validateAddressWhitelisted(address protocol) internal view {
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        if (!IMoreVaultsRegistry(acs.moreVaultsRegistry).isWhitelisted(protocol)) revert UnsupportedProtocol(protocol);
    }

    function validateAssetAvailable(address asset) internal view {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (asset == address(0)) asset = ds.wrappedNative;
        if (!ds.isAssetAvailable[asset]) revert UnsupportedAsset(asset);
    }

    function validateAssetDepositable(address asset) internal view {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (asset == address(0)) asset = ds.wrappedNative;
        if (!ds.isAssetDepositable[asset]) revert UnsupportedAsset(asset);
    }

    function validateNotMulticall() internal view {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (ds.isMulticall) {
            revert RestrictedActionInsideMulticall();
        }
    }

    function removeTokenIfnecessary(EnumerableSet.AddressSet storage tokensHeld, address token) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (IERC20(token).balanceOf(address(this)) + ds.lockedTokens[token] < 10e3) {
            tokensHeld.remove(token);
        }
    }

    function convertToUnderlying(address _token, uint256 amount, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;

        // Scope 1: Token validation and setup
        address resolvedToken;
        address underlyingToken;
        {
            MoreVaultsStorage storage ds = moreVaultsStorage();
            resolvedToken = _token == address(0) ? address(ds.wrappedNative) : _token;
            underlyingToken = address(getERC4626Storage()._asset);

            if (resolvedToken == underlyingToken) {
                return amount;
            }
        }

        // Scope 2: Oracle setup and input token price
        uint256 inputTokenPrice;
        uint8 inputTokenOracleDecimals;
        address oracleDenominationAsset;
        {
            IMoreVaultsRegistry registry = IMoreVaultsRegistry(AccessControlLib.vaultRegistry());
            IOracleRegistry oracle = registry.oracle();
            oracleDenominationAsset = registry.getDenominationAsset();

            IAggregatorV2V3Interface aggregator =
                IAggregatorV2V3Interface(oracle.getOracleInfo(resolvedToken).aggregator);
            inputTokenPrice = oracle.getAssetPrice(resolvedToken);
            inputTokenOracleDecimals = aggregator.decimals();
        }

        // Scope 3: Price conversion calculation
        uint256 finalPriceForConversion = inputTokenPrice;
        if (underlyingToken != oracleDenominationAsset) {
            IMoreVaultsRegistry registry = IMoreVaultsRegistry(AccessControlLib.vaultRegistry());
            IOracleRegistry oracle = registry.oracle();

            IAggregatorV2V3Interface aggregator =
                IAggregatorV2V3Interface(oracle.getOracleInfo(underlyingToken).aggregator);
            uint256 underlyingTokenPrice = oracle.getAssetPrice(underlyingToken);
            uint8 underlyingTokenOracleDecimals = aggregator.decimals();

            finalPriceForConversion =
                inputTokenPrice.mulDiv(10 ** underlyingTokenOracleDecimals, underlyingTokenPrice, rounding);
        }

        // Final conversion calculation
        return amount.mulDiv(
            finalPriceForConversion * 10 ** IERC20Metadata(underlyingToken).decimals(),
            10 ** (inputTokenOracleDecimals + IERC20Metadata(resolvedToken).decimals()),
            rounding
        );
    }

    function convertUnderlyingToUsd(uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        IOracleRegistry oracle = IMoreVaultsRegistry(AccessControlLib.vaultRegistry()).oracle();
        address underlyingToken = address(getERC4626Storage()._asset);
        return amount.mulDiv(
            oracle.getAssetPrice(underlyingToken), 10 ** IERC20Metadata(underlyingToken).decimals(), rounding
        );
    }

    function convertUsdToUnderlying(uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        IOracleRegistry oracle = IMoreVaultsRegistry(AccessControlLib.vaultRegistry()).oracle();
        address underlyingToken = address(getERC4626Storage()._asset);
        return amount.mulDiv(
            10 ** IERC20Metadata(underlyingToken).decimals(), oracle.getAssetPrice(underlyingToken), rounding
        );
    }

    function _setFeeRecipient(address recipient) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        address previousRecipient = ds.feeRecipient;
        ds.feeRecipient = recipient;
        emit FeeRecipientSet(previousRecipient, recipient);
    }

    function _setFee(uint96 fee) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        uint96 previousFee = ds.fee;
        if (fee > MAX_FEE) {
            revert InvalidFee();
        }
        ds.fee = fee;

        emit FeeSet(previousFee, fee);
    }

    function _setDepositCapacity(uint256 capacity) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        uint256 previousCapacity = ds.depositCapacity;
        ds.depositCapacity = capacity;

        emit DepositCapacitySet(previousCapacity, capacity);
    }

    function _setDepositWhitelist(address[] calldata depositors, uint256[] calldata underlyingAssetCaps) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        for (uint256 i; i < depositors.length;) {
            // Check if the user was added previously (by checking if initialDepositCapPerUser exists)
            uint256 previousInitialCap = ds.initialDepositCapPerUser[depositors[i]];
            
            // Update initialDepositCapPerUser to the new value
            ds.initialDepositCapPerUser[depositors[i]] = underlyingAssetCaps[i];
            
            // If the user already existed (initialDepositCapPerUser was set previously)
            if (previousInitialCap > 0) {
                // Preserve the current availableToDeposit value, but cap it to the new initialDepositCapPerUser
                // if it exceeds the new limit
                uint256 currentAvailableToDeposit = ds.availableToDeposit[depositors[i]];
                if (currentAvailableToDeposit > underlyingAssetCaps[i]) {
                    ds.availableToDeposit[depositors[i]] = underlyingAssetCaps[i];
                }
                // Otherwise, leave the current availableToDeposit value unchanged
            } else {
                // If the user is new, set both values to be equal
                ds.availableToDeposit[depositors[i]] = underlyingAssetCaps[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _setTimeLockPeriod(uint256 period) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        uint256 previousPeriod = ds.timeLockPeriod;
        ds.timeLockPeriod = period;

        emit TimeLockPeriodSet(previousPeriod, period);
    }

    function _addAvailableAsset(address asset) internal {
        if (asset == address(0)) {
            revert InvalidAddress();
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (ds.isAssetAvailable[asset]) {
            revert AssetAlreadyAvailable();
        }

        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        IMoreVaultsRegistry registry = IMoreVaultsRegistry(acs.moreVaultsRegistry);
        IOracleRegistry oracle = registry.oracle();
        if (address(oracle.getOracleInfo(asset).aggregator) == address(0)) {
            revert NoOracleForAsset();
        }

        ds.isAssetAvailable[asset] = true;
        ds.availableAssets.push(asset);

        emit AssetToManageAdded(asset);
    }

    function _enableAssetToDeposit(address asset) internal {
        if (asset == address(0)) {
            revert InvalidAddress();
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (!ds.isAssetAvailable[asset]) {
            revert UnsupportedAsset(asset);
        }
        if (ds.isAssetDepositable[asset]) {
            revert AssetAlreadyAvailable();
        }
        ds.isAssetDepositable[asset] = true;
        ds.depositableAssets.push(asset);

        emit AssetToDepositEnabled(asset);
    }

    function _disableAssetToDeposit(address asset) internal {
        if (asset == address(0)) {
            revert InvalidAddress();
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (!ds.isAssetDepositable[asset]) {
            revert UnsupportedAsset(asset);
        }

        ds.isAssetDepositable[asset] = false;
        for (uint256 i; i < ds.depositableAssets.length;) {
            if (ds.depositableAssets[i] == asset) {
                ds.depositableAssets[i] = ds.depositableAssets[ds.depositableAssets.length - 1];
                ds.depositableAssets.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        emit AssetToDepositDisabled(asset);
    }

    // Internal function version of diamondCut
    function diamondCut(IDiamondCut.FacetCut[] memory _diamondCut) internal {
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        IMoreVaultsRegistry registry = IMoreVaultsRegistry(acs.moreVaultsRegistry);

        for (uint256 facetIndex; facetIndex < _diamondCut.length;) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            address facetAddress = _diamondCut[facetIndex].facetAddress;

            // Validate facet and selectors for Add and Replace actions
            if (action == IDiamondCut.FacetCutAction.Add || action == IDiamondCut.FacetCutAction.Replace) {
                // Check if facet is allowed in registry
                if (!registry.isPermissionless()) {
                    if (!registry.isFacetAllowed(facetAddress)) {
                        revert FacetNotAllowed(facetAddress);
                    }

                    for (uint256 selectorIndex; selectorIndex < _diamondCut[facetIndex].functionSelectors.length;) {
                        if (
                            registry.selectorToFacet(_diamondCut[facetIndex].functionSelectors[selectorIndex])
                                != facetAddress
                        ) {
                            revert SelectorNotAllowed(_diamondCut[facetIndex].functionSelectors[selectorIndex]);
                        }
                        unchecked {
                            ++selectorIndex;
                        }
                    }
                }
            }

            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
                initializeAfterAddition(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].initData);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
                initializeAfterAddition(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].initData);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert IncorrectFacetCutAction(uint8(action));
            }
            unchecked {
                ++facetIndex;
            }
        }
        emit DiamondCut(_diamondCut);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsInFacetToCut();
        }
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (_facetAddress == address(0)) {
            revert ZeroAddress();
        }
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length;) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress != address(0)) {
                revert FunctionAlreadyExists(oldFacetAddress, selector);
            }
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
            unchecked {
                ++selectorIndex;
            }
        }
        // if factory is not set, then it is deployment of diamond, so link will be done on factory side
        if (factoryAddress() != address(0)) {
            IVaultsFactory(ds.factory).link(_facetAddress);
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsInFacetToCut();
        }
        MoreVaultsStorage storage ds = moreVaultsStorage();
        if (_facetAddress == address(0)) {
            revert ZeroAddress();
        }
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }

        address factory = ds.factory;
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length;) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress == _facetAddress) {
                revert FunctionAlreadyExists(oldFacetAddress, selector);
            }
            removeFunction(ds, oldFacetAddress, selector, true);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
            unchecked {
                ++selectorIndex;
            }
        }
        IVaultsFactory(factory).link(_facetAddress);
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) {
            revert NoSelectorsInFacetToCut();
        }
        MoreVaultsStorage storage ds = moreVaultsStorage();
        // if function does not exist then do nothing and return
        if (_facetAddress != address(0)) {
            revert ZeroAddress();
        }

        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length;) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacetAddress, selector, false);
            unchecked {
                ++selectorIndex;
            }
        }
    }

    function addFacet(MoreVaultsStorage storage ds, address _facetAddress) internal {
        enforceHasContractCode(_facetAddress, "MoreVaultsLibCut: New facet has no code");
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }

    function addFunction(
        MoreVaultsStorage storage ds,
        bytes4 _selector,
        uint96 _selectorPosition,
        address _facetAddress
    ) internal {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    function removeFunction(MoreVaultsStorage storage ds, address _facetAddress, bytes4 _selector, bool _isReplacing)
        internal
    {
        if (_facetAddress == address(0)) {
            revert FunctionDoesNotExist();
        }
        // an immutable function is a function defined directly in a diamond
        if (_facetAddress == address(this)) {
            revert ImmutableFunction();
        }
        // replace selector with last selector, then delete last selector
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        // if not the same then replace _selector with lastSelector
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }

        // if no more selectors for facet address then delete the facet address
        if (lastSelectorPosition == 0) {
            // replace facet address with last facet address and delete last facet address
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            address factory = ds.factory;
            IVaultsFactory(factory).unlink(_facetAddress);

            (bool success, bytes memory result) = address(_facetAddress)
                .delegatecall(
                    abi.encodeWithSelector(
                        bytes4(IGenericMoreVaultFacetInitializable.onFacetRemoval.selector), _isReplacing
                    )
                );
            // revert if onFacetRemoval exists on facet and failed
            if (!success && result.length > 0) {
                revert OnFacetRemovalFailed(_facetAddress, result);
            }
        }

        // delete the last selector
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];
    }

    function initializeAfterAddition(address _facetAddress, bytes memory _initData) internal {
        enforceHasContractCode(_facetAddress, "MoreVaultsLibCut: _facetAddress has no code");

        bytes memory callData =
            abi.encodeWithSelector(IGenericMoreVaultFacetInitializable.initialize.selector, _initData);
        (bool success, bytes memory error) = _facetAddress.delegatecall(callData);
        // 0x0dc149f0 is selector of error AlreadyInitialized()
        if (bytes4(error) == bytes4(hex"0dc149f0")) {
            return;
        }
        if (!success) {
            if (error.length > 0) {
                // bubble up error
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitializationFunctionReverted(_facetAddress, callData);
            }
        }
    }

    function removeFromBeforeAccounting(MoreVaultsStorage storage ds, address _facetAddress, bool _isReplacing)
        internal
    {
        for (uint256 i; i < ds.beforeAccountingFacets.length;) {
            if (ds.beforeAccountingFacets[i] == _facetAddress) {
                if (!_isReplacing) {
                    (bool success,) =
                        address(_facetAddress).delegatecall(abi.encodeWithSelector(bytes4(BEFORE_ACCOUNTING_SELECTOR)));
                    assembly {
                        if iszero(success) {
                            mstore(0x40, BEFORE_ACCOUNTING_FAILED_ERROR)
                            mstore(add(0x40, 0x04), _facetAddress)
                            revert(0x40, 0x24)
                        }
                    }
                }
                ds.beforeAccountingFacets[i] = ds.beforeAccountingFacets[ds.beforeAccountingFacets.length - 1];
                ds.beforeAccountingFacets.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function removeFromFacetsForAccounting(MoreVaultsStorage storage ds, bytes4 selector, bool _isReplacing) internal {
        for (uint256 i; i < ds.facetsForAccounting.length;) {
            if (ds.facetsForAccounting[i] == selector) {
                if (!_isReplacing) {
                    // Skip balance check for accountingBridgeFacet - it reports remote spoke funds,
                    // not local funds, and a failing oracle should not prevent disabling oracle accounting
                    bytes4 accountingBridgeFacetSelector =
                        bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()")));
                    if (selector != accountingBridgeFacetSelector) {
                        (bool success, bytes memory result) = address(this).staticcall(abi.encodeWithSelector(selector));
                        if (!success) {
                            revert AccountingFailed(selector);
                        }
                        uint256 decodedAmount = abi.decode(result, (uint256));
                        if (decodedAmount > 10e4) {
                            revert FacetHasBalance(decodedAmount);
                        }
                    }
                }
                ds.facetsForAccounting[i] = ds.facetsForAccounting[ds.facetsForAccounting.length - 1];
                ds.facetsForAccounting.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if (contractSize == 0) {
            revert ContractDoesntHaveCode(_errorMessage);
        }
    }

    function checkGasLimitOverflow() internal view {
        MoreVaultsStorage storage ds = moreVaultsStorage();

        GasLimit storage gl = ds.gasLimit;

        if (gl.value == 0) return;

        bytes32[] memory stakingIds = ds.vaultExternalAssets[TokenType.StakingToken].values();
        bytes32[] memory heldIds = ds.vaultExternalAssets[TokenType.HeldToken].values();

        uint256 stakingTokensLength;
        for (uint256 i = 0; i < stakingIds.length;) {
            unchecked {
                stakingTokensLength += ds.stakingAddresses[stakingIds[i]].length();
                ++i;
            }
        }

        uint256 tokensHeldLength;
        for (uint256 i = 0; i < heldIds.length;) {
            unchecked {
                tokensHeldLength += ds.tokensHeld[heldIds[i]].length();
                ++i;
            }
        }

        uint256 consumption;
        unchecked {
            consumption = tokensHeldLength * gl.heldTokenAccountingGas + stakingTokensLength
                * gl.stakingTokenAccountingGas + ds.availableAssets.length * gl.availableTokenAccountingGas
                + ds.facetsForAccounting.length * gl.facetAccountingGas + gl.nestedVaultsGas;
        }

        if (consumption > ds.gasLimit.value) {
            revert AccountingGasLimitExceeded(ds.gasLimit.value, consumption);
        }
    }

    function withdrawFromRequest(address _msgSender, address _requester, uint256 _shares) internal returns (bool) {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        WithdrawRequest storage request = ds.withdrawalRequests[_requester];
        // if withdrawal queue is disabled, request can be processed immediately
        if (!ds.isWithdrawalQueueEnabled) {
            // only allow for the shares owner to withdraw in this case
            return _msgSender == _requester;
        }

        if (isWithdrawableRequest(request.timelockEndsAt) && request.shares >= _shares) {
            request.shares -= _shares;
            return true;
        }

        return false;
    }

    function isWithdrawableRequest(uint256 _timelockEndsAt) internal view returns (bool) {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        uint256 maxWithdrawalDelay = ds.maxWithdrawalDelay < 1 days ? 1 days : ds.maxWithdrawalDelay;
        return block.timestamp >= _timelockEndsAt && block.timestamp - _timelockEndsAt <= maxWithdrawalDelay;
    }

    function factoryAddress() internal view returns (address) {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        return ds.factory;
    }

    function _setWhitelistFlag(bool isEnabled) internal {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        ds.isWhitelistEnabled = isEnabled;
    }

    function _beforeAccounting(address[] storage _baf) internal {
        assembly {
            let freePtr := mload(0x40)
            let length := sload(_baf.slot)
            mstore(0, _baf.slot)
            let slot := keccak256(0, 0x20)
            mstore(freePtr, BEFORE_ACCOUNTING_SELECTOR)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
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

    function _getCrossChainAccountingManager() internal view returns (address) {
        MoreVaultsStorage storage ds = moreVaultsStorage();
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        if (ds.crossChainAccountingManager == address(0)) {
            return IMoreVaultsRegistry(acs.moreVaultsRegistry).defaultCrossChainAccountingManager();
        }

        return ds.crossChainAccountingManager;
    }
}
