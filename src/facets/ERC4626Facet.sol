// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626Facet} from "../interfaces/facets/IERC4626Facet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ERC4626Facet
 * @dev Facet for handling ERC4626 vault operations
 * This facet provides functionality for synchronous deposit, withdrawal,
 * mint, and redeem operations on ERC4626-compliant vaults
 */
contract ERC4626Facet is IERC4626Facet, BaseFacetInitializer {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Constant identifier for ERC4626 operations
    bytes32 constant ERC4626_ID = keccak256("ERC4626_ID");

    /// @dev Structs to reduce stack depth in genericAsyncActionExecution
    struct ValidationContext {
        bytes4 selector;
        bool allowed;
        bytes maskForData;
    }

    struct BalanceSnapshot {
        uint256 sharesBefore;
        uint256 assetsBefore;
        uint256 totalSupplyBefore;
        uint256 sharesAfter;
        uint256 assetsAfter;
        uint256 totalSupplyAfter;
        address asset;
    }

    struct ExecutionContext {
        bytes32 diamondAddress;
        bytes fixedData;
        bool success;
        bytes result;
    }

    /**
     * @notice Returns the storage slot for this facet's initializable storage
     * @return bytes32 The storage slot identifier
     */
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.ERC4626FacetV1.0.1");
    }

    /**
     * @notice Returns the name of this facet
     * @return string The facet name
     */
    function facetName() external pure returns (string memory) {
        return "ERC4626Facet";
    }

    /**
     * @notice Returns the version of this facet
     * @return string The facet version
     */
    function facetVersion() external pure returns (string memory) {
        return "1.0.1";
    }

    /**
     * @notice Initializes the ERC4626Facet
     * @param data Encoded data containing the facet selector
     */
    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        bytes32 facetSelector = abi.decode(data, (bytes32));
        ds.facetsForAccounting.push(facetSelector);

        ds.supportedInterfaces[type(IERC4626Facet).interfaceId] = true;
        ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].add(ERC4626_ID);
    }

    /**
     * @notice Handles facet removal and cleanup
     * @param isReplacing Whether the facet is being replaced
     */
    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IERC4626Facet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(ds, IERC4626Facet.accountingERC4626Facet.selector, isReplacing);
        if (!isReplacing) {
            ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].remove(ERC4626_ID);
        }
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function accountingERC4626Facet() public view returns (uint256 sum, bool isPositive) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        for (uint256 i = 0; i < ds.tokensHeld[ERC4626_ID].length();) {
            address vault = ds.tokensHeld[ERC4626_ID].at(i);
            if (ds.isAssetAvailable[vault]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address asset = IERC4626(vault).asset();
            // Shares we hold + shares locked in pending redeem requests
            uint256 sharesBalance = IERC4626(vault).balanceOf(address(this)) + ds.lockedSharesPerVault[vault];
            uint256 convertedToVaultUnderlying = IERC4626(vault).convertToAssets(sharesBalance);
            // Add assets locked in pending deposit requests
            uint256 lockedAssets = ds.lockedAssetsPerVault[vault][asset];
            sum += MoreVaultsLib.convertToUnderlying(asset, convertedToVaultUnderlying + lockedAssets, Math.Rounding.Floor);
            unchecked {
                ++i;
            }
        }
        return (sum, true);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Deposit(address vault, uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        address asset = IERC4626(vault).asset();

        IERC20(asset).forceApprove(vault, assets);
        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        shares = IERC4626(vault).deposit(assets, address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if ((sharesBalanceAfter == sharesBalanceBefore || assetsBalanceAfter == assetsBalanceBefore)) {
            revert AsyncBehaviorProhibited();
        }

        ds.tokensHeld[ERC4626_ID].add(vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Mint(address vault, uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        address asset = IERC4626(vault).asset();

        assets = IERC4626(vault).previewMint(shares);
        IERC20(asset).forceApprove(vault, assets);
        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        assets = IERC4626(vault).mint(shares, address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if ((sharesBalanceAfter == sharesBalanceBefore || assetsBalanceAfter == assetsBalanceBefore)) {
            revert AsyncBehaviorProhibited();
        }

        ds.tokensHeld[ERC4626_ID].add(vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Withdraw(address vault, uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        shares = IERC4626(vault).withdraw(assets, address(this), address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if ((sharesBalanceAfter == sharesBalanceBefore || assetsBalanceAfter == assetsBalanceBefore)) {
            revert AsyncBehaviorProhibited();
        }
        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC4626_ID], vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Redeem(address vault, uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(address(this));
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if ((sharesBalanceAfter == sharesBalanceBefore || assetsBalanceAfter == assetsBalanceBefore)) {
            revert AsyncBehaviorProhibited();
        }
        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC4626_ID], vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function genericAsyncActionExecution(
        address vault,
        uint256 amount,
        bytes calldata data // data for async action execution
    )
        external
    {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();

        ValidationContext memory validation;
        validation.selector = bytes4(data[:4]);
        (validation.allowed, validation.maskForData) =
            IMoreVaultsRegistry(acs.moreVaultsRegistry).selectorInfo(vault, validation.selector);
        if (!validation.allowed) {
            revert SelectorNotAllowed(validation.selector);
        }

        BalanceSnapshot memory balances;
        balances.asset = IERC4626(vault).asset();
        balances.sharesBefore = IERC4626(vault).balanceOf(address(this));
        balances.assetsBefore = IERC20(balances.asset).balanceOf(address(this));
        balances.totalSupplyBefore = IERC4626(vault).totalSupply();

        ExecutionContext memory execution;
        execution.diamondAddress = bytes32(uint256(uint160(address(this))));
        execution.fixedData = _replaceBytesInData(data, validation.maskForData, execution.diamondAddress);

        IERC20(balances.asset).forceApprove(vault, amount);
        (execution.success, execution.result) = vault.call(execution.fixedData);
        if (!execution.success) revert AsyncActionExecutionFailed(execution.result);
        IERC20(balances.asset).forceApprove(vault, 0);

        balances.sharesAfter = IERC4626(vault).balanceOf(address(this));
        balances.assetsAfter = IERC20(balances.asset).balanceOf(address(this));
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        // Case when upon deposit request assets will be transferred to the vault, but shares will not be minted back until request is executed
        if (balances.sharesAfter == balances.sharesBefore && balances.assetsAfter < balances.assetsBefore) {
            ds.lockedTokens[balances.asset] += balances.assetsBefore - balances.assetsAfter;
            return;
        }
        // Case when upon withdrawal request shares will be transferred to the vault, but assets will not be transferred back until request is executed
        if (balances.sharesAfter < balances.sharesBefore && balances.assetsAfter == balances.assetsBefore) {
            ds.lockedTokens[vault] += balances.sharesBefore - balances.sharesAfter;
            return;
        }

        balances.totalSupplyAfter = IERC4626(vault).totalSupply();
        // Case when upon deposit finalization shares will be transferred to the reciever and assets already were locked on request
        if (balances.sharesBefore < balances.sharesAfter && balances.assetsAfter == balances.assetsBefore) {
            // If total supply increased, it means that deposit request was executed, otherwise withdrawal request was cancelled
            if (balances.totalSupplyAfter > balances.totalSupplyBefore) {
                uint256 assetsUnlocked = IERC4626(vault).convertToAssets(balances.sharesAfter - balances.sharesBefore);
                ds.lockedTokens[balances.asset] -= assetsUnlocked;
            } else {
                // Withdrawal cancel: shares returned, unlock only this request's shares
                uint256 sharesReturned = balances.sharesAfter - balances.sharesBefore;
                if (ds.lockedTokens[vault] >= sharesReturned) {
                    ds.lockedTokens[vault] -= sharesReturned;
                } else {
                    ds.lockedTokens[vault] = 0;
                }
            }
            return;
        }
        // Case when upon withdrawal finalization assets will be transferred to the reciever and shares already were locked on request
        if (balances.sharesAfter == balances.sharesBefore && balances.assetsBefore < balances.assetsAfter) {
            // If total supply decreased, it means that withdrawal request was executed, otherwise deposit request was cancelled
            if (balances.totalSupplyBefore > balances.totalSupplyAfter) {
                uint256 sharesUnlocked = IERC4626(vault).convertToShares(balances.assetsAfter - balances.assetsBefore);
                ds.lockedTokens[vault] -= sharesUnlocked;
                MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC4626_ID], vault);
            } else {
                // Deposit cancel: assets returned, unlock only this request's assets
                uint256 assetsReturned = balances.assetsAfter - balances.assetsBefore;
                if (ds.lockedTokens[balances.asset] >= assetsReturned) {
                    ds.lockedTokens[balances.asset] -= assetsReturned;
                } else {
                    ds.lockedTokens[balances.asset] = 0;
                }
            }
            return;
        }
        // Cases for request without locks
        if (
            (balances.sharesAfter == balances.sharesBefore // request was created without locks
                    && balances.assetsAfter == balances.assetsBefore)
                || (balances.sharesAfter > balances.sharesBefore // withdrawal request was finalized without locks
                    && balances.assetsAfter < balances.assetsBefore)
                || (balances.sharesAfter < balances.sharesBefore // deposit request was finalized without locks
                    && balances.assetsAfter > balances.assetsBefore)
        ) {
            return;
        } else {
            revert UnexpectedState();
        }
    }

    /**
     * @notice Helper function to replace part of bytes data with diamond address, to prevent from setting receiver or any other custom address to any address except More Vaults
     * @param data The original data bytes
     * @param mask The mask to use to replace the data
     * @param diamondAddress The diamond address to insert
     * @return bytes The modified data with diamond address
     */
    function _replaceBytesInData(bytes calldata data, bytes memory mask, bytes32 diamondAddress)
        internal
        pure
        returns (bytes memory)
    {
        uint256 lengthOfData = data.length - 4;
        uint256 lengthOfMask = mask.length;

        if (lengthOfData != lengthOfMask) {
            revert InvalidData();
        }

        uint256 partsCount = lengthOfData / 32;

        bytes32[] memory dataParts = new bytes32[](partsCount);
        bytes32[] memory maskParts = new bytes32[](partsCount);
        bytes32[] memory resultParts = new bytes32[](partsCount);

        for (uint256 i = 0; i < partsCount; i++) {
            bytes32 dataPart;
            bytes32 maskPart;
            assembly {
                dataPart := calldataload(add(add(data.offset, mul(32, i)), 4))
                maskPart := mload(add(add(mask, 32), mul(i, 32)))
            }
            dataParts[i] = dataPart;
            maskParts[i] = maskPart;
        }

        for (uint256 i = 0; i < partsCount; i++) {
            if (maskParts[i] != bytes32(0)) {
                resultParts[i] = dataParts[i];
            } else {
                resultParts[i] = diamondAddress;
            }
        }

        bytes memory result = new bytes(lengthOfData + 4);
        assembly {
            let dest := add(result, 32)

            calldatacopy(dest, data.offset, 4)

            let destData := add(dest, 4)
            for { let i := 0 } lt(i, partsCount) { i := add(i, 1) } {
                mstore(add(destData, mul(i, 32)), mload(add(resultParts, add(32, mul(i, 32)))))
            }
        }

        return result;
    }
}
