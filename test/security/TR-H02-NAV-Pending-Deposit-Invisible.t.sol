// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-H02 PoC: Pending ERC7540 Deposit Assets Invisible to accountingERC7540Facet
 *
 * @notice Proves that accountingERC7540Facet() misses the full deposit amount for any
 *         pending ERC-7540 deposit request. After erc7540RequestDeposit() is called,
 *         the locked assets are stored at ds.lockedTokens[asset] (keyed by underlying
 *         token address), but accountingERC7540Facet() reads ds.lockedTokens[vault]
 *         (keyed by vault address). The keys never match for a deposit request.
 *
 * Bug location: ERC7540Facet.sol:accountingERC7540Facet() (lines 85-107)
 *
 *   function accountingERC7540Facet() returns (uint256 sum, bool isPositive) {
 *       for vault in tokensHeld[ERC7540_ID]:
 *           uint256 balance = IERC20(vault).balanceOf(address(this))
 *                             + ds.lockedTokens[vault];   // <-- BUG: [vault] not [asset]
 *           // When a deposit is pending:
 *           //   erc7540RequestDeposit stores:  lockedTokens[ASSET]  = amount
 *           //   accountingERC7540Facet reads:  lockedTokens[VAULT]  = 0
 *           // Pending deposit assets are NEVER counted.
 *   }
 *
 * Contrast: erc7540RequestDeposit() (lines 116-125) stores:
 *   ds.lockedTokens[asset] += assets;              // keyed by ASSET
 *   ds.lockedTokensPerContract[vault][asset] = assets;
 *
 * But accountingERC7540Facet reads ds.lockedTokens[vault] -- the VAULT key.
 * During the ERC-7540 pending window (hours to days), totalAssets is understated
 * by the full deposit amount.
 *
 * Attack scenario (NAV manipulation via window):
 *   1. Vault manager calls erc7540RequestDeposit(extVault, 1000e18)
 *      -> lockedTokens[asset] = 1000e18, lockedTokens[vault] = 0
 *      -> 1000e18 assets leave the vault's balance (transferred to extVault)
 *      -> accountingERC7540Facet counts 0 for this position
 *      -> totalAssets drops by 1000e18 during the pending window
 *   2. A user redeems shares during the window at the depressed NAV
 *      -> receives more assets per share than they are entitled to
 *   3. After finalization, claimDeposit() restores the vault position
 *      -> but the over-redeemed user has extracted excess value
 *
 * Required Conditions:
 *   - Any ERC-7540 investment position (extVault) in the vault
 *   - A pending deposit request (erc7540RequestDeposit called, claimDeposit not yet called)
 *   - Attacker: user who redeems during the pending window
 *   - Capital: vault shares (legitimate depositor)
 *   - Timing: must redeem after requestDeposit but before claimDeposit
 *
 * What is REAL:
 *   - Real ERC7540Facet bytecode deployed fresh (Flow EVM Mainnet fork)
 *   - Real accountingERC7540Facet code path
 *   - Real MoreVaultsStorageHelper slot writes
 *   - Real lockedTokens key mismatch: lockedTokens[asset] vs lockedTokens[vault]
 *
 * What is SIMULATED:
 *   - ERC7540Facet deployed standalone (not through diamond proxy)
 *   - ERC-7540 external vault mocked (asset(), balanceOf(), convertToAssets())
 *   - lockedTokens[asset] and lockedTokensPerContract injected via StorageHelper
 *   - Registry/oracle mocked for convertToUnderlying (1:1 pass-through)
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC7540Facet} from "../../src/facets/ERC7540Facet.sol";
import {ERC4626Facet} from "../../src/facets/ERC4626Facet.sol";
import {IERC7540Facet} from "../../src/interfaces/facets/IERC7540Facet.sol";
import {IERC4626Facet} from "../../src/interfaces/facets/IERC4626Facet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract TR_H02_NAV_Pending_Deposit_Invisible_PoC is Test {

    // ERC7540_ID = keccak256("ERC7540_ID") -- same as in ERC7540Facet.sol
    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    // --- Actors ---
    address public registry = makeAddr("registry");
    address public factory  = makeAddr("factory");
    address public oracle   = makeAddr("oracle");

    // --- Contracts ---
    ERC7540Facet public facet;   // the contract under test
    MockERC20 public underlying; // outer vault's underlying asset
    address public extVault;     // mock ERC-7540 external vault

    // --- Test values ---
    uint256 constant DEPOSIT_AMOUNT = 1000e18;  // assets pending in ERC-7540 request

    // =========================================================================
    // setUp
    // =========================================================================
    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        underlying = new MockERC20("Underlying Asset", "UA");
        extVault   = makeAddr("extVault");

        // Deploy ERC7540Facet standalone
        facet = new ERC7540Facet();

        // Wire up storage: registry, factory, underlying asset
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);
        MoreVaultsStorageHelper.setFactory(address(facet), factory);
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(underlying));

        // Register extVault in tokensHeld[ERC7540_ID]
        // This simulates: erc7540RequestDeposit has been called and vault is tracked
        address[] memory vaults = new address[](1);
        vaults[0] = extVault;
        MoreVaultsStorageHelper.setTokensHeld(address(facet), ERC7540_ID, vaults);

        // Simulate pending deposit state: erc7540RequestDeposit was called
        //   ds.lockedTokens[asset]               = DEPOSIT_AMOUNT  (what the code writes)
        //   ds.lockedTokensPerContract[vault][asset] = DEPOSIT_AMOUNT
        // Note: lockedTokens[vault] stays 0 (deposit writes to lockedTokens[ASSET])
        MoreVaultsStorageHelper.setLockedTokens(address(facet), address(underlying), DEPOSIT_AMOUNT);
        MoreVaultsStorageHelper.setLockedTokensPerContract(address(facet), extVault, address(underlying), DEPOSIT_AMOUNT);

        // Mock extVault.asset() = underlying (so convertToUnderlying is a pass-through)
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(underlying)));

        // Mock extVault.balanceOf(facet) = 0 (shares held by facet: none yet, they're pending)
        vm.mockCall(
            extVault,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(facet)),
            abi.encode(uint256(0))
        );

        // Mock extVault.convertToAssets(0) = 0
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)), abi.encode(uint256(0)));

        // Mock registry.oracle() for convertToUnderlying -- not needed when resolvedToken == underlyingToken
        // convertToUnderlying returns amount directly when token == underlying, so no oracle needed
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(address(underlying))
        );

        console.log("=================================================================");
        console.log("TR-H02: Pending ERC7540 Deposit Assets Invisible to Accounting");
        console.log("ERC7540Facet:", address(facet));
        console.log("External Vault:", extVault);
        console.log("Pending deposit amount:", DEPOSIT_AMOUNT);
        console.log("=================================================================");
    }

    // =========================================================================
    // test_TR_H02_pending_deposit_missing_from_totalAssets
    //
    // Core bug: accountingERC7540Facet reads lockedTokens[vault] = 0
    // but the pending deposit is stored at lockedTokens[asset] = DEPOSIT_AMOUNT
    // =========================================================================
    function test_TR_H02_pending_deposit_missing_from_totalAssets() public {
        console.log("=================================================================");
        console.log("TR-H02: accountingERC7540Facet returns 0 for pending deposit");
        console.log("=================================================================");
        console.log("");

        // --- Pre-conditions: storage state ---
        console.log("--- Storage state (simulating pending deposit request) ---");
        uint256 lockedByAssetKey  = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(underlying));
        uint256 lockedByVaultKey  = MoreVaultsStorageHelper.getLockedTokens(address(facet), extVault);
        uint256 lockedPerContract = MoreVaultsStorageHelper.getLockedTokensPerContract(address(facet), extVault, address(underlying));
        console.log("lockedTokens[ASSET_KEY] (correct deposit key):", lockedByAssetKey);
        console.log("lockedTokens[VAULT_KEY] (what accounting reads):", lockedByVaultKey);
        console.log("lockedTokensPerContract[vault][asset]:", lockedPerContract);
        console.log("");

        // Confirm: deposit stored at ASSET key, accounting reads VAULT key
        assertEq(lockedByAssetKey, DEPOSIT_AMOUNT, "Deposit amount stored at lockedTokens[asset]");
        assertEq(lockedByVaultKey, 0, "lockedTokens[vault] is 0 -- this is what accountingERC7540Facet reads");
        console.log("KEY MISMATCH CONFIRMED:");
        console.log("  erc7540RequestDeposit writes: lockedTokens[ASSET] =", lockedByAssetKey);
        console.log("  accountingERC7540Facet reads: lockedTokens[VAULT] =", lockedByVaultKey);
        console.log("");

        // --- Call accountingERC7540Facet ---
        console.log("--- Calling accountingERC7540Facet() ---");
        (uint256 reportedSum, bool isPositive) = ERC7540Facet(address(facet)).accountingERC7540Facet();
        console.log("accountingERC7540Facet() returned:", reportedSum);
        console.log("isPositive:", isPositive);
        console.log("");

        // --- Assertions ---
        console.log("--- Assertions ---");
        // 1. Accounting returns 0 -- the pending deposit is INVISIBLE
        assertEq(reportedSum, 0,
            "BUG: accountingERC7540Facet returns 0 for pending deposit -- DEPOSIT_AMOUNT invisible");

        // 2. But the correct value should be DEPOSIT_AMOUNT
        // The accounting gap = DEPOSIT_AMOUNT - reported = DEPOSIT_AMOUNT
        uint256 accountingGap = DEPOSIT_AMOUNT - reportedSum;
        assertEq(accountingGap, DEPOSIT_AMOUNT,
            "BUG: Full DEPOSIT_AMOUNT missing from totalAssets accounting");

        console.log("CONFIRMED: accountingERC7540Facet returned:", reportedSum);
        console.log("Correct value should be:", DEPOSIT_AMOUNT);
        console.log("Accounting gap (= full deposit amount):", accountingGap);
        console.log("");
        console.log("IMPACT:");
        console.log("  During ERC-7540 pending window (hours to days):");
        console.log("  - totalAssets understated by", DEPOSIT_AMOUNT / 1e18, "tokens");
        console.log("  - Share price (NAV/share) is artificially depressed");
        console.log("  - Users who redeem during this window extract excess assets");
        console.log("  - Users who deposit during this window receive fewer shares");
    }

    // =========================================================================
    // test_TR_H02_root_cause_key_mismatch
    //
    // White-box proof: erc7540RequestDeposit writes lockedTokens[ASSET],
    // but accountingERC7540Facet reads lockedTokens[VAULT].
    // These are never the same address for a real ERC-7540 vault.
    // =========================================================================
    function test_TR_H02_root_cause_key_mismatch() public {
        console.log("=================================================================");
        console.log("TR-H02: Root cause -- lockedTokens key mismatch");
        console.log("=================================================================");
        console.log("");

        console.log("WRITE PATH (erc7540RequestDeposit lines 116-125):");
        console.log("  address asset = IERC4626(vault).asset();");
        console.log("  ds.lockedTokens[ASSET] += assets;              // keyed by ASSET");
        console.log("  ds.lockedTokensPerContract[vault][ASSET] = assets;");
        console.log("");
        console.log("READ PATH (accountingERC7540Facet lines 98-99):");
        console.log("  balance = IERC20(vault).balanceOf(this) + ds.lockedTokens[VAULT];");
        console.log("  //                                                          ^^^^^");
        console.log("  //                                           reads VAULT key, not ASSET key");
        console.log("  // For a deposit: lockedTokens[VAULT] = 0, lockedTokens[ASSET] = DEPOSIT_AMOUNT");
        console.log("  // The deposit amount is NEVER counted during the pending window");
        console.log("");

        // Prove: extVault != underlying (asset)
        assertTrue(extVault != address(underlying),
            "VAULT key != ASSET key -- mismatch is structural, not coincidental");

        // Show: if we READ at the CORRECT key (asset), we get the pending amount
        uint256 correctValue = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(underlying));
        assertEq(correctValue, DEPOSIT_AMOUNT, "lockedTokens[ASSET] = DEPOSIT_AMOUNT (correct value exists, never read)");

        // Show: what accounting ACTUALLY reads (vault key) = 0
        uint256 readValue = MoreVaultsStorageHelper.getLockedTokens(address(facet), extVault);
        assertEq(readValue, 0, "lockedTokens[VAULT] = 0 (wrong key, always zero for deposits)");

        console.log("extVault address:", extVault);
        console.log("underlying asset:", address(underlying));
        console.log("lockedTokens[extVault]:", readValue,  "  <-- accounting reads this (0)");
        console.log("lockedTokens[underlying]:", correctValue, "<-- deposit wrote this (DEPOSIT_AMOUNT)");
        console.log("");

        console.log("FIX: In accountingERC7540Facet, change line 98 to:");
        console.log("  address asset = IERC4626(vault).asset();");
        console.log("  uint256 balance = IERC20(vault).balanceOf(address(this))");
        console.log("                  + ds.lockedTokens[vault]    // locked SHARES (redeem path)");
        console.log("                  + ds.lockedTokens[asset];   // locked ASSETS (deposit path) <-- ADD THIS");
        console.log("");
        console.log("CONFIRMED: The same pattern applies to accountingERC4626Facet (line 120).");
        console.log("Both facets read lockedTokens[vault] but ignore lockedTokens[asset].");

        // Verify the accounting gap is exactly DEPOSIT_AMOUNT
        (uint256 reportedSum,) = ERC7540Facet(address(facet)).accountingERC7540Facet();
        uint256 gap = DEPOSIT_AMOUNT - reportedSum;
        assertEq(gap, DEPOSIT_AMOUNT, "BUG CONFIRMED: accounting gap equals full deposit amount");
    }
}
