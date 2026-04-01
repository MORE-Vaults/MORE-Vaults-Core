// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {StakingStorage} from "../storage/StakingStorage.sol";
import {IStakingFacet} from "../interfaces/facets/IStakingFacet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title StakingFacet
 * @notice Flow LST staking integration for MORE Vaults.
 *
 * Architecture overview
 * ---------------------
 * The vault holds moreFLOW (an ERC-20 share token). When a user deposits
 * native FLOW it is:
 *   1. Received by the vault as native coin.
 *   2. Locked in `ds.lockedTokens[wrappedNative]` so `_accountAvailableAssets`
 *      does NOT double-count it via `selfbalance()`.
 *   3. Queued in `StakingStorage.pendingDepositsLocked`.
 *   4. Bridged by the COA to Cadence (via Cadence Engine).
 *   5. On bridge: lock cleared, `totalStakedInCadence` incremented — net zero.
 *
 * Reward accrual
 * --------------
 * Each Cadence epoch the COA calls `updateStakedBalance(newBalance)` where
 * `newBalance > totalStakedInCadence`. Because `totalAssets()` returns a
 * higher value while `totalSupply()` is unchanged, the ERC4626 share price
 * rises. moreFLOW holders automatically benefit — the canonical LST mechanic.
 *
 * Withdrawal flow
 * ---------------
 * When a user redeems moreFLOW:
 *   - Shares are burned immediately (standard ERC4626 redeem).
 *   - The unstaking request is sent to Cadence by the COA.
 *   - `totalStakedInCadence` still includes the amount during the 7-14 day
 *     unbonding period (shares are already gone so TVL is correct).
 *   - When FLOW returns on EVM, `settleWithdrawal()` decrements
 *     `totalStakedInCadence`; the arriving native FLOW is counted by
 *     `selfbalance()` — net zero change in `totalAssets`.
 *
 * Registration in facetsForAccounting
 * ------------------------------------
 * `initialize()` pushes `bytes32(IStakingFacet.stakingTotalAssets.selector)`
 * into `ds.facetsForAccounting`. The vault's `_accountFacets` reads each
 * element as a 4-byte left-aligned selector and calls
 * `staticcall(address(), selector, freePtr, 4, retOffset, 0x40)`. The
 * function must return `(uint256, bool)` with no ABI head/tail offsets —
 * i.e. the return must be exactly two 32-byte words back-to-back.
 * Solidity satisfies this automatically for `returns (uint256, bool)`.
 */
