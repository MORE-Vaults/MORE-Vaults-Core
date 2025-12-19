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
    error CrossChainRequestWasntFulfilled(bytes32);
    error InvalidActionType();
    error OnlyCrossChainAccountingManager();
    error RequestWasntFulfilled();
    error FinalizationCallFailed();
    error OracleWasntSetForSpoke(address, uint32);
    error NoOracleForSpoke(uint32);
    error AlreadySet();
    error AccountingViaOracles();
    error AdapterNotAllowed(address);
    error RequestTimedOut();
    error RequestAlreadyFinalized();
    error NotEnoughMsgValueProvided();
    error SlippageExceeded(uint256 amount, uint256 limit);

    /**
     * @dev Returns the sum of assets from all spoke vaults in USD
     * @return sum Sum of assets from all spoke vaults
     * @return isPositive Flag indicating that the value is positive
     * @notice Used for calculating the total value of assets in cross-chain vault
     */
    function accountingBridgeFacet() external view returns (uint256 sum, bool isPositive);

    /**
     * @dev Enables or disables the use of oracles for cross-chain accounting
     * @param isTrue true to enable oracles, false to disable
     * @notice Only the owner can call this function
     * @notice When enabling, checks for the presence of oracles for all spoke chains
     */
    function setOraclesCrossChainAccounting(bool isTrue) external;

    /**
     * @dev Returns whether oracle-based cross-chain accounting is enabled
     * @return true if oracle accounting is enabled, false otherwise
     */
    function oraclesCrossChainAccounting() external view returns (bool);

    /**
     * @dev Quotes the native fee required to initiate cross-chain accounting
     * @param extraOptions Additional options for the cross-chain read (adapter-specific)
     * @return nativeFee The estimated native token fee required
     */
    function quoteAccountingFee(bytes calldata extraOptions) external view returns (uint256 nativeFee);

    /**
     * @dev Executes a cross-chain bridge operation
     * @param adapter Address of the adapter to use
     * @param token Address of the token to bridge
     * @param amount Amount of the token to bridge
     * @param bridgeSpecificParams Bridge-specific parameters
     */
    function executeBridging(address adapter, address token, uint256 amount, bytes calldata bridgeSpecificParams)
        external
        payable;

    /**
     * @dev Initiates a request to perform an action in a cross-chain vault
     * @param actionType Type of action to perform (deposit, withdraw, mint, etc.)
     * @param actionCallData Action call data
     * @param amountLimit Amount limit for slippage protection: minAmountOut for deposits/mints, maxAmountIn for withdraws/redeems (0 = no slippage check)
     * @param extraOptions Additional options for cross-chain transfer
     * @return guid Unique request number for tracking
     * @notice Function requires gas payment for cross-chain transfer
     * @notice Available only when the contract is not paused
     * @notice amountLimit is used for slippage protection for all actions except SET_FEE
     */
    function initVaultActionRequest(
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        uint256 amountLimit,
        bytes calldata extraOptions
    ) external payable returns (bytes32 guid);

    /**
     * @dev Updates accounting information for a request
     * @param guid Request number to update
     * @param sumOfSpokesUsdValue Sum of USD value of all spoke vaults
     * @param readSuccess Flag indicating if the read operation was successful
     * @notice Can only be called by the cross-chain accounting manager
     * @notice Updates total assets and marks the request as fulfilled
     */
    function updateAccountingInfoForRequest(bytes32 guid, uint256 sumOfSpokesUsdValue, bool readSuccess) external;

    /**
     * @dev Executes a cross-chain request action (deposit, mint, withdraw, etc.)
     * @param guid Request number to execute
     * @notice Can only be called by the cross-chain accounting manager
     * @notice Requires the request to be fulfilled
     * @notice Executes the action and performs slippage check
     */
    function executeRequest(bytes32 guid) external;

    /**
     * @dev Refunds the request if necessary
     * @param guid Request number to refund
     * @notice Can only be called by the cross-chain accounting manager
     */
    function refundIfNecessary(bytes32 guid) external;

    /**
     *
     **
     * @dev Returns the request info for a given guid
     * @param guid Request number to get info for
     * @return Request info
     */
    function getRequestInfo(bytes32 guid) external view returns (MoreVaultsLib.CrossChainRequestInfo memory);

    /**
     * @dev Returns the finalization result for a given guid
     * @param guid Request number to get finalization result for
     * @return result The finalization result (e.g., shares amount for deposits)
     */
    function getFinalizationResult(bytes32 guid) external view returns (uint256 result);
}
