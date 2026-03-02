# TR-C07 -- Governance Brick Chain: setTimeLockPeriod + setWithdrawalTimelock Permanent Locks

**Severity:** Informational (owner self-inflicted, no external attack vector)
**Status:** Acknowledged -- Michael: *"Just don't set it as max Uint256 for now"*
**Location:** `src/facets/MulticallFacet.sol` -- `submitActions()` (line 60); `src/facets/ConfigurationFacet.sol` -- `setTimeLockPeriod()` (line 114), `setWithdrawalTimelock()` (line 162)

---

## The bug

Three governance bricking conditions exist in the timelock parameter setters:

**BUG-01 -- timeLockPeriod arithmetic overflow:** `submitActions()` computes `uint256 pendingUntil = block.timestamp + ds.timeLockPeriod` (line 60) in checked arithmetic scope. If `timeLockPeriod == type(uint256).max`, Solidity 0.8 reverts with `Panic(0x11)`. Because `setTimeLockPeriod()` is gated by `validateDiamond` (only callable via `executeActions → submitActions` self-call), there is no recovery path once the overflow is stored: `submitActions` always reverts, so no governance action can ever be submitted again.

**BUG-02 -- witdrawTimelock unreachable timestamp:** `setWithdrawalTimelock(type(uint64).max)` stores approximately 5.84 × 10^11 years as the withdrawal timelock. `requestWithdraw` and `requestRedeem` compute `timelockEndsAt = block.timestamp + ds.witdrawTimelock`. With `type(uint64).max`, the resulting `timelockEndsAt` exceeds any reachable block timestamp by hundreds of billions of years. `isWithdrawableRequest()` never returns true; users with the withdrawal queue enabled can never withdraw.

**BUG-03 -- Guardian veto with no deadline:** `vetoActions()` is callable by the guardian at any time after `submitActions`, with no deadline after which veto power lapses. A compromised or adversarial guardian can veto every governance action indefinitely, permanently blocking the curator from executing any change.

---

## Root cause

**BUG-01** -- `MulticallFacet.sol` line 60:

```solidity
uint256 pendingUntil = block.timestamp + ds.timeLockPeriod;  // ← overflows if timeLockPeriod = type(uint256).max
```

No upper bound is validated in `setTimeLockPeriod` before storing the value. The overflow is not in the setter but in every subsequent call to `submitActions`, making recovery impossible through on-chain governance alone.

**BUG-02** -- `ConfigurationFacet.sol` line 162-167:

```solidity
function setWithdrawalTimelock(uint64 _duration) external {
    AccessControlLib.validateDiamond(msg.sender);
    MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
    ds.witdrawTimelock = _duration;        // ← no upper bound check
    emit WithdrawalTimelockSet(_duration);
}
```

`_duration` is `uint64`, so no arithmetic overflow occurs. The problem is semantic: `type(uint64).max ≈ 1.844 × 10^19` seconds (~584 billion years) is a valid `uint64` value but an unreachable timestamp when added to `block.timestamp`.

**BUG-03** -- `MulticallFacet.sol` lines 139-154:

```solidity
function vetoActions(uint256[] calldata actionsNonces) external {
    AccessControlLib.validateGuardian(msg.sender);
    // ...
    delete ds.pendingActions[actionsNonces[i]];  // ← no deadline check
}
```

There is no check that `block.timestamp < someDeadline` before allowing the veto. The guardian retains veto power indefinitely after an action is queued.

---

## Entry conditions

**This is an owner-inflicted problem.** There is no external attack vector. An outside party cannot trigger any of these bugs — they require the vault owner or curator to take a deliberate (and obviously wrong) governance action:

- `setTimeLockPeriod(type(uint256).max)` must be proposed and executed through the full timelock flow by the owner
- `setWithdrawalTimelock(type(uint64).max)` — a 20-digit number — must be explicitly passed by the owner

The only threat models are: (a) a compromised owner key, or (b) a careless mistake during initial vault setup. In both cases the damage is self-contained to that vault. Cross-vault interaction is limited: if the bricked vault is a hub, governance changes for its associated spokes are also blocked, but spoke-level deposits and withdrawals remain functional.

The bugs are **dormant until the extreme value is stored**. No deployed vault is currently affected.

**BUG-03** is always present whenever a guardian is configured. It becomes a real risk only if the guardian key is compromised or if the guardian acts adversarially.

---

## Impact

**BUG-01:** Governance is permanently bricked. `submitActions` always reverts → no pending action can be created → `validateDiamond` functions (`setTimeLockPeriod`, `setWithdrawalTimelock`, `transferOwnership`, etc.) become unreachable forever. The only recovery is redeploying the vault from scratch, which may not be possible for a live vault with user funds.

**BUG-02:** All users who have submitted withdrawal requests under a queue with `witdrawTimelock = type(uint64).max` can never complete their withdrawals on-chain. Their shares remain locked. Shares can still be transferred, but cannot be redeemed through the normal withdrawal path.

