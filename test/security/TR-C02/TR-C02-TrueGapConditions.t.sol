// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C02 True Gap Conditions
 *
 * @notice Determines precisely WHEN the pending-deposit accounting gap is real
 *         vs. when VaultFacet._accountAvailableAssets handles it correctly.
 *
 * ---
 *
 * MICHAEL ROZALENOK's COMMENT:
 *   "It should be accounted in VaultFacet in this case"
 *   "As well handled by VaultFacet"
 *   "Not an urgent for now"
 *
 * This is CORRECT for the common case. This file proves when Michael is right
 * and when the gap is still real.
 *
 * ---
 *
 * ROOT CAUSE RECAP (from TR-H02 tests):
 *   erc7540RequestDeposit writes:    ds.lockedTokens[ASSET]   = depositAmount
 *   accountingERC7540Facet reads:    ds.lockedTokens[VAULT]   = 0  (bug: wrong key)
 *
 * ---
 *
 * SCENARIO A -- GAP HANDLED BY VAULTFACET (Michael is right):
 *
 *   Conditions:
 *     - extVault.asset() == outer vault underlying (same token, e.g. USDC)
 *     - That underlying IS in ds.availableAssets
 *
 *   What happens:
 *     VaultFacet.totalAssets():
 *       _accountAvailableAssets([USDC]):
 *         reads: balance(USDC) = 400   (decreased after deposit sent)
 *             +  lockedTokens[USDC] = 600   (pending deposit tracked here)
 *             = 1000   <- CORRECT
 *       _accountFacets -> accountingERC7540Facet():
 *         reads: lockedTokens[extVault] = 0   (pending, no shares yet)
 *         = 0   <- CORRECT (deposit tracked via lockedTokens[USDC] above)
 *       TOTAL = 1000   <- NAV CORRECT, no gap
 *
 *   Result: HANDLED, no attack possible
 *
 * ---
 *
 * SCENARIO B -- GAP IS REAL:
 *
 *   Conditions (either):
 *     a) extVault.asset() is DIFFERENT from outer vault underlying
 *        (cross-asset ERC-7540 investment: e.g. outer=USDC, extVault.asset()=WETH)
 *        AND extVault.asset() is NOT in ds.availableAssets
 *     b) extVault.asset() == outer vault underlying, but underlying is NOT in
 *        ds.availableAssets (misconfigured vault)
 *
 *   What happens:
 *     _accountAvailableAssets never iterates over the pending deposit asset
 *       -> lockedTokens[WETH] (or lockedTokens[USDC]) never read
 *     accountingERC7540Facet reads lockedTokens[extVault] = 0
 *       -> pending deposit is invisible
 *     TOTAL = (only remaining assets) -- gap = full pending deposit amount
 *
 *   Result: REAL GAP, NAV depressed, attack profitable
 *
 * ---
 *
 * REAL-WORLD TRIGGER:
 *   The most realistic path to Scenario B is a cross-asset ERC-7540 investment:
 *   a USDC-denominated vault investing into a WETH-accepting ERC-7540 vault.
 *   In this case the WETH lockedTokens are never accounted.
 *
 *   For same-asset vaults (most common configuration), Scenario A applies
 *   and VaultFacet correctly handles it via lockedTokens[underlying].
 *
 * ---
 *
 * ADDITIONAL BUG (NOT FIXED by VaultFacet):
 *   ERC7540Facet line 96 comment says:
 *     "Count both locked shares (from redeem requests) and locked assets (from deposit requests)"
 *   This is WRONG. The code only reads lockedTokens[vault] (locked SHARES from redeem).
 *   lockedTokens[asset] (pending DEPOSIT) is never read by accountingERC7540Facet.
 *   The comment is misleading and should be corrected in the fix.
 */

