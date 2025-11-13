// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IAnkrFlowPool
 * @notice Minimal interface for Ankr's Flow Staking Pool on Flow EVM mainnet.
 *
 * Mainnet (chainId 747): 0xFE8189A3016cb6A3668b8ccdAC520CE572D4287a
 *
 * Behaviour notes (specific to Flow's Ankr deployment):
 *  - `stakeCerts` is payable and mints ankrFLOW (cert token) to msg.sender.
 *  - `unstakeCerts` burns ankrFLOW from msg.sender and queues a withdrawal.
 *    The pool does NOT return a per-call requestId — pending claims are
 *    aggregated by claimer address.
 *  - When the underlying Flow unbonding window completes (~7–15 days), the
 *    operator calls `distributePendingRewards` which forwards native FLOW to
 *    each pending claimer. If the push fails (e.g. recipient contract has no
 *    `receive()`), the address is flagged via `isMarkedForManualClaim` and
 *    must call `claimManually(self)` to pull the funds.
 */
interface IAnkrFlowPool {
    /// @notice Stake native FLOW and mint ankrFLOW (cert) to msg.sender.
    function stakeCerts() external payable;

    /// @notice Stake native FLOW with a referral code.
    function stakeCertsWithCode(bytes32 code) external payable;

    /// @notice Burn `shares` ankrFLOW from msg.sender and queue an unstake.
    /// @dev    Claim arrives asynchronously via `distributePendingRewards` or
    ///         a follow-up `claimManually(msg.sender)` if auto-push failed.
    function unstakeCerts(uint256 shares) external;

    /// @notice Burn `shares` ankrFLOW from msg.sender, FLOW will be paid to `receiver`.
    function unstakeCertsFor(address receiver, uint256 shares) external;

    /// @notice Pull pending FLOW for `receiver` after the auto-push failed.
    /// @dev    Only callable when `isMarkedForManualClaim(receiver) == true`.
    function claimManually(address receiver) external;

    /// @notice Total FLOW currently queued for `claimer` across all pending requests.
    function getPendingUnstakesOf(address claimer) external view returns (uint256);

    /// @notice Per-request snapshot of `claimer`'s pending unstakes (chronological).
    function getPendingRequestsOf(address claimer) external view returns (uint256[] memory);

    /// @notice Amount currently sitting in the manual-claim escrow for `claimer`.
    function getForManualClaimOf(address claimer) external view returns (uint256);

    /// @notice True if `claimer` has a pending payout that requires `claimManually`.
    function isMarkedForManualClaim(address claimer) external view returns (bool);

    /// @notice Minimum amount accepted by `stakeCerts` (may revert on some impls; treat as best-effort).
    function getMinStake() external view returns (uint256);

    /// @notice Minimum amount accepted by `unstakeCerts` (may revert on some impls; treat as best-effort).
    function getMinUnstake() external view returns (uint256);

    /// @notice Returns (bondsToken, certToken) — for Flow the cert is ankrFLOW.
    function getTokens() external view returns (address bonds, address cert);
}
