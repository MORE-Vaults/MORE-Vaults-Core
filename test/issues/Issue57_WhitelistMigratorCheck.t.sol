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

// Documents the root cause of Issue #57:
// VaultFacet._validateCapacity checks msg.sender (migrator), not the receiver (user).
// So whitelist entries must be set for the migrator contract, not the end user.
contract Issue57_WhitelistMigratorCheck is Test {
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
        oldVault  = _deployVault(escrowOld);
        newVault  = _deployVault(escrowNew);
        escrowOld.setUnderlyingToken(oldVault, address(asset));
        escrowNew.setUnderlyingToken(newVault, address(asset));
        migrator = new MoreVaultMigrator(oldVault, newVault, owner, curator);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        VaultFacet(oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    // User whitelisted, migrator NOT → reverts because deposit checks msg.sender (migrator).
    function test_userWhitelisted_migratorNot_migrationReverts() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        assertEq(MoreVaultsStorageHelper.getAvailableToDeposit(newVault, address(migrator)), 0);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(curator);
        vm.expectRevert();
        migrator.finalizeMigration(user, userShares, 0);
    }

    // Migrator whitelisted, user NOT → reverts with UserNotEligibleForDeposit (dual-check fix).
    // Before the fix this would have passed silently — the backdoor.
    function test_migratorWhitelisted_userNot_migrationReverts() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        assertEq(MoreVaultsStorageHelper.getAvailableToDeposit(newVault, user), 0);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

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

    // Whitelist OFF → migration succeeds regardless.
    function test_whitelistOff_migrationSucceeds() public {
        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0);
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
    }

    function _deployVault(MockMoreVaultsEscrow escrow) internal returns (address vault) {
        VaultFacet facet = new VaultFacet();
        vault = address(facet);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setOwner(vault, owner);
        MoreVaultsStorageHelper.setFactory(vault, factory);

        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oReg));
        vm.mockCall(oReg, abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(asset)), abi.encode(address(0x9000), uint96(1 hours)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector), abi.encode(address(0), uint96(0)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
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