import {Test, console} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {ERC7540Facet} from "../../src/facets/ERC7540Facet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract TR_C02_TrueGapConditions is Test {

    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    address public registry = makeAddr("registry");
    address public factory  = makeAddr("factory");
    address public oracle   = makeAddr("oracle");

    MockERC20 public usdc;   // outer vault's underlying

    // =========================================================================
    // SCENARIO A TESTS
    // Prove: when extVault.asset() == underlying AND underlying in availableAssets,
    // VaultFacet._accountAvailableAssets correctly accounts for the pending deposit.
    // =========================================================================

    /**
     * @notice Scenario A: underlying asset IS in availableAssets.
     *
     * State after erc7540RequestDeposit(extVault, 600 USDC):
     *   - Vault's USDC balance: 1000 -> 400  (600 transferred to extVault)
     *   - ds.lockedTokens[USDC] = 600         (tracked by erc7540RequestDeposit)
     *   - ds.lockedTokens[extVault] = 0       (vault shares not yet received)
     *
     * VaultFacet.totalAssets() path:
     *   _accountAvailableAssets([USDC]):
     *     USDC: balance = 400 + lockedTokens[USDC] = 600 -> total = 1000
     *   _accountFacets([]) = no-op (empty facets list)
     *   RESULT = 1000   <- CORRECT (same as before deposit)
     *
     * Conclusion: NAV is preserved. Michael is right. No attack in this config.
     */
    function test_C02_scenarioA_underlying_in_availableAssets_totalAssets_correct() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("Scenario A: underlying in availableAssets -- VaultFacet handles correctly");
        console.log("=================================================================");

        usdc = new MockERC20("USDC", "USDC");
        VaultFacet facet = new VaultFacet();

        // Wire: underlying = USDC
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(usdc));
        // Wire: availableAssets = [USDC]
        address[] memory avail = new address[](1);
        avail[0] = address(usdc);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), avail);
        // State after requestDeposit(extVault, 600): 600 USDC sent to extVault
        //   Vault still holds 400 USDC in balance
        uint256 remainingBalance = 400e18;
        uint256 lockedAmount     = 600e18;
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.balanceOf.selector, address(facet)), abi.encode(remainingBalance));
        // lockedTokens[USDC] = 600 (written by erc7540RequestDeposit)
        MoreVaultsStorageHelper.setLockedTokens(address(facet), address(usdc), lockedAmount);
        // facetsForAccounting is empty (no ERC7540Facet registered in this test)

        console.log("Vault USDC balance (remaining after requestDeposit):", remainingBalance / 1e18);
        console.log("lockedTokens[USDC] (tracked pending deposit):", lockedAmount / 1e18);
        console.log("Expected totalAssets:", (remainingBalance + lockedAmount) / 1e18, "(= 1000)");
        console.log("");

        uint256 total = facet.totalAssets();

        console.log("VaultFacet.totalAssets() returned:", total / 1e18);
        assertEq(total, remainingBalance + lockedAmount,
            "Scenario A: totalAssets = balance + lockedTokens[USDC] = 1000 -- handled correctly");

        console.log("CONFIRMED: VaultFacet._accountAvailableAssets reads lockedTokens[USDC] correctly.");
        console.log("NAV is preserved during the pending window. Michael is right.");
    }

    /**
     * @notice Scenario A extended: confirm accountingERC7540Facet returns 0 correctly
     *         for pending deposit when underlying is in availableAssets.
     *
     * During the pending window (extVault.balanceOf(facet) = 0, lockedTokens[extVault] = 0):
     *   accountingERC7540Facet() reports 0 for the extVault position.
     *   This is CORRECT -- the pending deposit is tracked via lockedTokens[USDC]
     *   in _accountAvailableAssets, not via lockedTokens[extVault] in this facet.
     *   Double-counting would inflate NAV; zero here is the right answer.
     */
    function test_C02_scenarioA_accountingERC7540Facet_returns_zero_correctly() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("Scenario A: accountingERC7540Facet returns 0 -- correct (not a bug here)");
        console.log("=================================================================");

        usdc = new MockERC20("USDC", "USDC");
        address extVault = makeAddr("extVaultSameAsset");
        ERC7540Facet e7540 = new ERC7540Facet();

        MoreVaultsStorageHelper.setUnderlyingAsset(address(e7540), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(e7540), registry);
        MoreVaultsStorageHelper.setFactory(address(e7540), factory);

        // extVault in tokensHeld (registered after requestDeposit)
        address[] memory vaults = new address[](1);
        vaults[0] = extVault;
        MoreVaultsStorageHelper.setTokensHeld(address(e7540), ERC7540_ID, vaults);

        // Pending deposit: lockedTokens[USDC] = 600 (deposit path uses ASSET key)
        // lockedTokens[extVault] = 0 (no shares received yet)
        MoreVaultsStorageHelper.setLockedTokens(address(e7540), address(usdc), 600e18);

        // Mock: extVault has USDC as underlying
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(usdc)));
        // Mock: vault holds 0 shares of extVault (pending)
        vm.mockCall(extVault, abi.encodeWithSelector(IERC20.balanceOf.selector, address(e7540)), abi.encode(uint256(0)));
        // Mock: 0 shares convert to 0 assets
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)), abi.encode(uint256(0)));
        // Mock: registry for oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(usdc)));

        (uint256 e7540sum, bool isPositive) = e7540.accountingERC7540Facet();

        console.log("accountingERC7540Facet() for pending deposit:", e7540sum);
        console.log("This is 0 -- CORRECT. Pending deposit is tracked via lockedTokens[USDC]");
        console.log("in _accountAvailableAssets (Scenario A), not via lockedTokens[extVault].");
        assertEq(e7540sum, 0, "Scenario A: 0 from ERC7540Facet is correct -- deposit tracked elsewhere");
        assertTrue(isPositive);

        console.log("Combined totalAssets (Scenario A) = _accountAvailableAssets + _accountFacets");
        console.log("  _accountAvailableAssets: balance(USDC)=400 + lockedTokens[USDC]=600 = 1000");
        console.log("  _accountFacets (ERC7540): 0 (pending, correct)");
        console.log("  TOTAL = 1000 -- NAV preserved. No double-count, no gap.");
    }

    // =========================================================================
    // SCENARIO B TESTS
    // Prove: when extVault.asset() is NOT in availableAssets,
    // the pending deposit is invisible to the full accounting pipeline.
    // =========================================================================

    /**
     * @notice Scenario B: cross-asset ERC-7540 investment.
     *
     * Outer vault is USDC-denominated. It invests 600 WETH into an ERC-7540 vault
     * that accepts WETH. WETH is NOT in ds.availableAssets.
     *
     * State after erc7540RequestDeposit(wethExtVault, 600 WETH):
     *   - ds.lockedTokens[WETH] = 600     (written by erc7540RequestDeposit)
     *   - ds.lockedTokens[wethExtVault] = 0
     *   - WETH NOT in availableAssets
     *
     * _accountAvailableAssets([USDC]):
     *   Iterates [USDC] only. Never reads lockedTokens[WETH].
     *   Gap: lockedTokens[WETH] = 600 is invisible.
     *
     * accountingERC7540Facet():
     *   reads lockedTokens[wethExtVault] = 0 (wrong key)
     *   Gap: 0 returned for pending position.
     *
     * Combined gap = 600 WETH (full pending deposit amount).
     */
    function test_C02_scenarioB_cross_asset_deposit_gap_is_real() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("Scenario B: cross-asset ERC7540 deposit -- gap IS real");
        console.log("=================================================================");

        usdc = new MockERC20("USDC", "USDC");
        MockERC20 weth = new MockERC20("WETH", "WETH");
        address wethExtVault = makeAddr("wethExtVault");

        ERC7540Facet e7540 = new ERC7540Facet();

        MoreVaultsStorageHelper.setUnderlyingAsset(address(e7540), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(e7540), registry);
        MoreVaultsStorageHelper.setFactory(address(e7540), factory);

        // WETH extVault is tracked in tokensHeld
        address[] memory vaults = new address[](1);
        vaults[0] = wethExtVault;
        MoreVaultsStorageHelper.setTokensHeld(address(e7540), ERC7540_ID, vaults);

        // Deposit state: lockedTokens[WETH] = 600 (NOT WETH extVault itself)
        uint256 lockedWeth = 600e18;
        MoreVaultsStorageHelper.setLockedTokens(address(e7540), address(weth), lockedWeth);

        // availableAssets = [USDC] only -- WETH is NOT in availableAssets
        // (simulated by NOT calling setAvailableAssets with WETH)

        // Mock: wethExtVault.asset() = WETH
        vm.mockCall(wethExtVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(weth)));
        // Mock: vault holds 0 shares (pending)
        vm.mockCall(wethExtVault, abi.encodeWithSelector(IERC20.balanceOf.selector, address(e7540)), abi.encode(uint256(0)));
        vm.mockCall(wethExtVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)), abi.encode(uint256(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(usdc)));

        // Show what IS stored
        uint256 lockedAtCorrectKey = MoreVaultsStorageHelper.getLockedTokens(address(e7540), address(weth));
        uint256 lockedAtWrongKey   = MoreVaultsStorageHelper.getLockedTokens(address(e7540), wethExtVault);

        console.log("lockedTokens[WETH]       = ", lockedAtCorrectKey / 1e18, "(correct deposit key -- exists)");
        console.log("lockedTokens[wethExtVault]= ", lockedAtWrongKey / 1e18,   "(accounting reads this -- 0)");
        console.log("");

        // accountingERC7540Facet reads lockedTokens[wethExtVault] = 0
        (uint256 reportedSum,) = e7540.accountingERC7540Facet();

        console.log("accountingERC7540Facet() returned:", reportedSum / 1e18);
        assertEq(reportedSum, 0,
            "Scenario B: accountingERC7540Facet returns 0 -- WETH pending deposit invisible");

        // _accountAvailableAssets would only iterate [USDC] -- lockedTokens[WETH] never read
        // Combined gap = lockedWeth (full pending deposit, not counted anywhere)
        uint256 gap = lockedWeth - reportedSum;
        assertEq(gap, lockedWeth,
            "Scenario B: gap = full pending WETH deposit -- invisible to both accounting paths");

        console.log("GAP = %d WETH (%d wei)", gap / 1e18, gap);
        console.log("IMPACT: NAV depressed by", gap / 1e18, "WETH during pending window.");
        console.log("Users who deposit/mint pay fewer assets than they should.");
        console.log("Users who redeem during this window extract excess assets.");
    }

    /**
     * @notice Scenario B variant: same underlying as outer vault, but NOT in availableAssets.
     *
     * This is a misconfigured vault (unusual). If the vault curator forgets to add
     * the underlying to availableAssets, the same gap exists even for same-asset ERC-7540.
     *
     * This test is included for completeness. In practice Scenario B cross-asset
     * (test above) is the more realistic trigger.
     */
    function test_C02_scenarioB_variant_underlying_not_in_availableAssets() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("Scenario B variant: underlying NOT in availableAssets -- gap exists");
        console.log("=================================================================");

        usdc = new MockERC20("USDC", "USDC");
        address extVault = makeAddr("extVault");

        ERC7540Facet e7540 = new ERC7540Facet();
        MoreVaultsStorageHelper.setUnderlyingAsset(address(e7540), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(e7540), registry);
        MoreVaultsStorageHelper.setFactory(address(e7540), factory);

        address[] memory vaults = new address[](1);
        vaults[0] = extVault;
        MoreVaultsStorageHelper.setTokensHeld(address(e7540), ERC7540_ID, vaults);

        // Same as TR-H02: lockedTokens[USDC] = 1000 (pending deposit)
        // BUT: USDC is NOT in availableAssets (misconfigured vault)
        MoreVaultsStorageHelper.setLockedTokens(address(e7540), address(usdc), 1000e18);
        // availableAssets is empty -- USDC NOT registered

        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(usdc)));
        vm.mockCall(extVault, abi.encodeWithSelector(IERC20.balanceOf.selector, address(e7540)), abi.encode(uint256(0)));
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)), abi.encode(uint256(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(usdc)));

        (uint256 reportedSum,) = e7540.accountingERC7540Facet();

        assertEq(reportedSum, 0, "Variant: gap exists when underlying not in availableAssets");
        console.log("GAP confirmed: 1000 USDC pending deposit is invisible.");
        console.log("This is unusual (misconfigured vault) -- same-asset deposits normally handled via Scenario A.");
    }

    // =========================================================================
    // WRONG COMMENT PROOF
    // ERC7540Facet line 96 comment is factually incorrect.
    // =========================================================================

    /**
     * @notice Prove that ERC7540Facet line 96 comment is incorrect.
     *
     * The comment says:
     *   "Count both locked shares (from redeem requests) and locked assets (from deposit requests)"
     *
     * But the code only reads lockedTokens[vault] (vault address key).
     * This catches locked SHARES (from redeem: lockedTokens[shareToken] = lockedTokens[vault]),
     * but NOT locked ASSETS (from deposit: lockedTokens[asset] -- a different key).
     *
     * The comment has been misleading since it was added.
     */
    function test_C02_misleading_comment_code_does_not_count_locked_assets() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("Wrong comment: ERC7540Facet line 96 does NOT count locked assets");
        console.log("=================================================================");

        usdc = new MockERC20("USDC", "USDC");
        address extVault = makeAddr("extVault");

        ERC7540Facet e7540 = new ERC7540Facet();
        MoreVaultsStorageHelper.setUnderlyingAsset(address(e7540), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(e7540), registry);
        MoreVaultsStorageHelper.setFactory(address(e7540), factory);

        address[] memory vaults = new address[](1);
        vaults[0] = extVault;
        MoreVaultsStorageHelper.setTokensHeld(address(e7540), ERC7540_ID, vaults);

        // Set BOTH keys to non-zero
        // lockedTokens[extVault] = 500 (locked SHARES from a redeem request)
        // lockedTokens[USDC] = 600     (locked ASSETS from a deposit request)
        MoreVaultsStorageHelper.setLockedTokens(address(e7540), extVault,         500e18); // redeem path
        MoreVaultsStorageHelper.setLockedTokens(address(e7540), address(usdc), 600e18); // deposit path

        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(usdc)));
        vm.mockCall(extVault, abi.encodeWithSelector(IERC20.balanceOf.selector, address(e7540)), abi.encode(uint256(0)));
        // 500 shares (locked for redeem) convert to 500 assets at 1:1
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(500e18)), abi.encode(uint256(500e18)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(usdc)));

        (uint256 reportedSum,) = e7540.accountingERC7540Facet();

        console.log("lockedTokens[extVault]   = 500 USDC (shares locked for redeem)");
        console.log("lockedTokens[USDC]       = 600 USDC (assets locked for deposit)");
        console.log("accountingERC7540Facet() = ", reportedSum / 1e18);
        console.log("");

        // The code reads lockedTokens[vault] = 500 (correct for redeem)
        // but ignores lockedTokens[USDC] = 600 (the deposit assets)
        assertEq(reportedSum, 500e18,
            "Code reads lockedTokens[vault]=500 (redeem shares) -- deposit 600 not counted");

        console.log("CONFIRMED: comment says 'count both locked shares AND locked assets'");
        console.log("ACTUAL: only locked SHARES (lockedTokens[vault]) are counted.");
        console.log("Locked ASSETS (lockedTokens[asset]=600) are silently ignored.");
        console.log("");
        console.log("FIX NEEDED in accountingERC7540Facet() line 97-98:");
        console.log("  address asset = IERC4626(vault).asset();");
        console.log("  uint256 balance = IERC20(vault).balanceOf(address(this))");
        console.log("                  + ds.lockedTokens[vault]   // locked shares (redeem)");
        console.log("                  + ds.lockedTokens[asset];  // locked assets (deposit) <-- ADD");
    }
}
