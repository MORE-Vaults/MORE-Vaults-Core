// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IERC4626Facet
 * @dev Interface for working with ERC4626 vault operations
 * ERC4626 is a standard for tokenized vaults that provide yield-bearing tokens
 */
interface IERC4626Facet is IGenericMoreVaultFacetInitializable {
    /// @dev Errors
    /// @notice Error thrown when the selector is not allowed
    error SelectorNotAllowed(bytes4 selector);
    /// @notice Error thrown when async action execution fails
    error AsyncActionExecutionFailed(bytes result);
    /// @notice Error thrown when amount is zero
    error ZeroAmount();
    /// @notice Error thrown when an unexpected state occurs
    error UnexpectedState();
    /// @notice Error thrown when async behavior is prohibited
    error AsyncBehaviorProhibited();
    /// @notice Error thrown when the calldata for generic async action execution is invalid
    error InvalidData();

    /**
     * @notice Calculates the total accounting for ERC4626 operations
     * @return sum The total sum of underlying assets
     * @return isPositive Whether the sum is positive
     */
    function accountingERC4626Facet()
        external
        view
        returns (uint256 sum, bool isPositive);

    /**
     * @notice Deposits assets into an ERC4626 vault, doesn't support async behavior
     * @param vault The address of the vault to deposit into
     * @param assets The amount of assets to deposit
     * @return shares The amount of shares received from the deposit
     */
    function erc4626Deposit(
        address vault,
        uint256 assets
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares from an ERC4626 vault, doesn't support async behavior
     * @param vault The address of the vault to mint shares from
     * @param shares The amount of shares to mint
     * @return assets The amount of assets required for minting
     */
    function erc4626Mint(
        address vault,
        uint256 shares
    ) external returns (uint256 assets);

    /**
     * @notice Withdraws assets from an ERC4626 vault, doesn't support async behavior, only withdrawing MORE Vault's position
     * @param vault The address of the vault to withdraw from
     * @param assets The amount of assets to withdraw
     * @return shares The amount of shares burned for the withdrawal
     */
    function erc4626Withdraw(
        address vault,
        uint256 assets
    ) external returns (uint256 shares);

    /**
     * @notice Redeems shares from an ERC4626 vault, doesn't support async behavior, only redeeming MORE Vault's position
     * @param vault The address of the vault to redeem from
     * @param shares The amount of shares to redeem
     * @return assets The amount of assets received from the redemption
     */
    function erc4626Redeem(
        address vault,
        uint256 shares
    ) external returns (uint256 assets);

    /**
     * @notice Executes a generic async action on a vault that is approved by registry for it
     * @param vault The address of the vault to execute an action on
     * @param data The encoded data for the async action execution
     */
    function genericAsyncActionExecution(
        address vault,
        bytes calldata data
    ) external;
}
