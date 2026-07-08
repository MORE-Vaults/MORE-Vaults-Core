// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IProtocolAdapter
 * @notice Stateless staking module executed by StakingFacet via delegatecall
 * @dev View functions are called with a normal staticcall to the module address.
 *      Execution functions (`stake`, `requestUnstake`, `finalizeUnstake`, `recoverStrandedWithdrawals`,
 *      `harvest`) are
 *      delegatecalled into the vault context and MUST NOT read or write persistent storage.
 *      Only constants/immutables and external calls are allowed in execution paths.
 *      Position accounting is exposed through view functions that read on-chain protocol state.
 *      `getAccountingDepositValue` returns the deposit-token value locked in the protocol that is
 *      not already counted via vault availableAssets. Withdrawal readiness is defined solely by
 *      `isWithdrawalClaimable`; `getWithdrawalClaimableAt` is informational and may be dynamic.
 *      `isWithdrawalCompleted` tracks protocol-side auto-settlement. `finalizeUnstake` must be
 *      idempotent: claim when needed and return the native amount received; return 0 when
 *      `isWithdrawalCompleted` is true (funds already on the vault). Adapter-specific `params`
 *      on finalize (e.g. Lido checkpoint hint) may be empty to use protocol defaults.
 *      Modules are audited and whitelisted in the registry before use.
 */
interface IProtocolAdapter {
    function depositToken() external view returns (address);

    function receiptToken() external view returns (address);

    /// @notice Receipt balance currently held on the vault wallet
    function getStakedReceipts(address vault) external view returns (uint256);

    /// @notice Receipt amount in protocol pending unstake (not on vault wallet)
    function getPendingUnstake(address vault) external view returns (uint256);

    /// @notice Receipt amount available to request unstake from the vault wallet
    function getUnstakeableReceipts(address vault) external view returns (uint256);

    /// @notice Deposit-token value to include in staking facet accounting
    /// @param vault The vault address
    /// @param receiptIsAvailableAsset True when receiptToken is in vault availableAssets
    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount);

    function stake(uint256 amount, bytes calldata params) external returns (uint256 receipts);

    function requestUnstake(uint256 receipts, bytes calldata params)
        external
        returns (bytes32 requestId, uint256 actualReceipts);

    function finalizeUnstake(bytes32 requestId, bytes calldata params) external returns (uint256 amount);

    /// @notice Recover native deposit-token refunds stranded in a protocol bucket without a matching
    ///         facet withdrawal request. Adapter-specific; see module natspec. Draining a shared bucket
    ///         here does not finalize facet requests — follow with `finalizeUnstake` per open request.
    /// @param params Adapter-specific recovery options. Unused by current implementations.
    function recoverStrandedWithdrawals(bytes calldata params) external returns (uint256 amount);

    /// @notice Claim staking rewards to the vault. Side-effect only; accounting reads wallet balances.
    function harvest() external;

    /// @notice Whether the protocol allows claiming this withdrawal request right now
    function isWithdrawalClaimable(address vault, bytes32 requestId) external view returns (bool);

    /// @notice Whether the protocol already delivered funds for this request (e.g. auto-settle)
    function isWithdrawalCompleted(address vault, bytes32 requestId) external view returns (bool);

    /// @notice Earliest expected claim timestamp from protocol state. May be 0 if unknown or dynamic.
    function getWithdrawalClaimableAt(address vault, bytes32 requestId) external view returns (uint256);

    /// @notice Whether the protocol currently blocks new unstake requests for this vault.
    /// @dev Adapter-specific gate (e.g. outstanding withdrawal workflow). Returns false when unstake is allowed.
    function isUnstakeBlocked(address vault) external view returns (bool);

    function getProtocolName() external pure returns (string memory);
}
