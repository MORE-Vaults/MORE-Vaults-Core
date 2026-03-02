# TR-C01 — LZ Retry Inflates totalAssets (Non-Idempotent Accounting)

**Severity:** High
**Status:** Fixed
**Location:** `src/facets/BridgeFacet.sol` — `updateAccountingInfoForRequest()` (line 219)

---

## The bug

`BridgeFacet.updateAccountingInfoForRequest()` is called by the LZ adapter (`crossChainAccountingManager`) when a cross-chain read response arrives. It adds the spoke chain's USD value to the stored `requestInfo.totalAssets` using `+=`. LayerZero guarantees **at-least-once delivery** — if the LZ executor retries the message (DVN redundancy, gas exhaustion, network hiccup), this function is called again for the same GUID, and the `+=` accumulates again.

Two bugs follow from the non-idempotent design.

## Root cause

### BUG-01 — totalAssets inflation via non-idempotent `+=`

```solidity
// BridgeFacet.sol:220 — BEFORE FIX
ds.guidToCrossChainRequestInfo[guid].totalAssets += convertUsdToUnderlying(sumOfSpokesUsdValue, ...);
ds.guidToCrossChainRequestInfo[guid].fulfilled = readSuccess;
```

Each LZ retry for the same GUID adds `sumOfSpokesUsdValue` again. N retries = N times the correct spoke value in storage. `VaultFacet._getInfoForAction()` (line 1051) reads `requestInfo.totalAssets` directly when `_isCrossChainWithoutOracle` is true, so the inflated value goes straight into share computation for all action types.

```
LZ Executor
    |
    +-- lzManager.updateAccountingInfoForRequest(guid, spokeValue, true)
              |
              +-- requestInfo.totalAssets += convertedSpokeValue   <-- BUG: += not =
              +-- requestInfo.fulfilled = readSuccess
    [LZ retry fires]
    |
    +-- lzManager.updateAccountingInfoForRequest(guid, spokeValue, true)  <-- same GUID
              |
              +-- requestInfo.totalAssets += convertedSpokeValue   <-- adds again
                   totalAssets now = hubSnapshot + 2 * spoke
```

### BUG-02 — fulfilled flag overwrite (DOS vector)

`fulfilled = readSuccess` overwrites on every call. A retry with `readSuccess=false` (failed read replayed after a successful one) sets `fulfilled` back to `false`, causing `executeRequest` to revert with `RequestWasntFulfilled`. User funds are locked in escrow until timeout.

## Entry conditions

This bug triggers on **any** LZ retry, which LayerZero's at-least-once delivery model guarantees can happen under normal operating conditions (DVN redundancy, gas exhaustion, network hiccups). No special attacker setup is required — the protocol's own infrastructure can trigger the double-accounting. Any vault using cross-chain accounting without an oracle (`_isCrossChainWithoutOracle == true`) is affected whenever a read response arrives via LZ.

## Impact

The inflated `totalAssets` corrupts share math in `VaultFacet._getInfoForAction()` for every action type:

| Action | Effect of inflated totalAssets | Who loses |
|--------|-------------------------------|-----------|
| DEPOSIT | fewer shares minted | depositor |
| WITHDRAW | **fewer shares burned** | remaining LPs |
| REDEEM | fewer assets returned | redeemer |
| MINT | more assets consumed | minter |

The profitable attack path is **WITHDRAW**: the withdrawer receives full assets but burns fewer shares than correct. The share delta stays redeemable, backed by real vault assets.

**Example (1 retry, vault: 1000 USDC hub + 200 USDC spoke = 1200 correct NAV, 1000 shares):**

| | Correct (1200 NAV) | After 1 retry (1400 NAV) |
|--|--|--|
| Withdraw 120 USDC | burns 100 shares | burns 85.7 shares |
| Shares saved | -- | **14.3 shares ~ $17.14** |

With N retries the profit scales linearly: 1 retry $17, 2 retries $25, 3 retries $33.

## Precedent

**Polygon bridge double-spend vulnerability (December 2021)** -- A critical vulnerability was discovered in Polygon's Plasma bridge where withdrawals could be processed multiple times because the state-change was non-idempotent. The exit transaction did not properly mark the withdrawal as consumed, allowing the same proof to be replayed. White-hat researcher Gerhard Wagner reported the bug before exploitation; approximately $850M in MATIC was at risk. Polygon paid a $2M bounty.

