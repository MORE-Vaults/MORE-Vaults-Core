# TR-H01 — LZ Retry Inflates totalAssets (Non-Idempotent Accounting)

**Severity:** High
**Status:** Fixed
**Location:** `src/facets/BridgeFacet.sol` — `updateAccountingInfoForRequest()`
**Found by:** Trace swarm analysis, batch B04 / B08 / B09

---

## The Bug

`BridgeFacet.updateAccountingInfoForRequest()` is called by the LZ adapter (`crossChainAccountingManager`) when a cross-chain read response arrives. It adds the spoke chain's USD value to the stored `requestInfo.totalAssets`:

```solidity
// BridgeFacet.sol:220 — BEFORE FIX
ds.guidToCrossChainRequestInfo[guid].totalAssets += convertUsdToUnderlying(sumOfSpokesUsdValue, ...);
ds.guidToCrossChainRequestInfo[guid].fulfilled = readSuccess;
```

LayerZero guarantees **at-least-once delivery**. If the LZ executor retries the message (DVN redundancy, gas exhaustion, network hiccup), this function is called again for the same GUID. The `+=` accumulates again. Two bugs follow:

**Bug 1 — totalAssets inflation:**
Each retry adds `sumOfSpokesUsdValue` again. N retries = N× the correct spoke value in storage.

**Bug 2 — fulfilled flag DOS:**
`fulfilled = readSuccess` overwrites on every call. A retry with `readSuccess=false` (failed read replayed after a successful one) sets `fulfilled` back to `false`, causing `executeRequest` to revert with `RequestWasntFulfilled`. User funds are locked in escrow until timeout.

---

## Where It Hits — The Full Flow

```
LZ Executor
    │
    └── lzManager.updateAccountingInfoForRequest(guid, spokeValue, true)
              │
              ├── requestInfo.totalAssets += convertedSpokeValue   ← BUG: += not =
              └── requestInfo.fulfilled = readSuccess               ← BUG: overwritable

    [LZ retry fires]
    │
    └── lzManager.updateAccountingInfoForRequest(guid, spokeValue, true)  ← same GUID
              │
              └── requestInfo.totalAssets += convertedSpokeValue   ← adds again
                   totalAssets now = hubSnapshot + 2 * spoke

    executeRequest(guid)
              │
              └── _executeRequest(guid)
                        │
                        ├── checks fulfilled == true
                        ├── calls deposit/withdraw/redeem/mint via address(this).call(...)
                        │         │
                        │         └── VaultFacet._getInfoForAction()
                        │                   │
                        │                   └── if (_isCrossChainWithoutOracle)
                        │                           totalAssets_ = requestInfo.totalAssets  ← reads INFLATED value
                        │
                        └── share math uses inflated totalAssets_
```

**Key:** `VaultFacet.sol:1051` reads `requestInfo.totalAssets` (stored), not the live vault balance. The inflated value goes directly into share computation for ALL action types.

### Economic direction by action type

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
| Shares saved | — | **14.3 shares ≈ $17.14** |

With N retries the profit scales linearly.

---

## The Fix

`src/facets/BridgeFacet.sol` — added idempotency guard at the top of `updateAccountingInfoForRequest()`:

```solidity
// AFTER FIX — BridgeFacet.sol:219-224
if (ds.guidToCrossChainRequestInfo[guid].fulfilled) {
    return;
}
```

Once `fulfilled == true`, any subsequent call returns immediately. This makes the function idempotent and fixes both bugs simultaneously:

- Bug 1: retry hits the guard, `+=` never executes again, `totalAssets` stays correct
- Bug 2: false retry hits the guard, `fulfilled` stays `true`, `executeRequest` can proceed

**Edge case preserved:** A first call with `readSuccess=false` sets `fulfilled=false`. The guard does not fire. A subsequent retry with `readSuccess=true` proceeds normally — this is the legitimate retry-after-failure path and must still work. Verified in `test_FIX_failed_first_then_success_retry_still_fulfills`.

---

## Tests

### Bug proof (demonstrate the vulnerability)

| File | What it proves |
|------|---------------|
| `TR-H01-LZ-Retry-Inflation.t.sol` | `test_TR_H01_non_idempotent_accounting_on_retry` — two identical calls accumulate `totalAssets` twice |
| `TR-H01-LZ-Retry-Inflation.t.sol` | `test_TR_H01_fulfilled_flag_overwritten_on_false_retry` — false retry sets `fulfilled` from `true` to `false` |
| `TR-H01-ATTACK-FullProfit.t.sol` | `test_TR_H01_attack_retry_inflates_stored_totalAssets` — full attack scenario with slippage and DOS paths |
| `TR-H01-ATTACK-FullProfit.t.sol` | `test_TR_H01_attack_access_control_analysis` — confirms only lzManager can call the function (no arbitrary external exploit) |
| `TR-H01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_retry_inflates_totalAssets_fewer_shares_burned` — WITHDRAW path: 1 retry saves 14.3 shares = $17.14 profit |
| `TR-H01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_n_retries_linear_profit_scaling` — profit scales linearly: 1 retry $17, 2 retries $25, 3 retries $33 |
| `TR-H01-WITHDRAW-SharesUnderdrain.t.sol` | `test_TR_H01_withdraw_vs_deposit_direction_comparison` — WITHDRAW profits, DEPOSIT loses (corrects prior analysis) |

### Fix verification (confirm the fix works and has no regressions)

| File | What it verifies |
|------|-----------------|
| `TR-H01-FIX-Verification.t.sol` | `test_FIX_retry_after_success_does_not_inflate_totalAssets` — retry is a no-op, totalAssets stays at 1200 |
| `TR-H01-FIX-Verification.t.sol` | `test_FIX_false_retry_does_not_overwrite_fulfilled_flag` — fulfilled stays true after false retry, DOS eliminated |
| `TR-H01-FIX-Verification.t.sol` | `test_FIX_n_retries_all_noop` — 5 retries, totalAssets unchanged every time |
| `TR-H01-FIX-Verification.t.sol` | `test_FIX_failed_first_then_success_retry_still_fulfills` — failed first + successful retry still fulfills correctly |

**Unit test suite:** 1010/1010 pass after the fix. No regressions.

---

## Note on prior analysis

`TR-H01-ATTACK-FullProfit.t.sol` (original) concluded:

> *"deposit() uses live totalAssets — the stored requestInfo.totalAssets is metadata only"*

This was incorrect. `VaultFacet._getInfoForAction()` (line 1051) reads `requestInfo.totalAssets` directly when `_isCrossChainWithoutOracle` is true. The original analysis only examined the DEPOSIT path and concluded the attacker loses. The WITHDRAW path was not examined and is the profitable direction.
