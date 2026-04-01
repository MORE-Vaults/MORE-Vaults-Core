// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Issue57WhitelistMigration
 * @notice Tests for the fix to Issue #57: whitelist backdoor in MoreVaultMigrator.
 *
 * BACKDOOR SCENARIO (pre-fix)
 * ---------------------------
 * If migrator is whitelisted in newVault but user is NOT, migration would PASS.
 * The non-whitelisted user would silently end up in a whitelisted vault.
 *
 * FIX: Dual pre-check in finalizeMigration (both run BEFORE the redeem):
 *   1. if (newVault.maxDeposit(user) < assetsToDeposit) revert UserNotEligibleForDeposit(...)
 *   2. if (newVault.maxDeposit(address(this)) < assetsToDeposit) revert MigratorNotEligibleForDeposit(...)
 *
 * WHY BOTH CHECKS
 * ---------------
 * - User check: closes the backdoor. Ensures only whitelisted users can migrate into
 *   a whitelisted vault.
 * - Migrator check: VaultFacet._validateCapacity uses msg.sender (= migrator) for the
 *   actual deposit. If the migrator lacks allocation, the deposit would fail.
 * - Both checks run BEFORE the redeem, so a revert preserves the user's withdrawal request.
 *
 * TEST SCENARIOS
 * --------------
 *  1. test_backdoor_original_bug          – demonstrates original bug; new code reverts with UserNotEligibleForDeposit
 *  2. test_userNotWhitelisted_migratorWhitelisted_reverts   – UserNotEligibleForDeposit
 *  3. test_userWhitelisted_migratorNotWhitelisted_reverts   – MigratorNotEligibleForDeposit
 *  4. test_bothWhitelisted_migrationSucceeds                – both whitelisted → success
 *  5. test_whitelistDisabled_migrationSucceeds              – whitelist off → success
 *  6. test_failedMigration_preservesWithdrawalRequest       – revert preserves request; retry succeeds
 */

import {Test, console} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";
import {MoreVaultMigrator} from "../../src/periphery/MoreVaultMigrator.sol";

