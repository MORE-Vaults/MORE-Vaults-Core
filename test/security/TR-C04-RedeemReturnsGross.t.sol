// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C04: ERC4626 Return Value Violations in redeem() and previewWithdraw()
 *
 * Two related bugs in VaultFacet when withdrawalFee > 0:
 *
 * BUG-01 -- redeem() returns gross assets, not net (ERC4626 violation)
 *   VaultFacet.sol:579-581:
 *     assets = _convertToAssetsWithTotals(shares, ...);           // gross
 *     uint256 netAssets = _handleWithdrawal(..., assets, shares); // transfers NET only
 *     // implicit return of `assets` = GROSS -- wrong per ERC4626
 *
 *   ERC4626 spec: "MUST return the amount of underlying tokens exchanged, i.e. what
 *   the caller would have received in return for burning the given exact amount of shares."
 *   Only netAssets reach the receiver. The return value should be netAssets.
 *
 * BUG-02 -- previewWithdraw() uses netAssets in shares conversion, withdraw() uses gross
 *   previewWithdraw (line 1020-1027):
 *     uint256 netAssets = assets - _calculateWithdrawalFee(assets);
 *     return _convertToSharesWithTotals(netAssets, ...); // uses NET
 *
 *   withdraw() (line 511):
 *     shares = _convertToSharesWithTotals(assets, ...); // uses GROSS
 *
 *   previewWithdraw(1000) returns ~900 shares, but withdraw(1000) burns ~1000 shares.
 *   ERC4626 spec: previewWithdraw MUST return >= shares burned by withdraw in same tx.
 *
 * COMPOSABILITY IMPACT:
 *   Outer vaults calling innerVault.redeem() and trusting the return value for accounting
 *   will record grossAssets as received, but only netAssets were transferred. Over time,
 *   the outer vault's totalAssets drifts up by the accumulated fee gap on every redeem.
 *   NAV is inflated, existing LPs hold shares backed by fewer real assets.
 *
 * FIX-01 -- redeem() fix (VaultFacet.sol line 581, add one line):
 *   assets = netAssets; // return what was actually delivered, not gross
 *
 * FIX-02 -- previewWithdraw() fix (VaultFacet.sol line 1027, use gross):
 *   return _convertToSharesWithTotals(assets, simTotalSupply, newTotalAssets, Math.Rounding.Ceil);
 *   // drop netAssets; withdraw() uses gross, so preview must match
 *
 * C04-01: redeem() return value == gross, actual transfer == net (gap = fee amount)
 * C04-02: previewWithdraw() underestimates shares vs what withdraw() actually burns
 * C04-03: composable vault accounting inflated by accumulated fee gap
 * C04-04 (FIX-01): after fix, redeem() return value == net == actual transfer
 * C04-05 (FIX-02): after fix, previewWithdraw() == shares burned by withdraw()
 */

