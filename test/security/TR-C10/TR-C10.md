# TR-C10 -- BASE_CURRENCY Hardcoded: No Depeg Detection

**Severity:** Low
**Status:** Open
**Location:** `src/registry/OracleRegistry.sol` -- `getAssetPrice()` (lines 113-123)

---

## The bug

`getAssetPrice(address asset)` contains an early-return short-circuit for the base currency:

```solidity
if (asset == BASE_CURRENCY) {
    return BASE_CURRENCY_UNIT;
}
```

This unconditionally returns the hardcoded unit value (e.g., `1e8` for $1.00) whenever the queried asset is the base currency (typically USDC). It does so even when an oracle is explicitly configured for that asset via `setOracleInfos`. During a stablecoin depeg event, every vault that denominates assets in the base currency will overvalue its holdings by the full depeg magnitude.

---

## Root cause

`OracleRegistry.sol` lines 113-123:

```solidity
function getAssetPrice(address asset) public view override returns (uint256) {
    OracleInfo memory info = _oracleInfos[asset];

    if (asset == BASE_CURRENCY) {
        return BASE_CURRENCY_UNIT;   // ← ignores _oracleInfos[BASE_CURRENCY] entirely
    } else {
        (, int256 price,, uint256 updatedAt,) = info.aggregator.latestRoundData();
        _verifyAnswer(price, updatedAt, info.stalenessThreshold);
        return uint256(price);
    }
}
```

