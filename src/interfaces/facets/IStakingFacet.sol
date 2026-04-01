// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IStakingFacet
 * @notice Interface for the Flow LST staking facet.
 *
 * Accounting contract: `stakingTotalAssets()` is registered in
 * `ds.facetsForAccounting` during `initialize()`. The vault's
 * `_accountFacets()` calls it via `staticcall(address(), selector, ...)` and
 * expects the ABI-encoded tuple `(uint256 amount, bool isPositive)`.
 *
 * Design decisions:
 * - isPositive is always `true`; staked FLOW is an asset, never a liability.
 * - pendingDeposits are FLOW sitting as native coin in the vault. Because
 *   `_accountAvailableAssets` already counts `selfbalance()` when
 *   `wrappedNative` is in the available-assets list, pendingDeposits must NOT
 *   be included here. Instead, while deposits are queued, the FLOW is locked
 *   out of the available-asset count via `ds.lockedTokens[wrappedNative]`.
 *   When the COA bridges the FLOW to Cadence it clears that lock and bumps
 *   `totalStakedInCadence`. This keeps the total flat across the bridge.
 * - Unstaking requests (7-14 day window): the user's moreFLOW has already been
 *   burned when the redeem is initiated. The amount in transit is tracked in
 *   `stakingTotalAssets()` via `totalStakedInCadence` until the COA calls
 *   `settleWithdrawal()`, at which point native FLOW arrives in the vault and
 *   `totalStakedInCadence` is reduced. No shares exist at that point so the
 *   share price is unaffected; the arriving FLOW is counted by `selfbalance()`.
 */
interface IStakingFacet is IGenericMoreVaultFacetInitializable {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------
    error UnauthorizedCOA();
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event StakedBalanceUpdated(uint256 previousBalance, uint256 newBalance);
    event DepositEnqueued(address indexed sender, uint256 amount);
    event DepositBridged(uint256 amount);
    event WithdrawalSettled(address indexed user, uint256 amount);

    // -------------------------------------------------------------------------
    // Accounting hook — registered in facetsForAccounting
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the staked balance as seen by the vault's accounting engine.
     * @return amount   Total FLOW currently staked in Cadence (canonical, set by COA each epoch).
     * @return isPositive Always `true`; staked FLOW is a vault asset.
     *
     * Called via `staticcall(address(), selector, <4 bytes>, retOffset, 0x40)`
     * from within `_accountFacets()`. Must not revert under normal conditions.
     */
    function stakingTotalAssets() external view returns (uint256 amount, bool isPositive);

    // -------------------------------------------------------------------------
    // COA-only write functions
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the canonical staked balance after each Cadence epoch.
     * @dev    Only callable by `authorizedCOA`. Increasing this value means
     *         rewards have accrued; the share price rises because `totalAssets`
     *         grows while `totalSupply` is unchanged.
     * @param newBalance New total FLOW staked in Cadence (including accrued rewards).
     */
    function updateStakedBalance(uint256 newBalance) external;

    /**
     * @notice Bridges queued deposits to Cadence and increases `totalStakedInCadence`.
     * @dev    Must clear `ds.lockedTokens[wrappedNative]` for the bridged amount
     *         so `_accountAvailableAssets` stops counting it via `selfbalance()`,
     *         and simultaneously add that amount to `totalStakedInCadence` so
     *         `stakingTotalAssets()` picks it up. Net effect on `totalAssets` = 0.
     * @param amount Amount of FLOW being bridged (must equal what is in pendingDeposits).
     */
    function bridgeDeposits(uint256 amount) external;

    /**
     * @notice Called by the COA when unstaked FLOW has arrived back on EVM.
     * @dev    Reduces `totalStakedInCadence` by `amount`. The native FLOW
     *         balance rises by the same amount so `selfbalance()` picks it up.
     *         Net effect on `totalAssets` = 0.
     * @param user   The user whose withdrawal is being settled.
     * @param amount The FLOW amount returned from Cadence.
     */
    function settleWithdrawal(address user, uint256 amount) external;

    // -------------------------------------------------------------------------
    // User-facing
    // -------------------------------------------------------------------------

    /**
     * @notice Accepts native FLOW and enqueues it for bridging to Cadence.
     * @dev    The deposited FLOW stays as `selfbalance()` until `bridgeDeposits`
     *         is called. To prevent double-counting with `_accountAvailableAssets`,
     *         the implementation MUST add `msg.value` to
     *         `ds.lockedTokens[wrappedNative]` immediately.
     */
    function enqueueDeposit() external payable;
}
