// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IWrappedNativeFacet
 * @notice Interface for wrapping and unwrapping the vault's configured native token
 * @dev Converts between native balance held by the vault and its wrapped ERC-20 representation
 */
interface IWrappedNativeFacet is IGenericMoreVaultFacetInitializable {
    error ZeroAmount();
    error WrappedNativeNotSet();
    error InsufficientNativeBalance(uint256 requested, uint256 available);
    error InsufficientWrappedBalance(uint256 requested, uint256 available);
    error WrapFailed();
    error UnwrapFailed();

    event NativeWrapped(address indexed wrappedNative, uint256 amount);
    event NativeUnwrapped(address indexed wrappedNative, uint256 amount);

    /**
     * @notice Wrap native tokens into the vault's wrapped native ERC-20
     * @dev Only callable from within the diamond (via multicall)
     * @param amount Amount of native tokens to wrap
     */
    function wrapNative(uint256 amount) external;

    /**
     * @notice Unwrap wrapped native ERC-20 into native tokens
     * @dev Only callable from within the diamond (via multicall)
     * @param amount Amount of wrapped tokens to unwrap
     */
    function unwrapNative(uint256 amount) external;
}