import {Test, console} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract TR_C04_RedeemReturnsGross is Test {

    VaultFacet public vault;
    MockERC20 public asset;
    MockMoreVaultsEscrow public escrow;

    address public alice      = makeAddr("alice");
    address public feeRecipient = makeAddr("feeRecipient");
    address public registry   = makeAddr("registry");
    address public factory    = makeAddr("factory");
    address public oracle     = makeAddr("oracle");
    address public router     = makeAddr("router");

    // 10% withdrawal fee (1000 bps out of 10000)
    uint96 constant WITHDRAWAL_FEE = 1000;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        vault = new VaultFacet();
        asset = new MockERC20("USDC", "USDC");
        escrow = new MockMoreVaultsEscrow();
        escrow.setUnderlyingToken(address(vault), address(asset));

        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(vault), registry);
        MoreVaultsStorageHelper.setFactory(address(vault), factory);

        _mockRegistryAndOracle();

        // fee=0 performance fee, withdrawalFee set separately via StorageHelper
        bytes memory initData = abi.encode(
            "Test Vault", "TV", address(asset), feeRecipient, uint96(0), uint256(type(uint128).max)
        );
        vault.initialize(initData);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(vault), registry);
        MoreVaultsStorageHelper.setIsHub(address(vault), true);
        MoreVaultsStorageHelper.setWithdrawalFee(address(vault), WITHDRAWAL_FEE);

        _mockFactory();

        // Alice deposits 1000 USDC to get shares
        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        console.log("=================================================================");
        console.log("TR-C04: ERC4626 Return Value Violations (withdrawalFee = 10%)");
        console.log("=================================================================");
        console.log("Alice deposited:", DEPOSIT_AMOUNT / 1e18, "USDC");
        console.log("Alice shares:   ", vault.balanceOf(alice) / 1e18);
        console.log("Vault USDC:     ", asset.balanceOf(address(vault)) / 1e18);
        console.log("Withdrawal fee: 10% (1000 bps)");
        console.log("");
    }

    // =========================================================================
    // C04-01: redeem() returns gross, receiver gets net only
    // =========================================================================
    function test_C04_redeem_returns_gross_not_net() public {
        console.log("=================================================================");
        console.log("C04-01: redeem() return value != assets delivered to receiver");
        console.log("=================================================================");

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceAssetBefore = asset.balanceOf(alice);

        console.log("Alice shares to redeem:   ", aliceShares / 1e18);
        console.log("Alice asset balance before:", aliceAssetBefore / 1e18);

        vm.prank(alice);
        uint256 returnedAssets = vault.redeem(aliceShares, alice, alice);

        uint256 aliceAssetAfter = asset.balanceOf(alice);
        uint256 actualTransferred = aliceAssetAfter - aliceAssetBefore;
        uint256 expectedGross = DEPOSIT_AMOUNT;
        uint256 expectedNet = DEPOSIT_AMOUNT * (10000 - WITHDRAWAL_FEE) / 10000; // 900 USDC

        console.log("redeem() return value:  ", returnedAssets / 1e18, "(gross)");
        console.log("Actual USDC received:   ", actualTransferred / 1e18, "(net)");
        console.log("Expected gross (~1000): ", expectedGross / 1e18);
        console.log("Expected net   (~900):  ", expectedNet / 1e18);
        console.log("Fee gap (return - received):", (returnedAssets - actualTransferred) / 1e18);
        console.log("");

        // BUG: return value is gross, actual transfer is net
        assertGt(returnedAssets, actualTransferred, "BUG: returnedAssets (gross) > actualTransferred (net)");

        // Return value is approximately gross (1000 USDC)
        assertApproxEqAbs(returnedAssets, expectedGross, 1e15,
            "BUG-01: redeem() returns gross assets (~1000), not net (~900)");

        // Actual transfer is approximately net (900 USDC)
        assertApproxEqAbs(actualTransferred, expectedNet, 1e15,
            "Only net assets (~900) reach the receiver");

        uint256 feeGap = returnedAssets - actualTransferred;
        assertApproxEqAbs(feeGap, DEPOSIT_AMOUNT * WITHDRAWAL_FEE / 10000, 1e15,
            "Fee gap = full withdrawal fee amount (~100 USDC)");

        console.log("CONFIRMED BUG-01: redeem() return value exceeds actual transfer by ~", feeGap / 1e18, "USDC");
        console.log("ERC4626 spec: return MUST equal amount delivered to receiver.");
        console.log("Fix: add `assets = netAssets;` after _handleWithdrawal() in redeem().");
    }

    // =========================================================================
    // C04-02: previewWithdraw() underestimates shares vs withdraw()
    // =========================================================================
    function test_C04_previewWithdraw_understates_shares() public {
        console.log("=================================================================");
        console.log("C04-02: previewWithdraw() inconsistent with withdraw() share burn");
        console.log("=================================================================");

        // previewWithdraw must be called as alice (because _getPreviewData uses msg.sender for HWM)
        vm.prank(alice);
        uint256 previewShares = vault.previewWithdraw(DEPOSIT_AMOUNT);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceSharesBefore = aliceShares;

        // Now actually call withdraw(DEPOSIT_AMOUNT) and see how many shares are burned
        vm.prank(alice);
        uint256 actualSharesBurned = vault.withdraw(DEPOSIT_AMOUNT, alice, alice);

        uint256 aliceSharesAfter = vault.balanceOf(alice);
        uint256 computedSharesBurned = aliceSharesBefore - aliceSharesAfter;

        console.log("previewWithdraw(1000 USDC) =", previewShares / 1e18, "shares (uses NET in conversion)");
        console.log("withdraw(1000 USDC) returned shares burned:", actualSharesBurned / 1e18, "(uses GROSS)");
        console.log("Actual shares deducted from Alice:", computedSharesBurned / 1e18);
        console.log("");

        // previewWithdraw uses netAssets (900) in conversion -> returns ~90,000 shares
        // withdraw uses grossAssets (1000) in conversion -> burns ~100,000 shares
        // So preview understates by ~10,000 shares (= 10% of total shares)
        assertGt(actualSharesBurned, previewShares,
            "BUG-02: withdraw() burns more shares than previewWithdraw() predicted");

        uint256 discrepancy = actualSharesBurned - previewShares;
        console.log("Share discrepancy (withdraw - preview):", discrepancy / 1e18);
        console.log("Discrepancy as % of total:", discrepancy * 100 / aliceSharesBefore, "%");

        // Discrepancy ~ 10% of shares (fee rate)
        assertGt(discrepancy, 0, "BUG-02: previewWithdraw underestimates by fee share amount");

        console.log("CONFIRMED BUG-02: previewWithdraw uses netAssets in share conversion,");
        console.log("but withdraw uses grossAssets. ERC4626: preview MUST return >= actual shares burned.");
        console.log("Fix: change previewWithdraw to use `assets` (gross) in _convertToSharesWithTotals.");
    }

    // =========================================================================
    // C04-03: Composable vault NAV inflation from gross return value
    //
    // An outer vault that calls innerVault.redeem() and records the return value
    // as its received assets will overcount by the fee amount on every redemption.
    // =========================================================================
    function test_C04_composable_vault_nav_inflation() public {
        console.log("=================================================================");
        console.log("C04-03: Composable vault records gross return value -- NAV inflated");
        console.log("=================================================================");

        // Setup: outer vault holds 100,000 inner vault shares
        // Outer vault calls innerVault.redeem() to liquidate the position
        // It trusts the return value to update its own totalAssets accounting
        uint256 aliceShares = vault.balanceOf(alice);

        // Outer vault tracking variable (mirrors how ERC4626 facets record received assets)
        uint256 outerVaultRecordedAssets = 0;
        uint256 outerVaultActualAssets = 0;

        uint256 assetBefore = asset.balanceOf(alice);

        console.log("Inner vault shares held:  ", aliceShares / 1e18);
        console.log("Inner vault withdrawalFee:", WITHDRAWAL_FEE, "bps (10%)");
        console.log("");

        // Simulate outer vault calling redeem and recording the return value
        vm.prank(alice);
        uint256 redeemReturnValue = vault.redeem(aliceShares, alice, alice);

        uint256 assetAfter = asset.balanceOf(alice);
        uint256 actualReceived = assetAfter - assetBefore;

        // Outer vault trusts the return value: this is what it would record
        outerVaultRecordedAssets = redeemReturnValue; // WRONG (gross)
        // But the actual assets it received:
        outerVaultActualAssets = actualReceived;      // CORRECT (net)

        uint256 navInflation = outerVaultRecordedAssets - outerVaultActualAssets;

        console.log("redeemReturnValue (what outer vault records):  ", outerVaultRecordedAssets / 1e18, "USDC");
        console.log("actualReceived    (real assets in outer vault):", outerVaultActualAssets / 1e18, "USDC");
        console.log("NAV inflation per redemption:                  ", navInflation / 1e18, "USDC");
        console.log("");
        console.log("Impact: outer vault NAV is overstated by", navInflation / 1e18, "USDC");
        console.log("Redemptions by outer vault LPs at inflated NAV cause losses to remaining LPs.");
        console.log("");

        assertGt(outerVaultRecordedAssets, outerVaultActualAssets,
            "BUG-03: outer vault records more assets than it received");

        assertApproxEqAbs(navInflation, DEPOSIT_AMOUNT * WITHDRAWAL_FEE / 10000, 1e15,
            "NAV inflation equals the full withdrawal fee amount");

        console.log("CONFIRMED: composable vault NAV inflated by", navInflation / 1e18, "USDC per redemption.");
        console.log("Any ERC4626 wrapper (including MORE nested vaults) is affected.");
    }

    // =========================================================================
    // C04-04 (FIX-01): After fixing redeem(), return value equals net transfer
    //
    // NOTE: Fix not applied to source. This test is EXPECTED TO FAIL without fix.
    //       Apply fix: add `assets = netAssets;` after _handleWithdrawal in redeem()
    // =========================================================================
    function test_C04_FIX01_redeem_returns_net_after_fix() public {
        console.log("=================================================================");
        console.log("C04-04 (FIX-01): redeem() should return net = actual transfer");
        console.log("=================================================================");

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 assetBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 returnedAssets = vault.redeem(aliceShares, alice, alice);

        uint256 actualTransferred = asset.balanceOf(alice) - assetBefore;
        uint256 expectedNet = DEPOSIT_AMOUNT * (10000 - WITHDRAWAL_FEE) / 10000;

        console.log("redeem() returned:", returnedAssets / 1e18);
        console.log("Alice received:   ", actualTransferred / 1e18);
        console.log("Expected net:     ", expectedNet / 1e18);

        // With Fix-01 applied: returnedAssets == actualTransferred (both net)
        // Without fix: this assertion FAILS because returnedAssets > actualTransferred
        assertEq(returnedAssets, actualTransferred,
            "FIX-01: redeem() return value must equal actual transfer (net)");

        assertApproxEqAbs(returnedAssets, expectedNet, 1e15,
            "FIX-01: return value ~ net assets (900 USDC)");

        console.log("PASS (with fix): redeem() correctly returns net assets.");
    }

    // =========================================================================
    // C04-05 (FIX-02): After fixing previewWithdraw(), it matches withdraw() burn
    //
    // NOTE: Fix not applied to source. This test is EXPECTED TO FAIL without fix.
    //       Apply fix: change previewWithdraw to use `assets` (gross) in conversion
    // =========================================================================
    function test_C04_FIX02_previewWithdraw_matches_withdraw_after_fix() public {
        console.log("=================================================================");
        console.log("C04-05 (FIX-02): previewWithdraw() must match withdraw() shares burned");
        console.log("=================================================================");

        vm.prank(alice);
        uint256 previewShares = vault.previewWithdraw(DEPOSIT_AMOUNT);

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice, alice);
        uint256 computedSharesBurned = aliceSharesBefore - vault.balanceOf(alice);

        console.log("previewWithdraw(1000 USDC):", previewShares / 1e18, "shares");
        console.log("withdraw(1000) burned:      ", computedSharesBurned / 1e18, "shares");

        // With Fix-02 applied: previewShares == computedSharesBurned (both use gross)
        // Without fix: previewShares < computedSharesBurned (preview uses net, withdraw uses gross)
        assertEq(previewShares, computedSharesBurned,
            "FIX-02: previewWithdraw must return the same shares that withdraw() burns");

        console.log("PASS (with fix): previewWithdraw correctly predicts withdraw() share burn.");
    }

    // --- Helpers ---

    function _mockRegistryAndOracle() internal {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(asset)),
            abi.encode(address(2000), uint96(1000))
        );
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(asset)));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), uint96(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector), abi.encode(address(escrow)));
    }

    function _mockFactory() internal {
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid)));
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), address(vault)),
            abi.encode(false)
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
    }
}
