// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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

// Issue #57: whitelist backdoor in MoreVaultMigrator.
//
// Root bug: VaultFacet._validateCapacity checked msg.sender (migrator), not receiver (user).
// A non-whitelisted user could be migrated into a whitelisted vault if the migrator was whitelisted.
//
// Fix (two-layer):
//   1. MoreVaultMigrator.finalizeMigration: pre-check maxDeposit(user) before redeem.
//   2. VaultFacet: when msg.sender == registry.migrator(), remap msgSender_ → receiver (user)
//      so _validateCapacity and _changeDepositCap operate on the user's quota.
//      The actual token payer remains the migrator contract (caller != _msgSender() branch).
//
// Consequence of the fix: the migrator no longer needs its own whitelist allocation.
// Only the user's quota is checked and consumed during the deposit.
contract Issue57WhitelistMigration is Test {
    address owner    = address(0xA11CE);
    address curator  = address(0xC0FFEE);
    address guardian = address(0x600D);
    address feeRecip = address(0xFEEF);
    address user     = address(0xB0B);
    address router   = address(0xBEEF01);
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

        // Critical: tell the vault who the registered migrator is so remap activates.
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.migrator.selector), abi.encode(address(migrator)));

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        VaultFacet(oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    function _setupUserRequest() internal returns (uint256 userShares) {
        userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
    }

    // Original bug scenario: migrator whitelisted, user NOT.
    // Fix (pre-check): UserNotEligibleForDeposit fires before any redeem.
    function test_backdoor_original_bug() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = _setupUserRequest();
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.UserNotEligibleForDeposit.selector,
                user, expectedAssets, uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);
    }

    // User not whitelisted, migrator whitelisted → pre-check blocks it before redeem.
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
                user, expectedAssets, uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);
    }

    // User whitelisted, migrator NOT whitelisted → migration SUCCEEDS.
    // After the fix, VaultFacet remaps msg.sender → receiver (user) for whitelist/cap checks,
    // so the migrator no longer needs its own whitelist allocation.
    function test_userWhitelisted_migratorNotWhitelisted_succeeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        // Migrator intentionally NOT whitelisted.

        uint256 userShares = _setupUserRequest();

        vm.prank(curator);
        (uint256 sharesMigrated,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "migration must succeed");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares, "user receives shares");
        assertEq(sharesMigrated, userShares, "all shares migrated");

        // Verify token flow: migrator paid, not the user.
        assertEq(IERC20(address(asset)).balanceOf(address(migrator)), 0, "migrator balance should be zero after deposit");
    }

    // Both whitelisted still works (migrator whitelist is now irrelevant but harmless).
    function test_bothWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        uint256 userShares = _setupUserRequest();

        vm.prank(curator);
        (uint256 sharesMigrated,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0);
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
        assertEq(sharesMigrated, userShares);
    }

    // No whitelist → always works.
    function test_whitelistDisabled_migrationSucceeds() public {
        uint256 userShares = _setupUserRequest();

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0);
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
    }

    // Pre-check revert fires before redeem — withdrawal request must be intact for retry.
    // Retry only needs user to be whitelisted (migrator whitelist no longer required).
    function test_failedMigration_preservesWithdrawalRequest() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        uint256 userShares = _setupUserRequest();
        (uint256 reqSharesBefore,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceBefore = VaultFacet(oldVault).balanceOf(user);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultMigrator.UserNotEligibleForDeposit.selector,
                user, expectedAssets, uint256(0)
            )
        );
        migrator.finalizeMigration(user, userShares, 0);

        (uint256 reqSharesAfter,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqSharesAfter, reqSharesBefore, "withdrawal request must be intact");
        assertEq(VaultFacet(oldVault).balanceOf(user), balanceBefore, "shares must be intact");

        // Retry: only whitelist user — migrator whitelist not required.
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);
        assertGt(newShares, 0, "retry must succeed with only user whitelisted");
    }

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
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector), abi.encode(address(0), uint96(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.migrator.selector), abi.encode(address(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector), abi.encode(address(escrow)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector), abi.encode(true));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid)));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector), abi.encode(false));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.getRestrictedFacets.selector), abi.encode(new address[](0)));

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
