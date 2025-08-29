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

    /**
     * @notice Returns the storage slot for this facet's initializable storage
     * @return bytes32 The storage slot identifier
     */
    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.ERC4626Facet");
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
        return "1.0.0";
    }

    /**
     * @notice Initializes the ERC4626Facet
     * @param data Encoded data containing the facet selector
     */
    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        bytes32 facetSelector = abi.decode(data, (bytes32));
        ds.facetsForAccounting.push(facetSelector);

        ds.supportedInterfaces[type(IERC4626Facet).interfaceId] = true;
        ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].add(
            ERC4626_ID
        );
    }

    /**
     * @notice Handles facet removal and cleanup
     * @param facetAddress The address of the facet being removed
     * @param isReplacing Whether the facet is being replaced
     */
    function onFacetRemoval(address facetAddress, bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IERC4626Facet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds,
            facetAddress,
            isReplacing
        );
        if (!isReplacing) {
            ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].remove(
                ERC4626_ID
            );
        }
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function accountingERC4626Facet()
        public
        view
        returns (uint256 sum, bool isPositive)
    {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        for (uint256 i = 0; i < ds.tokensHeld[ERC4626_ID].length(); ) {
            address vault = ds.tokensHeld[ERC4626_ID].at(i);
            if (ds.isAssetAvailable[vault]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address asset = IERC4626(vault).asset();
            uint256 balance = IERC4626(vault).balanceOf(address(this)) +
                ds.lockedTokens[vault];
            uint256 convertedToVaultUnderlying = IERC4626(vault)
                .convertToAssets(balance);
            sum += MoreVaultsLib.convertToUnderlying(
                asset,
                convertedToVaultUnderlying,
                Math.Rounding.Floor
            );
            unchecked {
                ++i;
            }
        }
        return (sum, true);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Deposit(
        address vault,
        uint256 assets
    ) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        address asset = IERC4626(vault).asset();

        IERC20(asset).forceApprove(vault, assets);
        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        shares = IERC4626(vault).deposit(assets, address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if (
            (sharesBalanceAfter == sharesBalanceBefore ||
                assetsBalanceAfter == assetsBalanceBefore)
        ) {
            revert AsyncBehaviorProhibited();
        }

        ds.tokensHeld[ERC4626_ID].add(vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Mint(
        address vault,
        uint256 shares
    ) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        address asset = IERC4626(vault).asset();

        assets = IERC4626(vault).previewMint(shares);
        IERC20(asset).forceApprove(vault, assets);
        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        assets = IERC4626(vault).mint(shares, address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if (
            (sharesBalanceAfter == sharesBalanceBefore ||
                assetsBalanceAfter == assetsBalanceBefore)
        ) {
            revert AsyncBehaviorProhibited();
        }

        ds.tokensHeld[ERC4626_ID].add(vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Withdraw(
        address vault,
        uint256 assets
    ) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        shares = IERC4626(vault).withdraw(assets, address(this), address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if (
            (sharesBalanceAfter == sharesBalanceBefore ||
                assetsBalanceAfter == assetsBalanceBefore)
        ) {
            revert AsyncBehaviorProhibited();
        }
        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC4626_ID], vault);
    }

    /**
     * @inheritdoc IERC4626Facet
     */
    function erc4626Redeem(
        address vault,
        uint256 shares
    ) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        // If shares balance or assets balance didn't change, it means that action is async and should be executed with genericAsyncActionExecution or ERC7540Facet
        if (
            (sharesBalanceAfter == sharesBalanceBefore ||
                assetsBalanceAfter == assetsBalanceBefore)
        ) {
            revert AsyncBehaviorProhibited();
        }
        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC4626_ID], vault);
    }

    /**
     * @notice Executes generic asynchronous actions on vaults
     * @param vault The address of the vault to execute the action on
     * @param data The encoded data for the async action execution
     */
    function genericAsyncActionExecution(
        address vault,
        bytes calldata data // data for async action execution
    ) external {
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib
            .accessControlStorage();

        bytes4 selector = bytes4(data[:4]);
        (bool allowed, bytes memory maskForData) = IMoreVaultsRegistry(
            acs.moreVaultsRegistry
        ).selectorInfo(vault, selector);
        if (!allowed) {
            revert SelectorNotAllowed(selector);
        }

        // Check if upon request execution, the amount of assets will increase or decrease, to handle possible locks on request step
        uint256 sharesBalanceBefore = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceBefore = IERC20(IERC4626(vault).asset()).balanceOf(
            address(this)
        );
        uint256 totalSupplyBefore = IERC4626(vault).totalSupply();
        address asset = IERC4626(vault).asset();

        IERC20(asset).forceApprove(vault, type(uint256).max);
        bytes32 diamondAddress = bytes32(uint256(uint160(address(this))));
        bytes memory fixedData = _replaceBytesInData(
            data,
            maskForData,
            diamondAddress
        );

        (bool success, bytes memory result) = vault.call(fixedData);
        if (!success) revert AsyncActionExecutionFailed(result);
        IERC20(asset).forceApprove(vault, 0);

        uint256 sharesBalanceAfter = IERC4626(vault).balanceOf(address(this));
        uint256 assetsBalanceAfter = IERC20(asset).balanceOf(address(this));
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        // Case when upon deposit request assets will be transferred to the vault, but shares will not be minted back until request is executed
        if (
            sharesBalanceAfter == sharesBalanceBefore &&
            assetsBalanceAfter < assetsBalanceBefore
        ) {
            ds.lockedTokens[asset] += assetsBalanceBefore - assetsBalanceAfter;
            return;
        }
        // Case when upon withdrawal request shares will be transferred to the vault, but assets will not be transferred back until request is executed
        if (
            sharesBalanceAfter < sharesBalanceBefore &&
            assetsBalanceAfter == assetsBalanceBefore
        ) {
            ds.lockedTokens[vault] += sharesBalanceBefore - sharesBalanceAfter;
            return;
        }

        uint256 totalSupplyAfter = IERC4626(vault).totalSupply();
        // Case when upon deposit finalization shares will be transferred to the reciever and assets already were locked on request
        if (
            sharesBalanceBefore < sharesBalanceAfter &&
            assetsBalanceAfter == assetsBalanceBefore
        ) {
            // If total supply increased, it means that deposit request was executed, otherwise withdrawal request was cancelled
            if (totalSupplyAfter > totalSupplyBefore) {
                ds.lockedTokens[asset] -=
                    sharesBalanceAfter -
                    sharesBalanceBefore;
            } else {
                delete ds.lockedTokens[vault];
            }
            return;
        }
        // Case when upon withdrawal finalization assets will be transferred to the reciever and shares already were locked on request
        if (
            sharesBalanceAfter == sharesBalanceBefore &&
            assetsBalanceBefore < assetsBalanceAfter
        ) {
            // If total supply decreased, it means that withdrawal request was executed, otherwise deposit request was cancelled
            if (totalSupplyBefore > totalSupplyAfter) {
                ds.lockedTokens[vault] -=
                    assetsBalanceAfter -
                    assetsBalanceBefore;
                MoreVaultsLib.removeTokenIfnecessary(
                    ds.tokensHeld[ERC4626_ID],
                    vault
                );
            } else {
                delete ds.lockedTokens[asset];
            }
            return;
        }
        // Cases for request without locks
        if (
            (sharesBalanceAfter == sharesBalanceBefore && // request was created without locks
                assetsBalanceAfter == assetsBalanceBefore) ||
            (sharesBalanceAfter > sharesBalanceBefore && // withdrawal request was finalized without locks
                assetsBalanceAfter < assetsBalanceBefore) ||
            (sharesBalanceAfter < sharesBalanceBefore && // deposit request was finalized without locks
                assetsBalanceAfter > assetsBalanceBefore)
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
    function _replaceBytesInData(
        bytes calldata data,
        bytes memory mask,
        bytes32 diamondAddress
    ) internal pure returns (bytes memory) {
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
            for {
                let i := 0
            } lt(i, partsCount) {
                i := add(i, 1)
            } {
                mstore(
                    add(destData, mul(i, 32)),
                    mload(add(resultParts, add(32, mul(i, 32))))
                )
            }
        }

        return result;
    }
}
