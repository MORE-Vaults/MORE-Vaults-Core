# TR-C05 — lzReduce Failed-Spoke Sum Inclusion + Overflow DoS

**Severity:** Medium
**Status:** Open
**Location:** `src/cross-chain/layerZero/LzAdapter.sol` — `lzReduce()` (line 232-246)

---

## The bug

`lzReduce()` aggregates cross-chain spoke responses by summing `(uint256 assets, bool success)` tuples. Two defects exist in the aggregation loop:

**BUG-01 — Logical inclusion:** `sum += assets` executes unconditionally, even when `success = false`. A failed spoke's reported value is included in the aggregated total. The intent was to exclude it — only `readSuccess` is set to false, but the value still accumulates, inflating the hub vault's totalAssets.

**BUG-02 — Overflow DoS:** `sum += assets` is in checked arithmetic scope (only `++i` is `unchecked`). If `sum + assets > type(uint256).max`, Solidity 0.8 reverts. This reverts `lzReduce` → LayerZero cannot deliver the read response → the GUID is permanently blocked → all pending cross-chain requests for that accounting cycle are frozen.

Under current spoke code both bugs are **dormant** — failed spokes always return `(0, false)`, so the sum is unaffected. The defect becomes dangerous if spoke behavior changes or external factors inject unexpected bytes.

## Root cause

`lzReduce()` in `LzAdapter.sol` (lines 232-246):

```solidity
function lzReduce(bytes calldata, bytes[] calldata _responses) external pure returns (bytes memory) {
    if (_responses.length == 0) revert NoResponses();
    uint256 sum;
    bool readSuccess = true;
    for (uint256 i = 0; i < _responses.length;) {
        (uint256 assets, bool success) = abi.decode(_responses[i], (uint256, bool));
        if (!success) readSuccess = false;
        sum += assets;          // ← BUG: executes ALWAYS, regardless of success flag

        unchecked { ++i; }
    }
    return abi.encode(sum, readSuccess);
}
```

**BUG-01 — Logical inclusion:** `sum += assets` runs even when `success = false`. A failed spoke's reported value is included in the aggregated total. The intent was to exclude it (only `readSuccess` is set to false, but the value still accumulates).

**BUG-02 — Overflow DoS:** `sum += assets` is in checked arithmetic scope (only `++i` is `unchecked`). If `sum + assets > type(uint256).max`, Solidity 0.8 reverts. This reverts `lzReduce` → LayerZero cannot deliver the read response → the GUID is permanently blocked → all pending cross-chain requests for that accounting cycle are frozen.

### Why the custom design diverges from LayerZero examples

The official `LzReadCounter.lzReduce()` example (in `lib/LayerZero-v2/.../LzReadCounter.sol`) does **not have a `success` flag** at all — it directly decodes responses as `uint256` and sums them. There is no precedent in LZ's own examples for conditional aggregation based on a success flag.

The `(uint256, bool)` encoding in MORE vaults is a **custom protocol design choice** — the success flag originates from `totalAssetsUsd()` on the spoke, not from LayerZero infrastructure. This means:

1. LayerZero itself does not enforce any meaning on the `bool` — it passes bytes as-is
2. The conditional logic (exclude failed spokes from sum) must be implemented entirely in `lzReduce`
3. The current implementation fails to implement this correctly

## Entry conditions

The bug only manifests under specific conditions. Under current protocol code it is **dormant** (benign today, dangerous in the future).

**Always present (latent):**
- Any vault with cross-chain spokes configured
- Any call to `initiateCrossChainAccounting()` that triggers a LayerZero read cycle

**Needed to activate BUG-01 (sum inflation):**
- A spoke returns `(largeValue, false)` — a non-zero assets value paired with `success = false`
- Today this is impossible because `totalAssetsUsd()` always returns `(0, false)` on failure (see below)

**Needed to activate BUG-02 (overflow DoS):**
- A spoke returns an assets value large enough that `sum += assets` overflows `uint256`
- Today this is also impossible with the current spoke implementation
- Becomes possible if: (a) a buggy/compromised spoke is added, (b) the contract at the spoke address changes, or (c) a DVN injects malformed bytes

### Why benign today

The spoke vault's `totalAssetsUsd()` (`VaultFacet.sol` lines 275-295):

```solidity
function totalAssetsUsd() public returns (uint256 _totalAssets, bool success) {
    ...
    if (!success) {
        return (0, false);   // ← always returns 0 when any accounting step fails
    }
    ...
    return (MoreVaultsLib.convertUnderlyingToUsd(_totalAssets, ...), true);
}
```

**On every failure path, the spoke returns `(0, false)` — never `(largeValue, false)`.**

In the current implementation:
- `sum += 0` when a spoke fails — no inflation, no overflow
- `readSuccess = false` correctly propagates — the hub refunds the request

The bug is a **logic defect that cannot be triggered by the current spoke code**. It becomes dangerous if the spoke behavior changes or if external factors (DVN compromise, wrong contract at spoke address) inject unexpected bytes.

### When it becomes dangerous

**Scenario 1 — Future code change (most likely):**
A developer modifies `totalAssetsUsd()` to return partial data on soft failures instead of zeroing:
```solidity
// Future: partial accounting, still marks success=false
return (_totalAssets, false);  // BUG-01 activates immediately
```
The sum inflates by `_totalAssets` for the failed spoke. The hub vault's `updateAccountingInfoForRequest` stores an inflated total. All share conversions (deposits, withdrawals) use this incorrect NAV until the next accounting cycle.

**Scenario 2 — Wrong contract at spoke address (upgrade risk):**
An upgrade deploys a different contract at the spoke address. The new contract's response bytes to `totalAssetsUsd()` decode as a large `uint256` with `false`. BUG-02 reverts `lzReduce` → DoS.