contract StakingFacet is IStakingFacet, BaseFacetInitializer {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // -------------------------------------------------------------------------
    // BaseFacetInitializer
    // -------------------------------------------------------------------------

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.StakingFacetV1.0.0");
    }

    function facetName() external pure returns (string memory) {
        return "StakingFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyCOA() {
        StakingStorage.Layout storage sl = StakingStorage.layout();
        if (msg.sender != sl.authorizedCOA) revert UnauthorizedCOA();
        _;
    }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /**
     * @notice Initialises the StakingFacet.
     * @param data ABI-encoded (address authorizedCOA).
     *
     * Registers `stakingTotalAssets` in `ds.facetsForAccounting` so the
     * vault's `totalAssets()` includes the Cadence-staked balance.
     * The selector is stored left-aligned in a bytes32, matching the format
     * `_accountFacets` expects (it stores the slot with `sload` directly
     * into memory before issuing `staticcall`).
     */
    function initialize(bytes calldata data) external initializerFacet {
        address coa = abi.decode(data, (address));
        if (coa == address(0)) revert InvalidParameters();

        StakingStorage.Layout storage sl = StakingStorage.layout();
        sl.authorizedCOA = coa;
        sl.exchangeRate = 1e18;

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Register the accounting hook.
        // bytes32(selector) left-shifts the 4-byte selector to the MSB so the
        // first word written to _freePtr contains the call data exactly.
        bytes32 accountingSelector = bytes32(IStakingFacet.stakingTotalAssets.selector);
        ds.facetsForAccounting.push(accountingSelector);

        ds.supportedInterfaces[type(IStakingFacet).interfaceId] = true;
    }

    /**
     * @notice Cleans up on facet removal.
     * @param isReplacing Whether a replacement facet is being installed.
     */
    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IStakingFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds,
            IStakingFacet.stakingTotalAssets.selector,
            isReplacing
        );
    }

    // -------------------------------------------------------------------------
    // Accounting hook (registered in facetsForAccounting)
    // -------------------------------------------------------------------------

    /**
     * @notice Returns `(totalStakedInCadence, true)`.
     * @dev    pendingDepositsLocked is intentionally excluded. While FLOW is
     *         queued it sits as native coin in the vault and is already counted
     *         by `_accountAvailableAssets` via `selfbalance()`. We do NOT use
     *         `ds.lockedTokens[wrappedNative]` because that field is ADDED on
     *         top of selfbalance in the assembly, which would double-count.
     *         Instead, queued FLOW is only reflected once via selfbalance; when
     *         the COA bridges it, selfbalance drops and totalStakedInCadence
     *         rises by the same amount — net zero.
     */
    function stakingTotalAssets() external view returns (uint256 amount, bool isPositive) {
        StakingStorage.Layout storage sl = StakingStorage.layout();
        amount = sl.totalStakedInCadence;
        isPositive = true;
    }

    // -------------------------------------------------------------------------
    // COA-only write functions
    // -------------------------------------------------------------------------

    /**
     * @notice Update the canonical staked balance post-epoch.
     * @dev    Only authorizedCOA. Increase → share price rises. Decrease → slashing.
     */
    function updateStakedBalance(uint256 newBalance) external onlyCOA {
        StakingStorage.Layout storage sl = StakingStorage.layout();
        uint256 prev = sl.totalStakedInCadence;
        sl.totalStakedInCadence = newBalance;
        emit StakedBalanceUpdated(prev, newBalance);
    }

    /**
     * @notice Bridge queued deposits to Cadence, updating staked balance.
     * @dev    selfbalance() drops (FLOW left EVM) and totalStakedInCadence
     *         rises by the same amount. Net totalAssets change = zero.
     *         No ds.lockedTokens manipulation: adding to lockedTokens would
     *         double-count because _accountAvailableAssets adds it on top
     *         of selfbalance().
     */
    function bridgeDeposits(uint256 amount) external onlyCOA {
        if (amount == 0) revert ZeroAmount();

        StakingStorage.Layout storage sl = StakingStorage.layout();
        sl.totalStakedInCadence += amount;
        sl.pendingDepositsLocked = 0;

        emit DepositBridged(amount);
    }

    /**
     * @notice Settle a completed withdrawal: FLOW arrived on EVM, reduce staked.
     * @dev    selfbalance() rises (FLOW received) and totalStakedInCadence drops.
     *         Net totalAssets change = zero. moreFLOW already burned at redeem.
     */
    function settleWithdrawal(address user, uint256 amount) external onlyCOA {
        if (amount == 0) revert ZeroAmount();

        StakingStorage.Layout storage sl = StakingStorage.layout();
        sl.totalStakedInCadence -= amount;

        StakingStorage.WithdrawalRequest storage req = sl.withdrawalRequests[user];
        req.pending = false;

        emit WithdrawalSettled(user, amount);
    }

    // -------------------------------------------------------------------------
    // User-facing
    // -------------------------------------------------------------------------

    /**
     * @notice Accept native FLOW and queue it for bridging.
     * @dev    FLOW sits as selfbalance until bridgeDeposits is called.
     *         _accountAvailableAssets counts it via selfbalance() already.
     *         stakingTotalAssets() excludes it, so no double-counting.
     */
    function enqueueDeposit() external payable {
        if (msg.value == 0) revert ZeroAmount();

        StakingStorage.Layout storage sl = StakingStorage.layout();
        sl.pendingDepositsLocked += msg.value;

        emit DepositEnqueued(msg.sender, msg.value);
    }
}
