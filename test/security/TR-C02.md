# TR-C02 — ERC7540 Pending Deposit Invisible to accountingERC7540Facet

**Severity:** Medium (conditional)
**Status:** Acknowledged — not urgent (Michael Rozalenok)
**Location:** `src/facets/ERC7540Facet.sol:accountingERC7540Facet()`

---

## Root Cause — Key Mismatch in `ds.lockedTokens`

Write path (`erc7540RequestDeposit`, line 128):
```solidity
address asset = IERC4626(vault).asset();
ds.lockedTokens[asset] += assets;    // key = vault.asset() address
```

Read path (`accountingERC7540Facet`, line 102):
```solidity
uint256 balance = IERC20(vault).balanceOf(address(this)) + ds.lockedTokens[vault];
//                                                                          ^^^^^ key = vault address
```

During the pending window: `lockedTokens[vault] == 0` (shares not issued yet).
`lockedTokens[asset] == depositAmount` is written but never read here.

**Call chain for `totalAssets()`:**
1. `VaultFacet.totalAssets()` → calls `_accountAvailableAssets()` + `_accountFacets()`
2. `_accountAvailableAssets()` (VaultFacet.sol line 170, assembly): reads `lockedTokens[asset]` for each `asset` in `ds.availableAssets`
3. `_accountFacets()` → delegatecalls `accountingERC7540Facet()` for each registered facet
4. `accountingERC7540Facet()` reads `lockedTokens[vault]` (not `lockedTokens[asset]`) → **reads wrong key**

---

## When is the gap real?

### Scenario A — No gap (VaultFacet compensates)

**Condition:** `extVault.asset() == outer vault underlying` AND that token is in `ds.availableAssets`

```
erc7540RequestDeposit(usdcExtVault, 600 USDC)
  → lockedTokens[USDC] = 600
  → vault USDC balance: 1000 → 400

VaultFacet.totalAssets():
  _accountAvailableAssets([USDC]):
    USDC: balance=400 + lockedTokens[USDC]=600 = 1000  ✓
  accountingERC7540Facet():
    lockedTokens[usdcExtVault] = 0  (correct — already counted above)
  TOTAL = 1000  ✓
```

### Scenario B — Gap is real

**Conditions that trigger it:**
- Cross-asset: `extVault.asset()` (e.g. WETH) is not in `ds.availableAssets` of a USDC vault
- Misconfigured: same underlying but not registered in `ds.availableAssets`

```
erc7540RequestDeposit(wethExtVault, 600 WETH)
  → lockedTokens[WETH] = 600
  → vault WETH balance: 1000 → 400

VaultFacet.totalAssets():
  _accountAvailableAssets([USDC]):
    only iterates USDC — lockedTokens[WETH] never read
  accountingERC7540Facet():
    lockedTokens[wethExtVault] = 0  (WETH not yet converted to shares)
  TOTAL = USDC portion only — missing 600 WETH
```

---

## Is cross-asset ERC-7540 intended?

`erc7540RequestDeposit` has no restriction on `extVault.asset()`. A USDC vault CAN deposit into a WETH ERC-7540 vault. This is technically possible but unusual — it requires the vault to hold WETH balance before calling.

If cross-asset is NOT intended (and it introduces an accounting bug), it should be blocked (Fix A).
If cross-asset IS a desired use case, the accounting must be fixed instead (Fix B).

---

## Attack / Exploitation (Scenario B)

During the pending window NAV is understated. Any user who redeems at this point profits:

1. Operator calls `erc7540RequestDeposit(wethExtVault, 600 WETH)` — 600 WETH leaves the vault, NAV drops
2. Attacker calls `redeem(shares)` — burns fewer shares per WETH than correct (exchange rate is wrong)
3. Later, `erc7540Deposit` fulfills — vault receives shares, NAV recovers
4. Remaining LPs hold shares backed by fewer assets than before the attack