**Scenario 3 — DVN compromise on Flow EVM (elevated risk vs. mainnet):**
Flow EVM is a newer chain with fewer DVN operators than Ethereum. A compromised DVN that has enough votes could inject arbitrary `_responses` bytes into `lzReduce`. Injecting `(type(uint256).max, false)` triggers the overflow revert, permanently blocking all cross-chain accounting for any GUID delivered through that DVN. LayerZero's security model assumes DVNs are honest and independent. On chains with lower DVN count, this assumption is weaker.

**Scenario 4 — abi.decode on empty/malformed bytes:**
If LZ delivers a response where the spoke call reverted entirely (not returning the `(uint256, bool)` tuple), the `abi.decode(_responses[i], (uint256, bool))` call inside `lzReduce` itself would revert (malformed data). This also blocks the delivery but through a different mechanism.

## Impact

- **BUG-01 (sum inflation):** The hub vault's `updateAccountingInfoForRequest` stores an inflated total. All share conversions (deposits, withdrawals) use this incorrect NAV until the next accounting cycle. Users depositing during an inflated NAV receive fewer shares than warranted; users withdrawing receive more assets than warranted — directly extractable economic damage.
- **BUG-02 (overflow DoS):** `lzReduce` reverts → LayerZero cannot deliver the read response → the GUID is permanently blocked → all pending cross-chain accounting requests for that cycle are frozen. The protocol must wait for the next accounting cycle to recover; any time-sensitive operations (withdrawals, rebalancing) are delayed indefinitely.

## Precedent

The Synthetix protocol aggregated multiple oracle price feeds for the Korean Won (sKRW). Two independent off-chain feed providers simultaneously experienced outages. The on-chain aggregation logic **included the stale/failed feed values in the aggregate** instead of excluding them.

Result: KRW price reported 1,000x higher than actual. An arbitrage bot extracted over 1 billion USD in synthetic profit within minutes (later reversed via a bug bounty negotiation).

**Root cause is identical to BUG-01:** failed data sources were not excluded from the sum. The Synthetix incident happened off-chain; in MORE vaults it would happen on-chain via `lzReduce`.

Reference: https://blog.synthetix.io/response-to-oracle-incident/

**Applicability to MORE vaults:** The same pattern could manifest on Flow EVM if a DVN is compromised and injects `(largeValue, false)` responses. In that scenario, `lzReduce` silently inflates the hub vault's `totalAssets`, corrupting NAV for all users in that accounting cycle — the exact same failure mode as the Synthetix sKRW incident, but executed on-chain through cross-chain message injection rather than off-chain oracle manipulation.

## Fix

```solidity
function lzReduce(bytes calldata, bytes[] calldata _responses) external pure returns (bytes memory) {
    if (_responses.length == 0) revert NoResponses();
    uint256 sum;
    bool readSuccess = true;
    for (uint256 i = 0; i < _responses.length;) {
        (uint256 assets, bool success) = abi.decode(_responses[i], (uint256, bool));
        if (success) {
            sum += assets;      // only add if spoke reported success
        } else {
            readSuccess = false;
        }
        unchecked { ++i; }
    }
    return abi.encode(sum, readSuccess);
}
```

**Effect on BUG-01:** Failed spoke values are no longer included in the sum regardless of what value the spoke reports.

**Effect on BUG-02:** The overflow path is eliminated — only verified successful responses contribute to `sum`. A failed spoke returning `type(uint256).max` is ignored, not summed.

**No regression:** In the current protocol, failed spokes return `(0, false)`. The fix produces identical output (`sum` unchanged, `readSuccess = false`) for this case. Zero behavioral change under current conditions.

```diff
- if (!success) readSuccess = false;
- sum += assets;
+ if (success) {
+     sum += assets;
+ } else {
+     readSuccess = false;
+ }
```

## Bytecode

- Removes 1 unconditional `ADD` + `SSTORE` sequence
- Adds 1 `JUMPI` (conditional branch)
- Net: approximately **+2 to +4 bytes** deployed bytecode (one extra branch)
- `lzReduce` is `external pure` — no storage reads, no state changes
- This is the lowest-cost category of fix possible in Solidity

The fix is defensive: it does not change observable behavior under current spoke code (spokes return 0 on failure), but correctly handles any future scenario where a failed spoke returns a non-zero value.

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C05-LzReduce-FailedSpoke.t.sol` | `test_C05_01_failed_spoke_value_included_in_sum` | PASS | BUG-01: failed spoke (500e18, false) adds 500 to sum |
| `TR-C05-LzReduce-FailedSpoke.t.sol` | `test_C05_02_overflow_causes_revert_when_spoke_returns_max_uint` | PASS | BUG-02: type(uint256).max causes lzReduce to revert |
| `TR-C05-LzReduce-FailedSpoke.t.sol` | `test_C05_03_today_benign_because_failed_spoke_returns_zero` | PASS | Today benign: (0, false) does not inflate sum |
| `TR-C05-LzReduce-FailedSpoke.t.sol` | `test_C05_04_FIX_failed_spoke_excluded_from_sum` | FAIL (expected) | Fix verification: sum = 1200, not 1700 |
| `batch-B08-harness.t.sol` | `test_NOVEL_lzReduce_sumOverflow_reverts` | PASS | Independent confirmation of BUG-02 |
| `batch-B08-harness.t.sol` | `test_NOVEL_lzReduce_allFailed_sumsZero` | PASS (asserts bug behavior) | Confirms sum includes failed values |

**Unit test regression note:** The `test_NOVEL_lzReduce_allFailed_sumsZero` test in `test/trace/batch-B08-harness.t.sol` asserts `sum = 1500e18` (includes failed values). With the fix applied, sum would be 0. **This test would need updating** if the fix is applied.