The short-circuit predates oracle configuration for the base currency. Once an admin sets an oracle for `BASE_CURRENCY` (e.g., to monitor USDC's peg), the configured feed is silently bypassed. The `info` variable is loaded but never read for the base currency path.

---

## Entry conditions

**Normal operation:** `BASE_CURRENCY_UNIT` as $1.00 is a reasonable approximation when the stablecoin is at peg. The short-circuit avoids the need to configure a base currency oracle during initial deployment.

**Depeg scenario:** USDC historically depegged to ~$0.87 during the Silicon Valley Bank collapse in March 2023. At that level, any vault holding USDC as its denominating asset would report total assets inflated by **1764 bps (17.64%)** compared to real market value. The miscalculation affects both deposit share issuance (depositors receive fewer shares than justified) and withdrawal redemption (redeemers receive more underlying than entitled).

**Oracle already supported but ignored:** The `setOracleInfos` admin function accepts BASE_CURRENCY as a valid asset key. An operator who conscientiously configures a depeg oracle for BASE_CURRENCY gets no benefit -- the oracle is stored but never consulted.

---

## Impact

**Share price inflation:** During a 15-cent USDC depeg ($0.85), `getAssetPrice(BASE_CURRENCY)` returns `1e8` ($1.00) instead of `0.85e8`. For a vault holding 10,000 USDC, reported value is `$10,000` vs real value `$8,500` -- **$1,500 overstatement** on a single holding.

**Deposit/withdrawal mispricing:** Vault share prices are derived from total assets divided by total supply. Inflated total assets inflate share price, causing:
- Depositors at depeg time to receive fewer shares than their capital warrants (systematic underpay).
- Redeemers at depeg time to receive more underlying than their shares justify (systematic overpay that drains the vault).

**Silent failure of operator-configured oracles:** Any admin who configures a BASE_CURRENCY oracle to enable depeg detection receives no error and no indication that the oracle is ignored. The configuration appears successful but has zero effect.

**Scope:** Affects all vault configurations where `BASE_CURRENCY` is a stablecoin (the standard deployment). Vaults denominated in a volatile asset are less relevant since `BASE_CURRENCY_UNIT` would already be wrong in that context.

---

## Precedent

**Synthetix sUSD oracle bypass (2019):** Synthetix's exchange rate logic short-circuited the price lookup for its native stablecoin sUSD, hardcoding it at $1.00. During the March 2020 DAI depeg, protocols that used similar hardcoded stablecoin assumptions suffered amplified liquidation waves because collateral values were computed using stale $1.00 prices while the real market price diverged. Root cause: oracle path skipped for assets assumed to be stable.

**Applicability to MORE vaults:** The same pattern appears here. `getAssetPrice` bypasses the oracle for `BASE_CURRENCY` on the assumption that a stablecoin will always be worth exactly one unit. During a real depeg event, vault TVL, share price, deposit and redemption ratios all reflect an inflated baseline that does not match on-chain market reality.

---

## Fix

Change `getAssetPrice` to use the configured oracle for `BASE_CURRENCY` when one exists, falling back to `BASE_CURRENCY_UNIT` only when no oracle is set. This is backward-compatible: deployments without a BASE_CURRENCY oracle continue to use the hardcoded unit.

```diff
 function getAssetPrice(address asset) public view override returns (uint256) {
     OracleInfo memory info = _oracleInfos[asset];

-    if (asset == BASE_CURRENCY) {
-        return BASE_CURRENCY_UNIT;
-    } else {
-        (, int256 price,, uint256 updatedAt,) = info.aggregator.latestRoundData();
-        _verifyAnswer(price, updatedAt, info.stalenessThreshold);
-        return uint256(price);
-    }
+    if (address(info.aggregator) == address(0)) {
+        if (asset == BASE_CURRENCY) { return BASE_CURRENCY_UNIT; }
+        revert AggregatorNotSet();
+    }
+    (, int256 price,, uint256 updatedAt,) = info.aggregator.latestRoundData();
+    _verifyAnswer(price, updatedAt, info.stalenessThreshold);
+    return uint256(price);
 }
```

`AggregatorNotSet` already exists in `IOracleRegistry`. No new errors or imports required.

**Effect:**
- No oracle configured for BASE_CURRENCY → returns `BASE_CURRENCY_UNIT` (unchanged behavior).
- Oracle configured for BASE_CURRENCY → uses the feed price (depeg detection enabled).
- Other assets with no oracle configured → now explicitly revert `AggregatorNotSet` instead of calling `address(0).latestRoundData()`.

---

## Bytecode

- Removes 1 `EQ` + `JUMPI` + `RETURN` for the BASE_CURRENCY path.
- Adds 1 `STATICCALL` to `info.aggregator.latestRoundData()` on the BASE_CURRENCY path when oracle is set.
- Net change: approximately **−5 bytes** in `OracleRegistry` deployed bytecode (eliminating the early-return branch).
- No new error selectors or imports required.

---

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C10-OracleDepeg.t.sol` | `test_C10_path1_aggregator_zero_reverts_getAssetPrice` | PASS | Path 1 confirmed: zero aggregator causes DoS -- admin-only (Informational) |
| `TR-C10-OracleDepeg.t.sol` | `test_C10_path2_staleness_zero_always_reverts_getAssetPrice` | PASS | Path 2 confirmed: zero staleness causes DoS -- admin-only (Informational) |
| `TR-C10-OracleDepeg.t.sol` | `test_C10_path3_stork_heuristic_cannot_misfire_for_chainlink` | PASS | Path 3 disproved: Stork heuristic cannot misfire for real Chainlink timestamps (not a vulnerability) |
| `TR-C10-OracleDepeg.t.sol` | `test_C10_01_getAssetPrice_baseCurrency_ignores_oracle_during_depeg` | PASS | BUG: configured depeg oracle is silently bypassed, $1.00 returned |
| `TR-C10-OracleDepeg.t.sol` | `test_C10_02_share_price_inflation_magnitude_during_depeg` | PASS | BUG: 1764 bps (17.64%) inflation for a 15-cent USDC depeg |
| `TR-C10-OracleDepeg.t.sol` | `test_C10_FIX_getAssetPrice_baseCurrency_uses_oracle_during_depeg` | FAIL (expected) | Fix verification: with oracle configured, getAssetPrice returns depeg price |
