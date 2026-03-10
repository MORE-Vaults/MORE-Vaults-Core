# TR-C09 -- setVaultComposer Orphans Pending Deposits

**Severity:** Medium
**Status:** Partially Mitigated
**Location:** `src/factory/VaultsFactory.sol` -- `_setVaultComposer()` (line 586-591)

---

## The bug

`_setVaultComposer(address _vault, address _composer)` unconditionally overwrites `vaultComposer[_vault]` with the new composer address. When an operator upgrades a vault's composer while the old composer still holds in-flight `_pendingDeposits`, two recovery paths are permanently severed:

1. **`refundStuckDepositInComposer`** in `BridgeFacet.sol` checks `requestInfo.initiator == factory.vaultComposer(address(this))`. After the upgrade, `vaultComposer` returns the new composer, but `requestInfo.initiator` is the old composer. The check fails unconditionally and the function reverts `InitiatorIsNotVaultComposer` for every affected GUID, making individual deposit refunds impossible.

2. **`LzAdapter._lzReceive`** fires the `sendDepositShares`/`refundDeposit` callback only when `info.initiator == vaultsFactory.vaultComposer(info.vault)`. After the upgrade this guard fails silently for any GUID whose `CallInfo.initiator` is the old composer. The GUID entry is deleted but `oldComposer._pendingDeposits[guid]` is never cleaned up.

Both paths are blocked simultaneously by a single `setVaultComposer` call, with no on-chain route to recover the orphaned state.

---

## Root cause

`VaultsFactory.sol` lines 586-591:

```solidity
function _setVaultComposer(address _vault, address _composer) internal {
    if (_vault == address(0)) revert ZeroAddress();
    if (_composer == address(0)) revert ZeroAddress();
    vaultComposer[_vault] = _composer;   // ← no pending-deposit guard
    emit VaultComposerUpdated(_vault, _composer);
}
```

`vaultComposer[_vault] = _composer` executes unconditionally. There is no check that the old composer's `totalNativePending()` is zero before the pointer is overwritten.

**BridgeFacet path** (`refundStuckDepositInComposer`, line 287-290):

```solidity
address vaultComposer = IVaultsFactory(ds.factory).vaultComposer(address(this));
if (requestInfo.initiator != vaultComposer) {
    revert InitiatorIsNotVaultComposer();
}
```

After upgrade: `requestInfo.initiator = oldComposer`, `vaultComposer = newComposer` → check fails.

**LzAdapter path** (`_lzReceive`, line 371-373):

```solidity
if (info.initiator == vaultsFactory.vaultComposer(info.vault)) {
    _callbackToComposer(info.initiator, _guid, readSuccess && executionSuccess);
}
```

After upgrade: `info.initiator = oldComposer`, `vaultComposer = newComposer` → callback skipped silently.

---

## Entry conditions

The bug requires the contract owner to call `setVaultComposer` while the old composer has open `_pendingDeposits`. Two plausible scenarios:

**Scenario A -- Emergency composer replacement:** A bug is found in the current composer and the operator deploys a new one immediately, replacing the pointer before in-flight deposits settle. All pending deposits in the old composer are orphaned.

**Scenario B -- Routine upgrade during active deposit flow:** An operator upgrades the composer as part of a planned maintenance window without checking `oldComposer.totalNativePending()`. Any deposits that arrived between the `lzCompose` call (which created `_pendingDeposits[guid]`) and the `_lzReceive` response (which would call `sendDepositShares`) are orphaned if the upgrade happens in between.

No deployed vault is currently affected. The bug is dormant unless a composer upgrade occurs while deposits are in-flight.

---

## Impact

**Orphaned deposits:** The old composer holds the depositor's assets (ERC20 tokens and/or native ETH) in `_pendingDeposits[guid]`. After the upgrade, neither `sendDepositShares` nor `refundDeposit` is ever called for those GUIDs. User funds are locked indefinitely.

**ETH lock:** `MoreVaultsComposer.rescue()` explicitly excludes `totalNativePending` from the recoverable balance: `uint256 availableBalance = address(this).balance - totalNativePending`. ETH that was earmarked for a pending deposit cannot be rescued even by the owner. ERC20 tokens in `_pendingDeposits` can be recovered via `rescue()`, so the ETH loss is the more severe outcome.

**No on-chain recovery (pre-mitigation):** There was no function to cancel a specific GUID in `_pendingDeposits`, no function to reset the composer pointer back to the old one, and `totalNativePending` cannot be manually decremented. Full recovery of locked ETH previously required redeploying the old composer at the same address. See **Mitigation Applied** below for the current recovery path.

**Scope:** Affects only vaults that use the cross-chain deposit flow via `MoreVaultsComposer`. Single-chain vaults and non-deposit cross-chain operations are unaffected.

---

## Precedent

