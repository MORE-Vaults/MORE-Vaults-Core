// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Issue57WhitelistMigration
 * @notice Tests for the fix to Issue #57: finalizeMigration now pre-checks newVault.maxDeposit(user)
 *         BEFORE the redeem, emitting a clear UserNotEligibleForDeposit error when the user has no
 *         whitelist allocation in the new vault.
 *
 * FIX LOCATION
 * ------------
 * src/periphery/MoreVaultMigrator.sol  (lines ~88-98)
 *
 *   uint256 assetsToDeposit = oldVault.previewRedeem(sharesMigrated);
 *   uint256 maxUserDeposit  = newVault.maxDeposit(user);
 *   if (maxUserDeposit < assetsToDeposit) {
 *       revert UserNotEligibleForDeposit(user, assetsToDeposit, maxUserDeposit);
 *   }
 *
 * WHY BEFORE THE REDEEM
 * ---------------------
 * Placing the check before oldVault.redeem() means that if it reverts, the user's withdrawal
 * request is NOT consumed — their position in the old vault is preserved.
 *
 * REMAINING LIMITATION (BACKDOOR)
 * --------------------------------
 * The new vault's deposit() still checks msg.sender (the migrator) against the whitelist,
 * NOT the user/receiver. So even with the pre-check passing (user whitelisted), the actual
 * deposit will revert if the MIGRATOR is not whitelisted. Conversely, if only the MIGRATOR
 * is whitelisted (user is not), maxDeposit(user) == 0 so our pre-check fires first — this
 * closes the backdoor at the migrator level: a non-whitelisted user cannot have their assets
 * migrated into the new vault even if the migrator itself is whitelisted.
 *
 * TEST SCENARIOS
 * --------------
 *  A. User NOT whitelisted, whitelist ON  → UserNotEligibleForDeposit, withdrawal request preserved
 *  B. User IS whitelisted, migrator IS whitelisted, whitelist ON → migration succeeds
 *  C. Whitelist OFF → migration succeeds regardless of whitelist entries
 *  D. Backdoor: migrator whitelisted, user NOT → pre-check fires UserNotEligibleForDeposit
 *  E. Revert does NOT consume the user's withdrawal request (safety property)
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
    // Test A: User NOT whitelisted, whitelist ON → clear revert BEFORE redeem
    // -------------------------------------------------------------------------
    function test_userNotWhitelisted_revertsWithClearError() public {
        // Enable whitelist on newVault — user has NO allocation
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        assertEq(
            MoreVaultsStorageHelper.getAvailableToDeposit(newVault, user),
            0,
            "User should have zero whitelist allocation"
        );

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        // Compute expected assetsToDeposit so we can match the error params
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

        console.log("[Issue57-Fix] Test A PASSED: clear UserNotEligibleForDeposit error emitted");
        console.log("[Issue57-Fix] assetsToDeposit:", expectedAssets);
    }

    // -------------------------------------------------------------------------
    // Test B: User IS whitelisted AND migrator IS whitelisted → migration succeeds
    // -------------------------------------------------------------------------
    function test_userAndMigratorWhitelisted_migrationSucceeds() public {
        // Enable whitelist on newVault
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        // Whitelist BOTH the user and the migrator
        // (user needs allocation for maxDeposit pre-check; migrator needs it for the actual deposit call)
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(curator);
        (uint256 sharesMigrated,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed when both user and migrator are whitelisted");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares, "User should hold new vault shares");
        assertEq(sharesMigrated, userShares, "All shares should be migrated");

        console.log("[Issue57-Fix] Test B PASSED: migration succeeded with user + migrator whitelisted");
        console.log("[Issue57-Fix] New shares minted:", newShares);
    }

    // -------------------------------------------------------------------------
    // Test C: Whitelist OFF → migration succeeds regardless of whitelist entries
    // -------------------------------------------------------------------------
    function test_whitelistOff_migrationSucceeds() public {
        // Whitelist disabled on newVault (default setUp state)
        // Whitelist the migrator in newVault since deposit still uses msg.sender check
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed when whitelist is disabled");
        console.log("[Issue57-Fix] Test C PASSED: migration succeeded with whitelist off");
    }

    // -------------------------------------------------------------------------
    // Test D: BACKDOOR CLOSED — migrator whitelisted but user NOT →
    //         pre-check fires UserNotEligibleForDeposit (user's funds protected)
    // -------------------------------------------------------------------------
    function test_migratorWhitelisted_userNotWhitelisted_backDoorClosed() public {
        // Enable whitelist on newVault
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        // Only whitelist the MIGRATOR, NOT the user
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        // Confirm user has NO whitelist allocation → maxDeposit(user) == 0
        assertEq(
            MoreVaultsStorageHelper.getAvailableToDeposit(newVault, user),
            0,
            "User should have zero whitelist allocation"
        );

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        // With the fix, the pre-check fires before the redeem — backdoor is CLOSED
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

        console.log("[Issue57-Fix] Test D PASSED: backdoor closed - migrator-whitelisted but user-not-whitelisted reverts");
        console.log("[Issue57-Fix] UserNotEligibleForDeposit fired before redeem");
    }

    // -------------------------------------------------------------------------
    // Test E: Revert does NOT consume the user's withdrawal request
    //         (funds are safe — user can retry after being whitelisted)
    // -------------------------------------------------------------------------
    function test_revertPreservesWithdrawalRequest() public {
        // Enable whitelist on newVault — user has NO allocation
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        // Capture withdrawal request state BEFORE failed migration attempt
        (uint256 reqSharesBefore,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceBefore = VaultFacet(oldVault).balanceOf(user);

        // Pre-compute expectedAssets BEFORE vm.prank to avoid consuming the prank
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        // Attempt migration — should revert
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(
            MoreVaultMigrator.UserNotEligibleForDeposit.selector,
            user,
            expectedAssets,
            uint256(0)
        ));
        migrator.finalizeMigration(user, userShares, 0);

        // Verify withdrawal request is UNCHANGED
        (uint256 reqSharesAfter,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceAfter = VaultFacet(oldVault).balanceOf(user);

        assertEq(reqSharesAfter, reqSharesBefore, "Withdrawal request shares must be unchanged after revert");
        assertEq(balanceAfter, balanceBefore, "User balance in old vault must be unchanged after revert");

        // Now whitelist the user AND migrator, retry — should succeed
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed after user is whitelisted");

        console.log("[Issue57-Fix] Test E PASSED: withdrawal request preserved after failed migration");
        console.log("[Issue57-Fix] User successfully retried after being whitelisted");
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
