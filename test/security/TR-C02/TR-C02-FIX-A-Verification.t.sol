// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C02 Fix A Verification
 *
 * Fix A: Restrict erc7540RequestDeposit to same-underlying vaults only.
 *
 *   if (asset != MoreVaultsLib.getUnderlyingTokenAddress()) revert AssetMismatch();
 *
 * Added in ERC7540Facet.sol after line 116 (address asset = IERC4626(vault).asset()).
 *
 * WHY:
 *   Cross-asset deposits write lockedTokens[extVaultAsset]. That key is only read by
 *   _accountAvailableAssets IF the asset is in ds.availableAssets. For a foreign asset
 *   (e.g. WETH in a USDC vault), it never is. accountingERC7540Facet also misses it
 *   (reads lockedTokens[vault] = 0). The pending deposit becomes invisible.
 *
 *   Restricting to same-underlying guarantees that lockedTokens[asset] is always the
 *   vault's primary underlying, which IS in availableAssets. _accountAvailableAssets
 *   then handles it correctly (Scenario A). The accounting bug in accountingERC7540Facet
 *   still exists but becomes harmless for this specific case.
 *
 * TRADE-OFF:
 *   Cross-asset ERC-7540 investment (e.g. USDC vault depositing into a WETH ERC-7540 vault)
 *   is permanently blocked. If that use case is needed, use Fix B instead.
 *
 * FIX-A-01: Cross-asset deposit reverts with AssetMismatch
 * FIX-A-02: Same-underlying deposit still works
 * FIX-A-03: After same-underlying deposit, accounting remains correct (no gap)
 * FIX-A-04: Existing Scenario A behavior is unchanged
 */

import {Test, console} from "forge-std/Test.sol";
import {ERC7540Facet} from "../../../src/facets/ERC7540Facet.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {IERC7540Facet} from "../../../src/interfaces/facets/IERC7540Facet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7540} from "../../../src/interfaces/IERC7540.sol";