**BUG-03:** A compromised guardian can veto every curator action indefinitely, preventing fee changes, asset configuration, cross-chain accounting updates, and any other governance action that requires the timelock queue.

None of these bugs directly steal funds. BUG-01 and BUG-02 cause permanent lockout; BUG-03 causes indefinite blockage.

---

## Precedent

**MakerDAO Governance Security Module (GSM) delay bounds:** MakerDAO's `DSPause` contract (the on-chain governance delay module) explicitly enforces a minimum and maximum delay. If `delay = type(uint256).max`, the internal computation `eta = block.timestamp + delay` would overflow and revert on every governance execution, permanently freezing the GSM. MakerDAO addressed this by capping the delay at a maximum value enforced in the setter, not in the consumer. This is the industry-standard fix adopted by Compound (`MAXIMUM_DELAY = 30 days`), Uniswap, and Aave governance timelocks.

MORE vaults has the vulnerability that every major DeFi governance timelock fixed: no upper bound on the timelock parameter enforced at the setter. The difference is that MORE vaults uses Solidity 0.8 checked arithmetic, so the overflow in `submitActions` produces an explicit revert rather than silent wraparound. The revert makes the brick visible but also makes recovery impossible.

**Applicability to MORE vaults:** Any vault curator who accidentally submits `setTimeLockPeriod(type(uint256).max)` through a governance proposal -- or any owner who makes a direct storage-level mistake during initial configuration -- permanently bricks all governance for that vault. Unlike MakerDAO's GSM where an emergency shutdown mechanism exists as an escape hatch, MORE vaults has no off-chain recovery path short of redeployment.

---

## Fix

Add upper bound validation in `ConfigurationFacet.sol` at the two setter functions:

```diff
+    error TimeLockPeriodTooHigh();
+    error WithdrawalTimelockTooHigh();
+    uint256 public constant MAX_TIME_LOCK_PERIOD    = 365 days;
+    uint64  public constant MAX_WITHDRAWAL_TIMELOCK = 365 days;

     function setTimeLockPeriod(uint256 period) external {
         AccessControlLib.validateDiamond(msg.sender);
+        if (period > MAX_TIME_LOCK_PERIOD) revert TimeLockPeriodTooHigh();
         MoreVaultsLib._setTimeLockPeriod(period);
     }

     function setWithdrawalTimelock(uint64 _duration) external {
         AccessControlLib.validateDiamond(msg.sender);
+        if (_duration > MAX_WITHDRAWAL_TIMELOCK) revert WithdrawalTimelockTooHigh();
         MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
```

**Effect on BUG-01:** `setTimeLockPeriod(type(uint256).max)` reverts with `TimeLockPeriodTooHigh` before the value is stored. `submitActions` never receives an overflow-inducing `timeLockPeriod`. The `MAX_TIME_LOCK_PERIOD = 365 days` cap is generous for any practical governance configuration and eliminates the overflow branch entirely.

**Effect on BUG-02:** `setWithdrawalTimelock(type(uint64).max)` reverts with `WithdrawalTimelockTooHigh`. The `MAX_WITHDRAWAL_TIMELOCK = 365 days` cap leaves ample room for any reasonable withdrawal queue configuration.

**BUG-03** has no code-level fix; it is a governance design tradeoff. Mitigation options include: (a) establishing a veto deadline after which the curator can execute without guardian approval, or (b) requiring multi-sig for the guardian role to prevent single-key compromise. These are operational decisions outside the current audit scope.

---

## Bytecode

- Step 1 (`setTimeLockPeriod`): +1 comparison + `JUMPI` + error dispatch: approximately **+6 bytes**.
- Step 2 (`setWithdrawalTimelock`): +1 comparison + `JUMPI` + error dispatch: approximately **+6 bytes**.
- Two new error selectors and two constants added to `ConfigurationFacet`: stored in bytecode, not storage.
- Net: approximately **+12 bytes** deployed bytecode across `ConfigurationFacet`.

---

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_01_submitActions_reverts_overflow_with_max_timeLockPeriod` | PASS | BUG-01: timeLockPeriod = max uint → submitActions Panic(0x11) |
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_02_no_recovery_path_after_governance_brick` | PASS | BUG-01: no on-chain path to reset timeLockPeriod after brick |
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_03_witdrawTimelock_max_uint64_makes_timelock_effectively_permanent` | PASS | BUG-02: timelockEndsAt = ~584B years from now, never reachable |
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_04_guardian_can_veto_any_action_at_any_time` | PASS | BUG-03: guardian vetoes before and after timelock with no deadline |
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_FIX01_setTimeLockPeriod_rejects_overflow_value` | FAIL (expected) | Fix verification: setTimeLockPeriod(max) reverts TimeLockPeriodTooHigh |
| `TR-C07-GovernanceBrick.t.sol` | `test_C07_FIX02_setWithdrawalTimelock_rejects_max_uint64` | FAIL (expected) | Fix verification: setWithdrawalTimelock(max) reverts WithdrawalTimelockTooHigh |
