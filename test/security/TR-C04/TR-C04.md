# TR-C04 — ERC4626 Return Value Violations in redeem() and previewWithdraw()

**Severity:** Medium
**Status:** Fixed — `469b63f` `fix: correct return value for redeem` (VaultFacet.sol) adds `assets = netAssets` post-`_handleWithdrawal`
**Location:** `src/facets/VaultFacet.sol` — `redeem()` (line 544-589), `previewWithdraw()` (line 1020-1028)

---

## The bug

`redeem()` returns the gross asset amount (before fee deduction) instead of the net amount actually transferred to the receiver. This violates the ERC4626 spec, which requires the return value to reflect the tokens actually delivered.

Separately, `previewWithdraw()` converts a net (post-fee) amount to shares, while `withdraw()` converts the gross (pre-fee) amount. This means `previewWithdraw()` understates the shares that `withdraw()` will actually burn, violating the ERC4626 invariant that the preview must match the execution.

Both bugs only manifest when `withdrawalFee > 0`. Vaults with zero fee are unaffected — the gross and net amounts are identical, so the return values happen to be correct by coincidence.

## Root cause

### BUG-01 — redeem() returns gross assets instead of net

Call chain in `redeem()` (lines 579-581):

```solidity
// VaultFacet.sol:579 -- compute gross assets from shares
assets = _convertToAssetsWithTotals(shares, totalSupply(), newTotalAssets, Math.Rounding.Floor);

// VaultFacet.sol:581 -- handle fee, transfer only net to receiver
uint256 netAssets = _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);

// `assets` is NEVER updated to `netAssets`.
// The named return variable `assets` still holds the GROSS amount.
// Function exits -- implicit return of `assets` (GROSS).
```

Inside `_handleWithdrawal()` (lines 1074-1098):

```solidity
function _handleWithdrawal(..., uint256 assets, ...) internal returns (uint256 netAssets) {
    uint256 withdrawalFeeAmount;
    if (ds.withdrawalFee > 0) {
        withdrawalFeeAmount = assets.mulDiv(ds.withdrawalFee, MoreVaultsLib.FEE_BASIS_POINT, Math.Rounding.Floor);
    }
    unchecked {
        netAssets = assets - withdrawalFeeAmount;  // line 1082
    }
    // ...
    _withdraw(msgSender, receiver, owner, netAssets, shares);  // line 1087: transfers NET only
}
```

The receiver gets `netAssets`. The return value is `assets` (gross). ERC4626 spec requires: *"MUST return the amount of underlying tokens exchanged"* — what was actually delivered to the receiver.

### BUG-02 — previewWithdraw() uses net in share conversion, withdraw() uses gross

`previewWithdraw()` (lines 1020-1027):

```solidity
uint256 withdrawalFeeAmount = _calculateWithdrawalFee(assets);
uint256 netAssets = assets - withdrawalFeeAmount;
return _convertToSharesWithTotals(netAssets, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
//                                 ^^^^^^^^^ NET
```

`withdraw()` (line 511):

```solidity
shares = _convertToSharesWithTotals(assets, totalSupply(), newTotalAssets, Math.Rounding.Ceil);
//                                   ^^^^^^ GROSS
```

Same conversion function, different inputs. `previewWithdraw(1000)` returns fewer shares than `withdraw(1000)` actually burns.

ERC4626 spec: *"previewWithdraw MUST return as close to and no fewer than the exact amount of Vault shares that would be burned"*.

Note: `previewRedeem()` (lines 1030-1037) is correct. It converts shares to gross, subtracts the fee, and returns net.

## Entry conditions

Both bugs only manifest when `ds.withdrawalFee > 0`.

The default is `withdrawalFee = 0`. Vaults with zero fee are unaffected — the gross and net amounts are identical, so the return values happen to be correct by coincidence.

- **BUG-01** affects every `redeem()` caller on a fee-enabled vault.
- **BUG-02** affects every integrator calling `previewWithdraw()` to predict share burn on a fee-enabled vault.

## Impact

### Numerical example (10% fee, 1000 USDC vault, 1:1 share ratio)

| Function | Expected (correct) | Actual (buggy) |
|---|---|---|
| `redeem(100k shares)` returns | 900 USDC (net) | 1000 USDC (gross) |
| Receiver actually gets | 900 USDC | 900 USDC |
| `previewRedeem(100k shares)` | 900 USDC | 900 USDC (correct) |
| `previewWithdraw(1000)` | 100,000 shares | 90,000 shares |
| `withdraw(1000)` burns | 100,000 shares | 100,000 shares |

### Composability attack: outer vault NAV inflation (BUG-01)

Any ERC4626 wrapper that calls `innerVault.redeem()` and trusts the return value for its own accounting is vulnerable.

1. Outer ERC4626 vault deposits 10,000 USDC into the inner MORE vault. It holds 10,000 inner shares.
2. Outer vault calls `innerVault.redeem(10000 shares, outerVault, outerVault)`.
3. `redeem()` returns 10,000 USDC (gross). Outer vault records `received = 10000 USDC`.
4. Actual tokens transferred to the outer vault: 9,000 USDC (net after 10% fee).
5. Outer vault `totalAssets` is inflated by 1,000 USDC. Its NAV is overstated.
6. Outer vault LPs redeem at the inflated NAV. They extract more than their fair share.
7. Remaining outer vault LPs absorb the 1,000 USDC shortfall.