contract TR_C02_FixA_Verification is Test {

    // Fix A adds this error to ERC7540Facet (not present in unfixed code)
    error AssetMismatch();

    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    address public registry = makeAddr("registry");
    address public factory  = makeAddr("factory");

    MockERC20 public usdc;
    MockERC20 public weth;
    address   public extVaultSameAsset;   // extVault.asset() = USDC
    address   public extVaultCrossAsset;  // extVault.asset() = WETH

    ERC7540Facet public facet;

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
        extVaultSameAsset  = makeAddr("extVaultSameAsset");
        extVaultCrossAsset = makeAddr("extVaultCrossAsset");

        facet = new ERC7540Facet();

        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(usdc));
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);
        MoreVaultsStorageHelper.setFactory(address(facet), factory);

        // extVaultSameAsset.asset() = USDC (same as outer vault)
        vm.mockCall(extVaultSameAsset, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(usdc)));
        // extVaultCrossAsset.asset() = WETH (different from outer vault)
        vm.mockCall(extVaultCrossAsset, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(address(weth)));

        // whitelist both vaults (validateAddressWhitelisted calls registry.isWhitelisted)
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, extVaultSameAsset), abi.encode(true));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, extVaultCrossAsset), abi.encode(true));

        // mock requestDeposit (ERC-7540 external call) for same-asset vault
        vm.mockCall(
            extVaultSameAsset,
            abi.encodeWithSelector(IERC7540.requestDeposit.selector),
            abi.encode(uint256(1))
        );

        // mock USDC.forceApprove (called before requestDeposit)
        vm.mockCall(address(usdc), abi.encodeWithSelector(bytes4(keccak256("forceApprove(address,uint256)"))), abi.encode(true));
    }

    // =========================================================================
    // FIX-A-01: Cross-asset deposit reverts with AssetMismatch
    // =========================================================================
    function test_FIXA_cross_asset_deposit_reverts() public {
        console.log("=================================================================");
        console.log("FIX-A-01: Cross-asset deposit reverts with AssetMismatch");
        console.log("=================================================================");

        console.log("Outer vault underlying: USDC");
        console.log("extVaultCrossAsset.asset(): WETH");
        console.log("Expected: revert AssetMismatch()");

        // self-call pattern (validateDiamond requires msg.sender == address(this))
        vm.prank(address(facet));
        vm.expectRevert(AssetMismatch.selector);
        facet.erc7540RequestDeposit(extVaultCrossAsset, 600e18);

        console.log("PASS: AssetMismatch reverted. Cross-asset deposit blocked.");
        console.log("Scenario B is now impossible -- gap is eliminated at entry.");
    }

    // =========================================================================
    // FIX-A-02: Same-underlying deposit still works
    // =========================================================================
    function test_FIXA_same_underlying_deposit_succeeds() public {
        console.log("=================================================================");
        console.log("FIX-A-02: Same-underlying deposit succeeds normally");
        console.log("=================================================================");

        console.log("Outer vault underlying: USDC");
        console.log("extVaultSameAsset.asset(): USDC");
        console.log("Expected: no revert, lockedTokens[USDC] = 600");

        vm.prank(address(facet));
        uint256 requestId = facet.erc7540RequestDeposit(extVaultSameAsset, 600e18);

        uint256 locked = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(usdc));

        console.log("requestId:", requestId);
        console.log("lockedTokens[USDC]:", locked / 1e18);

        assertEq(locked, 600e18, "FIX-A-02: lockedTokens[USDC] = 600 after same-asset deposit");
        console.log("PASS: Same-underlying deposit works correctly.");
    }

    // =========================================================================
    // FIX-A-03: After same-underlying deposit, VaultFacet.totalAssets() is correct
    //
    // With Fix A applied, only same-underlying deposits are possible.
    // _accountAvailableAssets will always find lockedTokens[USDC] via availableAssets.
    // The accounting gap is impossible in this configuration.
    // =========================================================================
    function test_FIXA_totalAssets_no_gap_after_same_underlying_deposit() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        console.log("=================================================================");
        console.log("FIX-A-03: totalAssets correct after same-underlying deposit");
        console.log("=================================================================");

        VaultFacet vfacet = new VaultFacet();

        MoreVaultsStorageHelper.setUnderlyingAsset(address(vfacet), address(usdc));
        // USDC in availableAssets (normal vault configuration)
        address[] memory avail = new address[](1);
        avail[0] = address(usdc);
        MoreVaultsStorageHelper.setAvailableAssets(address(vfacet), avail);
        // After requestDeposit(extVault, 600): vault holds 400 USDC, 600 locked
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.balanceOf.selector, address(vfacet)), abi.encode(400e18));
        MoreVaultsStorageHelper.setLockedTokens(address(vfacet), address(usdc), 600e18);
        // facetsForAccounting empty (no ERC7540Facet in this test)

        uint256 total = vfacet.totalAssets();

        console.log("USDC balance (after deposit sent): 400");
        console.log("lockedTokens[USDC]: 600");
        console.log("VaultFacet.totalAssets():", total / 1e18);

        assertEq(total, 1000e18, "FIX-A-03: totalAssets = 1000 -- no gap");
        console.log("PASS: NAV preserved. With Fix A, Scenario B is unreachable.");
    }

    // =========================================================================
    // FIX-A-04: Scenario A behavior unchanged (existing correct path still works)
    // =========================================================================
    function test_FIXA_existing_scenarioA_behavior_unchanged() public {
        console.log("=================================================================");
        console.log("FIX-A-04: Scenario A unaffected -- Fix A does not change Scenario A");
        console.log("=================================================================");

        // Scenario A was already correct before Fix A.
        // Fix A only adds a restriction that makes Scenario B impossible.
        // Scenario A path: same-underlying, in availableAssets -- unchanged.

        vm.prank(address(facet));
        // Should succeed (same underlying) -- no revert
        facet.erc7540RequestDeposit(extVaultSameAsset, 100e18);

        uint256 locked = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(usdc));
        assertEq(locked, 100e18, "FIX-A-04: Scenario A path unaffected");
        console.log("PASS: Same-underlying deposit succeeds. Scenario A intact.");
    }
}
