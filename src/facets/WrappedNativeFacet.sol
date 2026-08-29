// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IWrappedNativeFacet} from "../interfaces/facets/IWrappedNativeFacet.sol";
import {IWrappedToken} from "../interfaces/IWrappedToken.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title WrappedNativeFacet
 * @notice Facet for converting between native balance and wrapped native ERC-20 held by the vault
 * @dev Intended for curator multicall flows, e.g. unwrap WFLOW before staking into native-only protocols
 */
contract WrappedNativeFacet is BaseFacetInitializer, IWrappedNativeFacet {
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.WrappedNativeFacet");
    }

    function facetName() external pure returns (string memory) {
        return "WrappedNativeFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata /* data */) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IWrappedNativeFacet).interfaceId] = true;
    }

    function onFacetRemoval(bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IWrappedNativeFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IWrappedNativeFacet
     */
    function wrapNative(uint256 amount) external {
        AccessControlLib.validateDiamond(msg.sender);
        if (amount == 0) revert ZeroAmount();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        address wrappedNative = ds.wrappedNative;
        if (wrappedNative == address(0)) revert WrappedNativeNotSet();
        MoreVaultsLib.validateAssetAvailable(wrappedNative);

        uint256 nativeBalance = address(this).balance;
        if (nativeBalance < amount) {
            revert InsufficientNativeBalance(amount, nativeBalance);
        }

        uint256 wrappedBefore = IERC20(wrappedNative).balanceOf(address(this));
        IWrappedToken(wrappedNative).deposit{value: amount}();
        uint256 wrappedAfter = IERC20(wrappedNative).balanceOf(address(this));

        if (wrappedAfter - wrappedBefore != amount) revert WrapFailed();

        emit NativeWrapped(wrappedNative, amount);
    }

    /**
     * @inheritdoc IWrappedNativeFacet
     */
    function unwrapNative(uint256 amount) external {
        AccessControlLib.validateDiamond(msg.sender);
        if (amount == 0) revert ZeroAmount();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        address wrappedNative = ds.wrappedNative;
        if (wrappedNative == address(0)) revert WrappedNativeNotSet();
        MoreVaultsLib.validateAssetAvailable(wrappedNative);

        uint256 wrappedBalance = IERC20(wrappedNative).balanceOf(address(this));
        if (wrappedBalance < amount) {
            revert InsufficientWrappedBalance(amount, wrappedBalance);
        }

        uint256 nativeBefore = address(this).balance;
        IWrappedToken(wrappedNative).withdraw(amount);
        uint256 nativeAfter = address(this).balance;

        if (nativeAfter - nativeBefore != amount) revert UnwrapFailed();

        emit NativeUnwrapped(wrappedNative, amount);
    }
}