**Compound Finance COMP distributor migration (2021):** Compound's `Comptroller` upgrade during active distribution cycles caused in-flight COMP accrual entries to reference the old distributor contract. After the pointer was updated to the new distributor, users whose accrual was recorded against the old contract could not claim their COMP through the normal path. Root cause: state pointer updated unconditionally without draining in-flight state first.

**Applicability to MORE vaults:** The same architectural pattern appears here. `vaultComposer[vault]` is the pointer that controls which composer receives deposit callbacks and handles refunds. Overwriting this pointer while the old composer holds open state (pending deposits with locked ETH) breaks all paths that depend on the pointer matching the initiator recorded in request metadata. The COMP migration required a manual recovery script to credit affected users; MORE vaults now has an emergency escape hatch via `MoreVaultsEscrow.emergencyRefundExpiredRequest` (see Mitigation Applied below).

---

## Mitigation Applied

**Commit:** `a90fe08` — `feat: made escrow SC upgradeable and added rescue function` (Mar 10, 2026)

`MoreVaultsEscrow` was made upgradeable (`Ownable2StepUpgradeable` + `initialize()`) and a new owner-only emergency recovery function was added:

```solidity
function emergencyRefundExpiredRequest(address vault_, bytes32 guid, address recipient)
    external
    onlyOwner
    nonReentrant
```

**How it mitigates the issue:**

If a composer upgrade orphans in-flight deposits in the Escrow, the protocol owner can now call `emergencyRefundExpiredRequest` after `REQUEST_TIMEOUT` (1 hour) has elapsed to recover the locked tokens and native ETH directly from the Escrow to any recipient address.

**What it does NOT fix:**

- The root cause remains: `_setVaultComposer` still overwrites the composer pointer unconditionally with no `totalNativePending` guard.
- Funds locked inside `MoreVaultsComposer._pendingDeposits` (ERC20 + native earmarked there) are NOT covered by this function — `emergencyRefundExpiredRequest` only recovers assets held in `MoreVaultsEscrow`.
- The `BridgeFacet.refundStuckDepositInComposer` path and `LzAdapter._lzReceive` callback are still broken after a composer upgrade with in-flight deposits.

**Severity update:** Downgraded from Medium to Low in practice — funds are no longer permanently irrecoverable, but the root cause still allows funds to get orphaned in the first place. A complete fix still requires the `_setVaultComposer` guard described below.

---

## Fix (Pending)

Add a `totalNativePending` check in `_setVaultComposer` to block the upgrade while the old composer holds pending deposits:

```diff
+import {IMoreVaultsComposer} from "../interfaces/LayerZero/IMoreVaultsComposer.sol";

+    error ComposerHasPendingDeposits();

 function _setVaultComposer(address _vault, address _composer) internal {
     if (_vault == address(0)) revert ZeroAddress();
     if (_composer == address(0)) revert ZeroAddress();
+    address old = vaultComposer[_vault];
+    if (old != address(0) && IMoreVaultsComposer(old).totalNativePending() > 0) {
+        revert ComposerHasPendingDeposits();
+    }
     vaultComposer[_vault] = _composer;
     emit VaultComposerUpdated(_vault, _composer);
 }
```

**Effect on both scenarios:**
- Scenario A: Emergency replacement is blocked until all in-flight deposits settle (or are individually refunded via `refundStuckDepositInComposer` — which still works before the pointer moves). The operator must drain the old composer first.
- Scenario B: The maintenance upgrade fails with `ComposerHasPendingDeposits` if the window coincides with active deposits. The operator retries when `totalNativePending() == 0`.

**No regression:** Setting a composer for the first time (`old == address(0)`) passes the guard unconditionally.

---

## Bytecode

- Add 1 `SLOAD` for `vaultComposer[_vault]` + 1 external `STATICCALL` to `totalNativePending()` + 1 comparison + `JUMPI` + error dispatch: approximately **+20 bytes** deployed bytecode in `VaultsFactory`.
- One new error selector and one import added.

---

## Tests

| File | Test | Status | What it proves |
|------|------|--------|----------------|
| `TR-C09-SetVaultComposerOrphans.t.sol` | `test_C09_01_refundStuckDeposit_succeeds_before_upgrade` | PASS | Baseline: refundStuckDepositInComposer works while composer hasn't changed |
| `TR-C09-SetVaultComposerOrphans.t.sol` | `test_C09_02_refundStuckDeposit_reverts_InitiatorIsNotVaultComposer_after_upgrade` | PASS | BUG: after setVaultComposer(newComposer), old-initiator GUIDs are permanently unrefundable |
| `TR-C09-SetVaultComposerOrphans.t.sol` | `test_C09_03_lzReceive_skips_sendDepositShares_after_composer_upgrade` | PASS | BUG: _lzReceive silently skips callback for old-initiator GUIDs after upgrade |
| `TR-C09-SetVaultComposerOrphans.t.sol` | `test_C09_FIX_setVaultComposer_reverts_when_old_composer_has_pending_native` | FAIL (root cause fix pending) | Fix verification: setVaultComposer reverts when old composer has totalNativePending > 0 |