This requires the attacker to monitor mempool for the `requestDeposit` call. In practice:
- Whitelisted operators initiate `requestDeposit`
- Any user with vault shares can front-run by calling `redeem` in the same block
- Profit scales with pending deposit size and duration of the pending window

Test `TR-H02-ATTACK-NAVManipulation.t.sol` shows a +119 USDC profit on a 1200 USDC vault.

---

## Fix A — Block cross-asset deposits (not applied)

Add to `erc7540RequestDeposit` after `address asset = IERC4626(vault).asset()`:

```solidity
if (asset != MoreVaultsLib.getUnderlyingTokenAddress()) revert AssetMismatch();
```

Also add `error AssetMismatch()` to `IERC7540Facet`.

**Effect:** Scenario B is structurally impossible. Same-underlying deposits still work via Scenario A (VaultFacet handles them correctly). The bug in `accountingERC7540Facet` becomes harmless.

**Trade-off:** Cross-asset ERC-7540 investment (USDC vault → WETH ERC-7540 vault) is permanently blocked.

**Tests (4/4 pass with Fix A applied, 3/4 pass without):**
- `test_FIXA_cross_asset_deposit_reverts` — expects `AssetMismatch`, fails without fix
- `test_FIXA_same_underlying_deposit_succeeds` — same-underlying still works
- `test_FIXA_totalAssets_no_gap_after_same_underlying_deposit` — totalAssets = 1000, no gap
- `test_FIXA_existing_scenarioA_behavior_unchanged` — Scenario A path unaffected

---

## Fix B — Fix `accountingERC7540Facet` accounting (not applied)

Replace the balance line in `accountingERC7540Facet` with a guard that adds `lockedTokens[asset]` only when `_accountAvailableAssets` won't handle it:

**Correct implementation (unit-safe):**
```solidity
address asset = IERC4626(vault).asset();
// Convert held shares + redeem-locked shares to asset value
uint256 sharesValue = IERC4626(vault).convertToAssets(
    IERC20(vault).balanceOf(address(this)) + ds.lockedTokens[vault]
);
// Add deposit-locked amount (already in vault.asset() units, NOT shares)
// Guard: skip if _accountAvailableAssets already reads lockedTokens[asset]
uint256 lockedDeposit = ds.isAssetAvailable[asset] ? 0 : ds.lockedTokens[asset];
sum += MoreVaultsLib.convertToUnderlying(asset, sharesValue + lockedDeposit, Math.Rounding.Floor);
```

**Why the guard matters:** `lockedDeposit` is in asset units (USDC/WETH), not share units. Adding it to `balance` before `convertToAssets` would mix units. In a 1:1 ratio vault it happens to work, but in a vault where 1 share = 2 assets it would double-count the locked deposit. The correct fix adds `lockedDeposit` AFTER `convertToAssets`, in the same asset units.

**Unit test regression:** `ERC7540FacetTest.test_accountingERC7540Facet_ShouldAccountLockedTokensDuringAsyncDeposit` asserts 100 (shares only). With Fix B it correctly returns 150 (shares + locked deposit). The assertion was written against the buggy behavior. If Fix B is applied, update that test to assert 150.

**Trade-off vs Fix A:** Preserves cross-asset ERC-7540. More complex — requires the guard logic to be exactly right.

**Tests (5/5 pass with Fix B applied, 2/5 pass without):**
- `test_FIXB_scenarioB_gap_eliminated_asset_not_in_availableAssets` — gap closed, sum = 600
- `test_FIXB_scenarioA_no_double_count` — guard fires, lockedDeposit = 0 when asset in availableAssets
- `test_FIXB_redeem_path_unaffected` — lockedTokens[vault] (redeem shares) still works
- `test_FIXB_deposit_and_redeem_pending_simultaneously` — 600 + 500 = 1100 counted correctly
- `test_FIXB_scenarioB_variant_same_underlying_not_in_availableAssets` — misconfigured vault gap fixed