contract Issue57WhitelistMigration is Test {
    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------
    address owner    = address(0xA11CE);
    address curator  = address(0xC0FFEE);
    address guardian = address(0x600D);
    address feeRecip = address(0xFEEF);
    address user     = address(0xB0B);
    address router   = address(0xBEEF01);

    // Mock external contracts
    address registry = address(0x1000);
    address factory  = address(0x1001);
    address oReg     = address(0x1002);

    MockERC20            asset;
    MockMoreVaultsEscrow escrowOld;
    MockMoreVaultsEscrow escrowNew;
    address              oldVault;
    address              newVault;
    MoreVaultMigrator    migrator;

    uint256 constant DEPOSIT_AMOUNT = 10_000e18;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        asset     = new MockERC20("Token", "TK");
        escrowOld = new MockMoreVaultsEscrow();
        escrowNew = new MockMoreVaultsEscrow();

        oldVault = _deployVault(escrowOld);
        newVault = _deployVault(escrowNew);

        escrowOld.setUnderlyingToken(oldVault, address(asset));
        escrowNew.setUnderlyingToken(newVault, address(asset));

        migrator = new MoreVaultMigrator(oldVault, newVault, owner, curator);

        // Fund user and deposit into oldVault (whitelist off for oldVault simplicity)
        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        VaultFacet(oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helper: set up user request and migrator approval
    // -------------------------------------------------------------------------
    function _setupUserRequest() internal returns (uint256 userShares) {
        userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
    }

    // -------------------------------------------------------------------------
    // Test 1: test_backdoor_original_bug
    //
    // Demonstrates the ORIGINAL BUG: migrator whitelisted, user NOT whitelisted.
    // Before the fix, this would PASS — a non-whitelisted user silently entering
    // a whitelisted vault.
    //
    // After the fix: reverts with UserNotEligibleForDeposit (user check fires first).
    // -------------------------------------------------------------------------
    function test_backdoor_original_bug() public {
        // BUG SETUP: Enable whitelist on newVault, whitelist ONLY the migrator.
        // The user has NO whitelist allocation.
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        // Confirm user has NO whitelist allocation
        assertEq(
            MoreVaultsStorageHelper.getAvailableToDeposit(newVault, user),
            0,
            "User should have zero whitelist allocation to reproduce the bug"
        );

        uint256 userShares = _setupUserRequest();
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        // PRE-FIX BEHAVIOR: this would have PASSED (backdoor).
        // Migration succeeded because vault checks migrator (msg.sender), not user.
        // Non-whitelisted user would silently end up in the whitelisted vault.
        //
        // POST-FIX BEHAVIOR: reverts with UserNotEligibleForDeposit.
        // The user check (maxDeposit(user)) runs first and catches this case.
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.UserNotEligibleForDeposit.selector,
                user,
                expectedAssets,
                uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);

        console.log("[Issue57-BUG] Original backdoor: migrator whitelisted, user NOT -> was PASS, now REVERTS");
        console.log("[Issue57-BUG] UserNotEligibleForDeposit closes the backdoor");
        console.log("[Issue57-BUG] assetsToDeposit:", expectedAssets);
    }

    // -------------------------------------------------------------------------
    // Test 2: test_userNotWhitelisted_migratorWhitelisted_reverts
    //
    // Same as the backdoor scenario. After the fix, UserNotEligibleForDeposit is
    // emitted (user check fires before migrator check).
    // -------------------------------------------------------------------------
    function test_userNotWhitelisted_migratorWhitelisted_reverts() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = _setupUserRequest();
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.UserNotEligibleForDeposit.selector,
                user,
                expectedAssets,
                uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);

        console.log("[Issue57-Fix] Test 2 PASSED: user NOT whitelisted, migrator whitelisted -> UserNotEligibleForDeposit");
    }

    // -------------------------------------------------------------------------
    // Test 3: test_userWhitelisted_migratorNotWhitelisted_reverts
    //
    // User IS whitelisted, migrator is NOT. User check passes; migrator check fails.
    // Reverts with MigratorNotEligibleForDeposit.
    // -------------------------------------------------------------------------
    function test_userWhitelisted_migratorNotWhitelisted_reverts() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        // Confirm migrator has NO whitelist allocation
        assertEq(
            MoreVaultsStorageHelper.getAvailableToDeposit(newVault, address(migrator)),
            0,
            "Migrator should have zero whitelist allocation"
        );

        uint256 userShares = _setupUserRequest();
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.MigratorNotEligibleForDeposit.selector,
                address(migrator),
                expectedAssets,
                uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);

        console.log("[Issue57-Fix] Test 3 PASSED: user whitelisted, migrator NOT -> MigratorNotEligibleForDeposit");
    }

    // -------------------------------------------------------------------------
    // Test 4: test_bothWhitelisted_migrationSucceeds
    //
    // Both user and migrator are whitelisted. Both checks pass; migration succeeds.
    // -------------------------------------------------------------------------
    function test_bothWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = _setupUserRequest();

        vm.prank(curator);
        (uint256 sharesMigrated,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed when both user and migrator are whitelisted");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares, "User should hold new vault shares");
        assertEq(sharesMigrated, userShares, "All shares should be migrated");

        console.log("[Issue57-Fix] Test 4 PASSED: both whitelisted -> migration succeeded");
        console.log("[Issue57-Fix] New shares minted:", newShares);
    }

    // -------------------------------------------------------------------------
    // Test 5: test_whitelistDisabled_migrationSucceeds
    //
    // Whitelist is disabled on newVault. maxDeposit returns type(uint256).max for
    // both user and migrator, so both checks pass trivially. Migration succeeds.
    // -------------------------------------------------------------------------
    function test_whitelistDisabled_migrationSucceeds() public {
        // Whitelist is disabled on newVault (default from setUp)
        // No whitelist entries needed

        uint256 userShares = _setupUserRequest();

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed when whitelist is disabled");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares, "User should hold new vault shares");

        console.log("[Issue57-Fix] Test 5 PASSED: whitelist disabled -> migration succeeded");
        console.log("[Issue57-Fix] New shares minted:", newShares);
    }

    // -------------------------------------------------------------------------
    // Test 6: test_failedMigration_preservesWithdrawalRequest
    //
    // When migration fails due to user not being whitelisted, the revert happens
    // BEFORE oldVault.redeem(), so the user's withdrawal request is preserved.
    // After fixing the whitelist, the curator can retry and migration succeeds.
    // -------------------------------------------------------------------------
    function test_failedMigration_preservesWithdrawalRequest() public {
        // Enable whitelist, neither user nor migrator whitelisted initially
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        uint256 userShares = _setupUserRequest();

        // Capture withdrawal request state BEFORE failed migration attempt
        (uint256 reqSharesBefore,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceBefore = VaultFacet(oldVault).balanceOf(user);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        // Attempt migration -- should revert with UserNotEligibleForDeposit (user check fires first)
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.UserNotEligibleForDeposit.selector,
                user,
                expectedAssets,
                uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);

        // Verify withdrawal request is UNCHANGED (pre-check fired before redeem)
        (uint256 reqSharesAfter,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceAfter = VaultFacet(oldVault).balanceOf(user);

        assertEq(reqSharesAfter, reqSharesBefore, "Withdrawal request shares must be unchanged after revert");
        assertEq(balanceAfter, balanceBefore, "User balance in old vault must be unchanged after revert");

        // Fix: whitelist BOTH the user and the migrator
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        // Retry -- should succeed
        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed after both are whitelisted");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares, "User should hold new shares");

        console.log("[Issue57-Fix] Test 6 PASSED: withdrawal request preserved after failed migration");
        console.log("[Issue57-Fix] Curator successfully retried after whitelisting both user and migrator");
        console.log("[Issue57-Fix] New shares after retry:", newShares);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------
    function _deployVault(MockMoreVaultsEscrow escrow) internal returns (address vault) {
        VaultFacet facet = new VaultFacet();
        vault = address(facet);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setOwner(vault, owner);
        MoreVaultsStorageHelper.setFactory(vault, factory);

        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oReg));
        vm.mockCall(
            oReg,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(asset)),
            abi.encode(address(0x9000), uint96(1 hours))
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), uint96(0))
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector),
            abi.encode(address(escrow))
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.localEid.selector),
            abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector),
            abi.encode(false)
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.getRestrictedFacets.selector),
            abi.encode(new address[](0))
        );

        bytes memory initData = abi.encode("Test Vault", "TV", address(asset), feeRecip, uint96(0), type(uint256).max);
        VaultFacet(vault).initialize(initData);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setCurator(vault, curator);
        MoreVaultsStorageHelper.setGuardian(vault, guardian);
        MoreVaultsStorageHelper.setIsHub(vault, true);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(vault, 1 days);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(vault, 7 days);
    }
}