The same pattern applies to MORE vaults: LayerZero's at-least-once delivery means `updateAccountingInfoForRequest` can be called multiple times for the same GUID, and without the idempotency guard, each replay inflates `totalAssets` via `+=` -- the cross-chain equivalent of processing the same message twice without marking it consumed.

## Fix

`src/facets/BridgeFacet.sol` -- added idempotency guard at the top of `updateAccountingInfoForRequest()`:

```solidity
// AFTER FIX — BridgeFacet.sol:219-224
if (ds.guidToCrossChainRequestInfo[guid].fulfilled) {
    return;
}
```

Once `fulfilled == true`, any subsequent call returns immediately. This makes the function idempotent and fixes both bugs simultaneously:

- BUG-01: retry hits the guard, `+=` never executes again, `totalAssets` stays correct
- BUG-02: false retry hits the guard, `fulfilled` stays `true`, `executeRequest` can proceed

**Edge case preserved:** A first call with `readSuccess=false` sets `fulfilled=false`. The guard does not fire. A subsequent retry with `readSuccess=true` proceeds normally -- this is the legitimate retry-after-failure path and must still work. Verified in `test_FIX_failed_first_then_success_retry_still_fulfills`.

## Bytecode

The fix adds a single `SLOAD` + `JUMPI` (idempotency check on the `fulfilled` storage slot). Net cost is approximately 6 bytes of deployed bytecode. No offsetting savings.

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C01-LZ-Retry-Inflation.t.sol` | `test_TR_H01_non_idempotent_accounting_on_retry` | PASS (bug fires) | Two identical calls accumulate `totalAssets` twice |
| `TR-C01-LZ-Retry-Inflation.t.sol` | `test_TR_H01_fulfilled_flag_overwritten_on_false_retry` | PASS (bug fires) | False retry sets `fulfilled` from `true` to `false` |
| `TR-C01-ATTACK-FullProfit.t.sol` | `test_TR_H01_attack_retry_inflates_stored_totalAssets` | PASS (bug fires) | Full attack scenario with slippage and DOS paths |
| `TR-C01-ATTACK-FullProfit.t.sol` | `test_TR_H01_attack_access_control_analysis` | PASS | Confirms only lzManager can call the function (no arbitrary external exploit) |
| `TR-C01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_retry_inflates_totalAssets_fewer_shares_burned` | PASS (bug fires) | WITHDRAW path: 1 retry saves 14.3 shares = $17.14 profit |
| `TR-C01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_n_retries_linear_profit_scaling` | PASS (bug fires) | Profit scales linearly: 1 retry $17, 2 retries $25, 3 retries $33 |
| `TR-C01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_vs_deposit_direction_comparison` | PASS (bug fires) | WITHDRAW profits, DEPOSIT loses (corrects prior analysis) |
| `TR-C01-FIX-Verification.t.sol` | `test_FIX_retry_after_success_does_not_inflate_totalAssets` | PASS (fix works) | Retry is a no-op, totalAssets stays at 1200 |
| `TR-C01-FIX-Verification.t.sol` | `test_FIX_false_retry_does_not_overwrite_fulfilled_flag` | PASS (fix works) | Fulfilled stays true after false retry, DOS eliminated |
| `TR-C01-FIX-Verification.t.sol` | `test_FIX_n_retries_all_noop` | PASS (fix works) | 5 retries, totalAssets unchanged every time |
| `TR-C01-FIX-Verification.t.sol` | `test_FIX_failed_first_then_success_retry_still_fulfills` | PASS (fix works) | Failed first + successful retry still fulfills correctly |

Unit test suite: 1010/1010 pass after the fix. No regressions.

**Note on prior analysis:** `TR-C01-ATTACK-FullProfit.t.sol` (original) concluded that "deposit() uses live totalAssets -- the stored requestInfo.totalAssets is metadata only." This was incorrect. `VaultFacet._getInfoForAction()` (line 1051) reads `requestInfo.totalAssets` directly when `_isCrossChainWithoutOracle` is true. The original analysis only examined the DEPOSIT path and concluded the attacker loses. The WITHDRAW path was not examined and is the profitable direction.
