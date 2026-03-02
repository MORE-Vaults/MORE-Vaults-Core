# TR-C06 -- maxWithdraw / maxRedeem Ignore Withdrawal Queue State

**Severity:** Low (view-function inconsistency, no fund loss)
**Status:** Open -- Michael: *"Not urgent, but makes sense, refactor needed before fix"*
**Location:** `src/facets/VaultFacet.sol` -- `maxRedeem()` (line 326), `maxWithdraw()` (line 320)

---

## The bug

`maxWithdraw(owner)` and `maxRedeem(owner)` return the user's full share-equivalent balance regardless of whether the withdrawal queue is enabled or whether a valid request with an elapsed timelock exists. `withdraw()` and `redeem()` enforce the queue strictly -- they revert with `CantProcessWithdrawRequest` if no valid request is present. The two surfaces give contradictory answers to the same question.

---

## Root cause

`maxWithdraw` delegates entirely to `super.maxWithdraw`, which in OZ ERC4626 is:

```solidity
function maxWithdraw(address owner) public view virtual returns (uint256) {
    return previewRedeem(maxRedeem(owner));
}
```

`maxRedeem` in the override:

```solidity
// VaultFacet.sol:326
function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    return super.maxRedeem(owner);  // = balanceOf(owner), ignores queue
}
```

Neither function reads `ds.isWithdrawalQueueEnabled` or `ds.withdrawalRequests[owner]`.

The enforcement lives entirely in `MoreVaultsLib.withdrawFromRequest()`:

```solidity
function withdrawFromRequest(address _owner, uint256 _shares) internal returns (bool) {
    if (!ds.isWithdrawalQueueEnabled) return true;
    if (isWithdrawableRequest(request.timelockEndsAt) && request.shares >= _shares) {
        request.shares -= _shares;
        return true;
    }
    return false;  // withdraw/redeem revert on false
}
```

`withdrawFromRequest` is only called from state-changing functions (`withdraw`, `redeem`), never from view functions.

---

## Entry conditions

The inconsistency is active whenever `isWithdrawalQueueEnabled == true`. Three sub-cases:

- **No request submitted:** `maxWithdraw` returns full balance, `withdraw` reverts immediately.
- **Request submitted, timelock not elapsed:** `maxWithdraw` still returns full balance, `withdraw` reverts.
- **Timelock reset (griefing):** `requestWithdraw` overwrites `timelockEndsAt` on every call. If a user (or operator with allowance) calls `requestWithdraw` before the previous timelock expires, the window resets. `maxWithdraw` returns non-zero throughout; `withdraw` always reverts.

The withdrawal queue is **not enabled on any deployed vault today**. This is an opt-in feature. The bug is dormant until a vault curator enables it.

---

## Impact

No fund loss. `withdraw` and `redeem` revert cleanly; shares and assets remain intact (confirmed by `test_C06_05`).

The practical impact is integrator breakage:

- Off-chain systems that gate withdrawal calls on `maxWithdraw() > 0` will attempt `withdraw()` and get `CantProcessWithdrawRequest`. No funds lost, but the transaction fails and gas is wasted.
- ERC4626 aggregators that use `maxWithdraw` to populate UI state (e.g. "available to withdraw") will show the full balance as withdrawable at all times, even during the timelock window.
- The timelock-reset scenario lets a user or operator keep `maxWithdraw` permanently non-zero while `withdraw` permanently reverts -- an indefinite inconsistency rather than a temporary one.

---

## Precedent

**Ribbon Finance v2 ribbon vaults (2022)** -- Ribbon's theta vaults locked deposited shares between weekly option rounds. During the locked period, `maxRedeem()` returned the user's full balance. Calls to `redeem()` reverted because the vault was between rounds. ERC4626 aggregators (including Yearn strategy helpers) that used `maxRedeem` to determine withdrawal feasibility attempted `redeem()` during the locked window and received unexpected reverts. The root cause was identical: a protocol-specific state constraint enforced only in the state-changing function, invisible to the view function.

In MORE vaults: if a third-party ERC4626 wrapper or yield aggregator allocates capital to a MORE vault with the withdrawal queue enabled, it will call `maxWithdraw` to check exit capacity before rebalancing. `maxWithdraw` will always report full capacity. The aggregator calls `withdraw`, gets `CantProcessWithdrawRequest`, and the rebalance fails. For automated strategies with slippage or timing constraints this can cause cascading failures across the aggregator's positions.

---

## Fix

