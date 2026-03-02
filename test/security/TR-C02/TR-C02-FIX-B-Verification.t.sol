// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C02 Fix B Verification
 *
 * Fix B: Read lockedTokens[asset] in accountingERC7540Facet with a guard to avoid
 *        double-counting when the asset is already covered by _accountAvailableAssets.
 *
 *   // BEFORE:
 *   uint256 balance = IERC20(vault).balanceOf(address(this)) + ds.lockedTokens[vault];
 *
 *   // AFTER:
 *   uint256 lockedDeposit = ds.isAssetAvailable[asset] ? 0 : ds.lockedTokens[asset];
 *   uint256 balance = IERC20(vault).balanceOf(address(this)) + ds.lockedTokens[vault] + lockedDeposit;
 *
 * WHY THE GUARD:
 *   If asset IS in availableAssets, _accountAvailableAssets reads lockedTokens[asset] already.
 *   Adding it here again would inflate NAV. The guard prevents double-counting.
 *
 *   If asset is NOT in availableAssets (Scenario B: cross-asset, or misconfigured vault),
 *   lockedDeposit picks up the pending amount that would otherwise be invisible.
 *
 * TRADE-OFF vs Fix A:
 *   Fix B preserves cross-asset ERC-7540 functionality. More complex but more flexible.
 *   Requires the guard to be correct -- tested here.
 *
 * FIX-B-01: Scenario B gap eliminated -- cross-asset pending deposit now visible
 * FIX-B-02: Guard prevents double-count in Scenario A (asset in availableAssets)
 * FIX-B-03: Redeem path (lockedTokens[vault]) still works correctly
 * FIX-B-04: Both deposit and redeem pending simultaneously -- correct sum
 * FIX-B-05: Scenario B variant (same underlying, not in availableAssets) -- gap fixed
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC7540Facet} from "../../src/facets/ERC7540Facet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract TR_C02_FixB_Verification is Test {

    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    address public registry = makeAddr("registry");
    address public factory  = makeAddr("factory");
    address public oracle   = makeAddr("oracle");

    MockERC20 public usdc;
    MockERC20 public weth;

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");
        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
    }

    function _deployFacet() internal returns (ERC7540Facet facet) {
        facet = new ERC7540Facet();
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);
        MoreVaultsStorageHelper.setFactory(address(facet), factory);
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(address(usdc)));
    }

    function _setupExtVault(address facet, address extVault, address asset, uint256 lockedDeposit, uint256 lockedShares) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = extVault;
        MoreVaultsStorageHelper.setTokensHeld(address(facet), ERC7540_ID, vaults);

        // Set locked amounts
        if (lockedDeposit > 0) MoreVaultsStorageHelper.setLockedTokens(address(facet), asset, lockedDeposit);
        if (lockedShares > 0)  MoreVaultsStorageHelper.setLockedTokens(address(facet), extVault, lockedShares);

        // Mock vault calls
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(asset));
        vm.mockCall(extVault, abi.encodeWithSelector(IERC20.balanceOf.selector, address(facet)), abi.encode(uint256(0)));
        // convertToAssets(lockedShares) = lockedShares (1:1)
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, lockedShares), abi.encode(lockedShares));
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(0)), abi.encode(uint256(0)));
    }

    // =========================================================================
    // FIX-B-01: Scenario B gap eliminated
    // extVault.asset() == outer vault underlying (USDC), but USDC NOT in availableAssets.
    // Scenario B: lockedTokens[USDC] was invisible before Fix B.
    // Note: cross-asset (different tokens) follows the same fix logic but requires
    //       oracle mocks for convertToUnderlying. This test isolates the Fix B
    //       guard logic (isAssetAvailable check) without oracle complexity.
    // =========================================================================
    function test_FIXB_scenarioB_gap_eliminated_asset_not_in_availableAssets() public {
        console.log("=================================================================");
        console.log("FIX-B-01: Scenario B gap eliminated -- pending deposit now visible");
        console.log("=================================================================");

        ERC7540Facet facet = _deployFacet();
        address extVault = makeAddr("extVault");

        // extVault.asset() = USDC, USDC NOT in availableAssets (isAssetAvailable[USDC] = false)
        // lockedTokens[USDC] = 600 (pending deposit) -- previously invisible
        _setupExtVault(address(facet), extVault, address(usdc), 600e18, 0);
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, 600e18), abi.encode(600e18));

        (uint256 sum,) = facet.accountingERC7540Facet();

        console.log("lockedTokens[USDC]: 600");
        console.log("isAssetAvailable[USDC]: false  -- guard does NOT fire, lockedDeposit = 600");
        console.log("accountingERC7540Facet() returned (expected 600):", sum / 1e18);

        assertEq(sum, 600e18, "FIX-B-01: Scenario B gap eliminated, sum = 600");
        console.log("PASS: Pending deposit now visible. Gap closed for Scenario B.");
    }

    // =========================================================================
    // FIX-B-02: Guard prevents double-count in Scenario A
    // USDC extVault, USDC IS in availableAssets
    // accountingERC7540Facet must return 0 (lockedDeposit guard = 0)
    // _accountAvailableAssets handles lockedTokens[USDC] separately
    // =========================================================================
    function test_FIXB_scenarioA_no_double_count() public {
        console.log("=================================================================");
        console.log("FIX-B-02: Scenario A guard -- no double-count when asset in availableAssets");
        console.log("=================================================================");

        ERC7540Facet facet = _deployFacet();
        address usdcExtVault = makeAddr("usdcExtVault");

        // USDC IS in availableAssets
        MoreVaultsStorageHelper.setAssetAvailable(address(facet), address(usdc), true);

        // Pending deposit: lockedTokens[USDC] = 600
        _setupExtVault(address(facet), usdcExtVault, address(usdc), 600e18, 0);

        (uint256 sum,) = facet.accountingERC7540Facet();

        console.log("lockedTokens[USDC]: 600");
        console.log("isAssetAvailable[USDC]: true (guard active)");
        console.log("accountingERC7540Facet() returned (expected 0):", sum / 1e18);

        assertEq(sum, 0, "FIX-B-02: guard fires, lockedDeposit=0, no double-count");
        console.log("PASS: Guard prevents double-counting. _accountAvailableAssets handles USDC separately.");
    }

    // =========================================================================
    // FIX-B-03: Redeem path unaffected
    // lockedTokens[vault] (shares locked for redeem) still counted correctly
    // =========================================================================
    function test_FIXB_redeem_path_unaffected() public {
        console.log("=================================================================");
        console.log("FIX-B-03: Redeem path unaffected -- lockedTokens[vault] still works");
        console.log("=================================================================");

        ERC7540Facet facet = _deployFacet();
        address extVault = makeAddr("extVault");

        // USDC NOT in availableAssets, lockedShares = 500 (redeem pending), no deposit
        _setupExtVault(address(facet), extVault, address(usdc), 0, 500e18);

        (uint256 sum,) = facet.accountingERC7540Facet();

        console.log("lockedTokens[extVault] (shares): 500");
        console.log("lockedTokens[USDC] (deposit): 0");
        console.log("accountingERC7540Facet() returned (expected 500):", sum / 1e18);

        assertEq(sum, 500e18, "FIX-B-03: redeem path unchanged, locked shares counted");
        console.log("PASS: Redeem path (lockedTokens[vault]) works correctly. No regression.");
    }

    // =========================================================================
    // FIX-B-04: Both deposit and redeem pending simultaneously
    // lockedTokens[USDC] = 600 (deposit, USDC not in availableAssets)
    // lockedTokens[extVault] = 500 (redeem shares)
    // Expected: 600 + 500 = 1100
    // =========================================================================
    function test_FIXB_deposit_and_redeem_pending_simultaneously() public {
        console.log("=================================================================");
        console.log("FIX-B-04: Deposit + redeem pending simultaneously -- both counted");
        console.log("=================================================================");

        ERC7540Facet facet = _deployFacet();
        address extVault = makeAddr("extVault");

        // Both pending: lockedTokens[USDC]=600 (deposit), lockedTokens[extVault]=500 (redeem)
        // USDC NOT in availableAssets (so lockedDeposit = 600, not blocked by guard)
        _setupExtVault(address(facet), extVault, address(usdc), 600e18, 500e18);

        // convertToAssets(600 + 500 = 1100) = 1100 (1:1)
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, 1100e18), abi.encode(1100e18));

        (uint256 sum,) = facet.accountingERC7540Facet();

        console.log("lockedTokens[USDC] (deposit): 600");
        console.log("lockedTokens[extVault] (shares): 500");
        console.log("accountingERC7540Facet() returned (expected 1100):", sum / 1e18);

        assertEq(sum, 1100e18, "FIX-B-04: deposit + redeem both counted correctly");
        console.log("PASS: Both paths handled simultaneously.");
    }

    // =========================================================================
    // FIX-B-05: Scenario B variant -- same underlying, not in availableAssets
    // =========================================================================
    function test_FIXB_scenarioB_variant_same_underlying_not_in_availableAssets() public {
        console.log("=================================================================");
        console.log("FIX-B-05: Scenario B variant -- underlying not in availableAssets, gap fixed");
        console.log("=================================================================");

        ERC7540Facet facet = _deployFacet();
        address extVault = makeAddr("extVault");

        // USDC NOT in availableAssets (misconfigured) -- lockedDeposit guard will be false
        _setupExtVault(address(facet), extVault, address(usdc), 1000e18, 0);
        vm.mockCall(extVault, abi.encodeWithSelector(IERC4626.convertToAssets.selector, 1000e18), abi.encode(1000e18));

        (uint256 sum,) = facet.accountingERC7540Facet();

        console.log("lockedTokens[USDC]: 1000");
        console.log("isAssetAvailable[USDC]: false");
        console.log("accountingERC7540Facet() returned (expected 1000):", sum / 1e18);

        assertEq(sum, 1000e18, "FIX-B-05: Scenario B variant fixed, sum = 1000");
        console.log("PASS: Misconfigured vault gap also closed by Fix B.");
    }
}
