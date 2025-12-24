// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IERC7540Facet
 * @dev Interface for working with asynchronous token operations (ERC7540)
 * ERC7540 is a standard for asynchronous token operations, including
 * creating deposit/withdrawal requests and their execution
 */
interface IERC7540Facet is IGenericMoreVaultFacetInitializable {
    /// @dev Errors
    /// @notice Error thrown when amount is zero
    error ZeroAmount();

    /**
     * @notice Calculates the total accounting for ERC7540 operations
     * @return sum The total sum of underlying assets
     * @return isPositive Whether the sum is positive
     */
    function accountingERC7540Facet() external view returns (uint256, bool);

    /**
     * @notice Creates a deposit request for ERC7540 vault
     * @param vault The address of the vault to deposit into
     * @param assets The amount of assets to deposit
     * @return requestId The unique identifier for the created request
     */
    function erc7540RequestDeposit(address vault, uint256 assets) external returns (uint256 requestId);

    /**
     * @notice Creates a redemption request for ERC7540 vault
     * @param vault The address of the vault to redeem from
     * @param shares The amount of shares to redeem
     * @return requestId The unique identifier for the created request
     */
    function erc7540RequestRedeem(address vault, uint256 shares) external returns (uint256 requestId);

    /**
     * @notice Executes a deposit operation on ERC7540 vault
     * @param vault The address of the vault to deposit into
     * @param assets The amount of assets to deposit
     * @return shares The amount of shares received from the deposit
     */
    function erc7540Deposit(address vault, uint256 assets) external returns (uint256 shares);

    /**
     * @notice Executes a mint operation on ERC7540 vault
     * @param vault The address of the vault to mint shares from
     * @param shares The amount of shares to mint
     * @return assets The amount of assets required for minting
     */
    function erc7540Mint(address vault, uint256 shares) external returns (uint256 assets);

    /**
     * @notice Executes a withdrawal operation on ERC7540 vault
     * @param vault The address of the vault to withdraw from
     * @param assets The amount of assets to withdraw
     * @return shares The amount of shares burned for the withdrawal
     */
    function erc7540Withdraw(address vault, uint256 assets) external returns (uint256 shares);

    /**
     * @notice Executes a redemption operation on ERC7540 vault
     * @param vault The address of the vault to redeem from
     * @param shares The amount of shares to redeem
     * @return assets The amount of assets received from the redemption
     */
    function erc7540Redeem(address vault, uint256 shares) external returns (uint256 assets);
}
