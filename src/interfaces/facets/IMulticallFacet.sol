// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IMulticallFacet
 * @notice Interface for MulticallFacet that allows batching multiple calls into a single transaction
 */
interface IMulticallFacet is IGenericMoreVaultFacetInitializable {
    error ActionsStillPending(uint256 actionsNonce);
    error MulticallFailed(uint256 index, bytes reason);
    error NoSuchActions(uint256 actionsNonce);
    error EmptyActions();

    /**
     * @dev Emitted when new actions sequence is submitted
     * @param curator Address of curator who submitted actions
     * @param nonce Nonce of submitted actions sequence
     * @param pendingUntil Timestamp until which actions are pending
     * @param actionsData Array of encoded function calls
     */
    event ActionsSubmitted(
        address indexed curator,
        uint256 indexed nonce,
        uint256 pendingUntil,
        bytes[] actionsData
    );

    /**
     * @dev Emitted when actions sequence is vetoed by guardian
     * @param guardian Address of guardian who vetoed
     * @param actionsNonce Nonce of vetoed actions sequence
     */
    event ActionsVetoed(address indexed guardian, uint256 indexed actionsNonce);

    /**
     * @dev Emitted when actions sequence is executed
     * @param executor Address that executed the sequence
     * @param actionsNonce Nonce of executed actions sequence
     */
    event ActionsExecuted(
        address indexed executor,
        uint256 indexed actionsNonce
    );

    /**
     * @notice Submit new sequence of actions for time-locked execution
     * @param actionsData Array of encoded function calls
     * @return nonce Nonce assigned to this sequence
     */
    function submitActions(
        bytes[] calldata actionsData
    ) external returns (uint256 nonce);

    /**
     * @notice Execute pending sequence of actions after time lock period
     * @param actionsNonce Nonce of actions sequence to execute
     */
    function executeActions(uint256 actionsNonce) external;

    /**
     * @notice Veto (cancel) pending sequence of actions
     * @param actionsNonces Array of nonces of actions sequences to veto
     */
    function vetoActions(uint256[] calldata actionsNonces) external;

    /**
     * @notice Get pending actions for given nonce
     * @param actionsNonce Nonce to query
     * @return actionsData Array of encoded function calls
     * @return pendingUntil Timestamp until which actions are pending
     */
    function getPendingActions(
        uint256 actionsNonce
    ) external view returns (bytes[] memory actionsData, uint256 pendingUntil);

    /**
     * @notice Get current actions nonce
     * @return Current nonce value
     */
    function getCurrentNonce() external view returns (uint256);
}
