// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title StakingStorage
 * @notice Diamond storage for the Flow LST StakingFacet.
 *
 * Storage layout rationale
 * ------------------------
 * This library occupies its own Diamond storage slot so that it is fully
 * isolated from MoreVaultsStorage and any other facet. The slot is derived
 * from the human-readable label so it is collision-resistant and easy to
 * audit.
 *
 * Field-by-field notes
 * --------------------
 * totalStakedInCadence
 *   The canonical amount of FLOW currently delegated to a Flow validator node.
 *   Updated by the authorizedCOA after each Cadence epoch reward distribution.
 *   This is the single source of truth that `stakingTotalAssets()` reports.
 *
 * pendingDepositsLocked
 *   Mirror of `ds.lockedTokens[wrappedNative]` additions made by this facet.
 *   Kept here for auditability; the authoritative lock lives in MoreVaultsLib.
 *   While FLOW is queued here it is NOT included in `stakingTotalAssets()`
 *   because `_accountAvailableAssets` already counts it via `selfbalance()`.
 *   When `bridgeDeposits()` is called:
 *     1. `ds.lockedTokens[wrappedNative]` is decremented (FLOW leaves EVM).
 *     2. `totalStakedInCadence` is incremented by the same amount.
 *     3. `pendingDepositsLocked` is cleared.
 *   Net totalAssets change: zero.
 *
 * pendingRewards
 *   Rewards claimed from the Cadence staking contract but not yet distributed
 *   to vault depositors. Tracked for informational purposes; they are already
 *   included in `totalStakedInCadence` once the COA updates it.
 *
 * exchangeRate
 *   Informational: starts at 1e18 and increases as rewards accrue.
 *   Computed off-chain as `totalStakedInCadence / totalSupply_moreFLOW`.
 *   Not used by `totalAssets()` directly — the ERC4626 math handles
 *   the share-price relationship through `totalAssets / totalSupply`.
 *
 * authorizedCOA
 *   The single EVM address of the Cadence-Owned Account bridge contract.
 *   All state-mutating calls (updateStakedBalance, bridgeDeposits,
 *   settleWithdrawal) revert unless `msg.sender == authorizedCOA`.
 *
 * withdrawalPending
 *   Amount of FLOW that has been unstaked on Cadence but not yet arrived
 *   on EVM (7-14 day unbonding window). Included in `totalStakedInCadence`
 *   during this window, since moreFLOW for these amounts was already burned.
 *   When `settleWithdrawal()` is called, `totalStakedInCadence` drops and
 *   native FLOW arrives, so selfbalance() picks it up — net zero.
 */
library StakingStorage {
    bytes32 constant STAKING_STORAGE_POSITION = keccak256("MoreVaults.storage.StakingFacet.v1");

    struct WithdrawalRequest {
        uint256 amount;       // FLOW amount being unstaked
        uint64  requestedAt;  // timestamp when unstaking was initiated
        bool    pending;      // true until COA calls settleWithdrawal
    }

    struct Layout {
        /// @dev Total FLOW currently staked in Cadence, updated every epoch by COA.
        uint256 totalStakedInCadence;
        /// @dev Informational: rewards accumulated but not yet reflected in totalStakedInCadence.
        uint256 pendingRewards;
        /// @dev Informational: exchange rate (starts at 1e18, rises with rewards).
        uint256 exchangeRate;
        /// @dev Sum of FLOW locked in pendingDeposits (mirrors ds.lockedTokens addition).
        uint256 pendingDepositsLocked;
        /// @dev Amount of FLOW in the 7-14 day Cadence unbonding queue.
        uint256 withdrawalPending;
        /// @dev The only address allowed to call COA-only write functions.
        address authorizedCOA;
        /// @dev Per-user withdrawal state for the EVM-side claim.
        mapping(address => WithdrawalRequest) withdrawalRequests;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 position = STAKING_STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }
}