---

## Condition Summary

| Vault configuration | Gap | Fix A | Fix B |
|--------------------|-----|-------|-------|
| `extVault.asset()` == underlying, asset in `availableAssets` | None | No change | No change (guard = 0) |
| `extVault.asset()` == underlying, asset NOT in `availableAssets` | Full deposit | Blocks it | Fixed |
| Cross-asset (`extVault.asset()` not in `availableAssets`) | Full deposit | Blocks it | Fixed |

---

## All Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-H02-NAV-Pending-Deposit-Invisible.t.sol` | `test_TR_H02_pending_deposit_missing_from_totalAssets` | PASS | accountingERC7540Facet returns 0 for pending deposit |
| `TR-H02-NAV-Pending-Deposit-Invisible.t.sol` | `test_TR_H02_root_cause_key_mismatch` | PASS | lockedTokens[ASSET] written, lockedTokens[VAULT] read |
| `TR-H02-ATTACK-NAVManipulation.t.sol` | `test_TR_H02_attack_deposit_at_depressed_nav` | PASS | full attack: +119 USDC profit |
| `TR-H02-ATTACK-NAVManipulation.t.sol` | `test_TR_H02_attack_exchange_rates_logged` | PASS | confirms profit |
| `TR-C02-TrueGapConditions.t.sol` | `test_C02_scenarioA_underlying_in_availableAssets_totalAssets_correct` | PASS | Scenario A: no gap |
| `TR-C02-TrueGapConditions.t.sol` | `test_C02_scenarioA_accountingERC7540Facet_returns_zero_correctly` | PASS | Scenario A: ERC7540Facet returning 0 is correct behavior |
| `TR-C02-TrueGapConditions.t.sol` | `test_C02_scenarioB_cross_asset_deposit_gap_is_real` | PASS | Scenario B: cross-asset gap = 600 WETH |
| `TR-C02-TrueGapConditions.t.sol` | `test_C02_scenarioB_variant_underlying_not_in_availableAssets` | PASS | Scenario B: underlying not registered, gap exists |
| `TR-C02-TrueGapConditions.t.sol` | `test_C02_misleading_comment_code_does_not_count_locked_assets` | PASS | line comment claims both, code only reads shares |
| `TR-C02-FIX-A-Verification.t.sol` | `test_FIXA_cross_asset_deposit_reverts` | FAIL (expected without fix) | Fix A blocks cross-asset at entry |
| `TR-C02-FIX-A-Verification.t.sol` | `test_FIXA_same_underlying_deposit_succeeds` | PASS | Fix A allows same-underlying |
| `TR-C02-FIX-A-Verification.t.sol` | `test_FIXA_totalAssets_no_gap_after_same_underlying_deposit` | PASS | totalAssets correct with Fix A |
| `TR-C02-FIX-A-Verification.t.sol` | `test_FIXA_existing_scenarioA_behavior_unchanged` | PASS | Scenario A unaffected |
| `TR-C02-FIX-B-Verification.t.sol` | `test_FIXB_scenarioB_gap_eliminated_asset_not_in_availableAssets` | FAIL (expected without fix) | Fix B closes the gap |
| `TR-C02-FIX-B-Verification.t.sol` | `test_FIXB_scenarioA_no_double_count` | PASS | guard prevents double-count |
| `TR-C02-FIX-B-Verification.t.sol` | `test_FIXB_redeem_path_unaffected` | PASS | redeem path not broken |
| `TR-C02-FIX-B-Verification.t.sol` | `test_FIXB_deposit_and_redeem_pending_simultaneously` | FAIL (expected without fix) | both paths counted |
| `TR-C02-FIX-B-Verification.t.sol` | `test_FIXB_scenarioB_variant_same_underlying_not_in_availableAssets` | FAIL (expected without fix) | misconfigured vault fixed |