This compounds on every redemption cycle. The gap equals `withdrawalFee * grossAssets` per call.

```solidity
// How an outer vault typically processes inner vault redemptions:
uint256 received = IERC7540(innerVault).redeem(shares, address(this), address(this));
// `received` = GROSS (1000 USDC), but only NET (900 USDC) arrived.
// Outer vault totalAssets inflated by 100 USDC.
```

### previewWithdraw inconsistency: ERC4626 integrator revert (BUG-02)

Standard ERC4626 integration pattern:

1. Integrator calls `previewWithdraw(1000 USDC)` — returns 90,000 shares (buggy, uses net).
2. Integrator approves the vault for exactly 90,000 shares.
3. Integrator calls `withdraw(1000 USDC)` — vault tries to burn 100,000 shares (uses gross).
4. Transaction **reverts** with insufficient allowance (approved 90,000, needs 100,000).

Any router, aggregator, or smart contract that uses `previewWithdraw` to set an approval amount before calling `withdraw` will fail every time on a fee-enabled vault. The user's transaction reverts with no recourse.

## Precedent

**USDT ERC20 return value non-compliance (2018 onward)** — Tether's `transfer()` does not return a `bool`, violating the ERC20 spec. Protocols that called `transfer()` and checked the return value reverted on USDT, while those that didn't check could silently fail. The community response was OpenZeppelin's `SafeERC20`. Identical pattern: a function's return value diverges from the spec, causing integrators that trust the return value to operate on incorrect data.

In MORE vaults, any ERC4626 aggregator that calls `innerVault.redeem()` and uses the return value to update its own NAV (standard pattern per EIP-4626) will record inflated assets, creating an exploitable NAV gap that compounds on every withdrawal cycle.

## Fix

### Fix-01 — redeem() returns net (VaultFacet.sol, after line 581)

```diff
  uint256 netAssets = _handleWithdrawal(ds, newTotalAssets, msgSender, receiver, owner, assets, shares);
+ assets = netAssets;
```

One assignment. The named return variable `assets` now reflects the net amount actually delivered.

### Fix-02 — previewWithdraw() uses gross (VaultFacet.sol, lines 1020-1028)

```diff
  function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
      (uint256 newTotalAssets, uint256 simTotalSupply) = _getPreviewData();
-     uint256 withdrawalFeeAmount = _calculateWithdrawalFee(assets);
-     uint256 netAssets;
-     unchecked {
-         netAssets = assets - withdrawalFeeAmount;
-     }
-     return _convertToSharesWithTotals(netAssets, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
+     return _convertToSharesWithTotals(assets, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
  }
```

`withdraw()` converts `assets` (gross) to shares. `previewWithdraw()` must do the same.

## Bytecode

Michael asked about free bytecode availability. Net impact is minimal or negative (saves space).

- **Fix-01** adds one `MSTORE` opcode to reassign `assets = netAssets`. Cost: ~3 bytes of deployed bytecode.
- **Fix-02** removes `_calculateWithdrawalFee` call (SLOAD + MULMOD + conditional), local variable allocation (`netAssets`), and the subtraction. Saves: ~10+ bytes of deployed bytecode.
- **Combined:** Fix-02 saves more than Fix-01 costs. Net result is a small bytecode **reduction**.

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-------------------|----------------|
| `TR-C04-RedeemReturnsGross.t.sol` | `test_C04_redeem_returns_gross_not_net` | PASS | return value = gross, transfer = net, gap = fee |
| `TR-C04-RedeemReturnsGross.t.sol` | `test_C04_previewWithdraw_understates_shares` | PASS | previewWithdraw returns 90k shares, withdraw burns 100k |
| `TR-C04-RedeemReturnsGross.t.sol` | `test_C04_composable_vault_nav_inflation` | PASS | outer vault records gross, receives net, NAV inflated |
| `TR-C04-RedeemReturnsGross.t.sol` | `test_C04_FIX01_redeem_returns_net_after_fix` | FAIL (expected) | Fix-01: return value == actual transfer |
| `TR-C04-RedeemReturnsGross.t.sol` | `test_C04_FIX02_previewWithdraw_matches_withdraw_after_fix` | FAIL (expected) | Fix-02: previewWithdraw == withdraw() shares burned |
| `VaultFacet.t.sol` | `test_redeem_ShouldApplyWithdrawalFee` | PASS (circular) | Passes via circular gross reference; breaks after Fix-01 |

**Unit test regression note:** The existing test `VaultFacetTest::test_redeem_ShouldApplyWithdrawalFee` (line 1794 in `test/unit/facets/VaultFacet.t.sol`) will break when Fix-01 is applied. Today, `assets` = gross (1000 USDC). The test computes `expectedFee = 10% of gross = 100`, then `expectedNetAmount = gross - fee = 900`, and asserts the user balance matches. This is circular: it derives the expected value from the buggy return value. After Fix-01, `redeem()` returns net (900 USDC), and the old assertion `assertEq(userBalance, assets - fee(assets))` fails because `net - 10%(net) != net`. The corrected assertion should be:

```solidity
uint256 returnedAssets = VaultFacet(facet).redeem(redeemShares, user, user);

// Return value must equal what the receiver got
assertEq(returnedAssets, userBalanceAfter - userBalanceBefore);

// Return value must match previewRedeem
assertEq(returnedAssets, VaultFacet(facet).previewRedeem(redeemShares));
```
