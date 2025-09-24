// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../../libraries/MoreVaultsLib.sol";
import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IBridgeFacet
 * @dev Interface for the bridge facet providing cross-chain functionality for vaults
 * @notice This interface defines methods for managing cross-chain operations between hub and spoke vaults
 */
interface IBridgeFacet is IGenericMoreVaultFacetInitializable {
    /**
     * @dev Returns the sum of assets from all spoke vaults in USD
     * @return sum Sum of assets from all spoke vaults
     * @return isPositive Flag indicating that the value is positive
     * @notice Used for calculating the total value of assets in cross-chain vault
     */
    function accountingBridgeFacet()
        external
        view
        returns (uint256 sum, bool isPositive);

    /**
     * @dev Enables or disables the use of oracles for cross-chain accounting
     * @param isTrue true to enable oracles, false to disable
     * @notice Only the owner can call this function
     * @notice When enabling, checks for the presence of oracles for all spoke chains
     */
    function setOraclesCrossChainAccounting(bool isTrue) external;

    /**
     * @dev Initiates a request to perform an action in a cross-chain vault
     * @param actionType Type of action to perform (deposit, withdraw, mint, etc.)
     * @param actionCallData Action call data
     * @param extraOptions Additional options for cross-chain transfer
     * @return nonce Unique request number for tracking
     * @notice Function requires gas payment for cross-chain transfer
     * @notice Available only when the contract is not paused
     */
    function initVaultActionRequest(
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        bytes calldata extraOptions
    ) external payable returns (uint64 nonce);

    /**
     * @dev Updates accounting information for a request
     * @param nonce Request number to update
     * @param sumOfSpokesUsdValue Sum of USD value of all spoke vaults
     * @notice Can only be called by the cross-chain accounting manager
     * @notice Updates total assets and marks the request as fulfilled
     */
    function updateAccountingInfoForRequest(
        uint64 nonce,
        uint256 sumOfSpokesUsdValue
    ) external;

    /**
     * @dev Finalizes the execution of a cross-chain request
     * @param nonce Request number to finalize
     * @notice Executes the actual action after receiving all data from spoke vaults
     * @notice Supports various action types: deposit, withdraw, mint, set fee
     * @notice Can only be called after successful accounting information update
     */
    function finalizeRequest(uint64 nonce) external payable;

    /**
     * @dev Returns the request info for a given nonce
     * @param nonce Request number to get info for
     * @return Request info
     */
    function getRequestInfo(
        uint64 nonce
    ) external view returns (MoreVaultsLib.CrossChainRequestInfo memory);
}