**Fix A -- naive (breaks `requestRedeem`):** Override `maxRedeem` to check queue state. This alone breaks `requestRedeem` because that function validates `_shares <= maxRedeem(owner)`, which would return 0 before any request exists, making it impossible to submit the initial request.

**Fix B -- correct refactor (4 touch points):**

### Step 1 -- Fix `maxRedeem` to reflect queue state

```diff
 function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
+    MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
+    if (ds.isWithdrawalQueueEnabled) {
+        MoreVaultsLib.WithdrawRequest storage request = ds.withdrawalRequests[owner];
+        if (!MoreVaultsLib.isWithdrawableRequest(request.timelockEndsAt)) {
+            return 0;
+        }
+        uint256 balance = balanceOf(owner);
+        return request.shares < balance ? request.shares : balance;
+    }
     return super.maxRedeem(owner);
 }
```

`maxWithdraw` inherits the fix automatically via `previewRedeem(maxRedeem(owner))`.

### Step 2 -- Decouple `requestRedeem` from `maxRedeem`

```diff
-    uint256 maxRedeem_ = maxRedeem(_onBehalfOf);
-    if (_shares > maxRedeem_) {
-        revert ERC4626ExceededMaxRedeem(_onBehalfOf, _shares, maxRedeem_);
+    uint256 balance_ = balanceOf(_onBehalfOf);
+    if (_shares > balance_) {
+        revert ERC4626ExceededMaxRedeem(_onBehalfOf, _shares, balance_);
     }
```

Same change in `requestWithdraw` (line 437).

### Step 3 -- Fix cap checks inside `withdraw` and `redeem`

`withdrawFromRequest` decrements `request.shares` before `withdraw`/`redeem` call `maxRedeem` for their cap check. After decrement, `maxRedeem` sees `request.shares = 0` and returns 0, causing a false `ERC4626ExceededMaxRedeem`. Replace with `balanceOf`:

```diff
-    maxRedeem_ = maxRedeem(owner);
+    maxRedeem_ = balanceOf(owner);
```

Two occurrences: `withdraw()` (line 537) and `redeem()` (line 580). The queue constraint is already enforced by `withdrawFromRequest`; this check only guards against burning more than the owner holds.

---

## Bytecode

- Step 1 (`maxRedeem`): +~15 bytes (SLOAD, comparison, two conditional branches).
- Steps 2-3 (`requestRedeem`, `requestWithdraw`, `withdraw`, `redeem`): neutral -- replaces a `maxRedeem()` internal call with a `balanceOf()` call at each site, similar opcode cost.
- Net: approximately **+15 bytes** deployed bytecode.

---

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_01_maxWithdraw_nonzero_but_withdraw_reverts_no_request` | PASS | maxWithdraw = 100 assets, withdraw() reverts |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_02_maxRedeem_nonzero_but_redeem_reverts_no_request` | PASS | maxRedeem = 10000 shares, redeem() reverts |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_03_request_exists_timelock_not_elapsed_maxWithdraw_still_lies` | PASS | request exists but timelock active: maxWithdraw still non-zero, withdraw reverts |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_04_timelock_reset_griefing_perpetuates_inconsistency` | PASS | timelock reset extends inconsistency indefinitely |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_05_no_fund_loss_funds_safe_after_failed_attempts` | PASS | shares and assets unchanged after failed withdraw -- no fund loss |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_06_correct_path_request_plus_elapsed_timelock` | PASS | happy path works: request + elapsed timelock = successful withdraw |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_07_why_refactor_needed_maxRedeem_used_in_requestRedeem_validation` | PASS | requestRedeem uses maxRedeem as balance cap -- naive fix breaks it |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_FIXA_maxRedeem_returns_zero_when_no_valid_request` | FAIL (expected) | Fix A: maxRedeem = 0 when no valid request |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_FIXA_regression_requestRedeem_breaks_with_naive_fix` | FAIL (expected) | Fix A alone: requestRedeem reverts with ERC4626ExceededMaxRedeem |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_FIXB_maxWithdraw_zero_no_request` | FAIL (expected) | Fix B: maxWithdraw = 0 when queue enabled + no request |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_FIXB_requestRedeem_still_works_after_refactor` | PASS | Fix B: requestRedeem still accepts shares up to balance |
| `TR-C06-MaxWithdraw-QueueState.t.sol` | `test_C06_FIXB_maxWithdraw_correct_after_elapsed_timelock` | FAIL (expected) | Fix B: maxWithdraw reflects queued amount after timelock, withdraw succeeds |
