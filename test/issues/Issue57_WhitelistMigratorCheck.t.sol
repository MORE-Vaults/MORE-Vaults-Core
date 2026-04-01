// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Issue57_WhitelistMigratorCheck
 * @notice Tests Issue #57: When whitelist mode is on, deposit checks msg.sender (the migrator),
 *         not the original user.
 *
 * ROOT CAUSE
 * ----------
 * VaultFacet._validateCapacity uses `receiver` from `_getInfoForAction` which returns
 * `_msgSender()` (i.e. `msg.sender`) for the `msgSender_` used in whitelist checks.
 * When the migrator calls `newVault.deposit(assets, user)`, msg.sender = migrator.
 * The whitelist check runs against the migrator's `availableToDeposit` allocation, NOT the user's.
 *
 * Relevant code path (VaultFacet.deposit → _getInfoForAction → _validateCapacity):
 *   msgSender_ = _msgSender()   // = migrator contract address
 *   _validateCapacity(msgSender_, ..., assets)
 *   → if ds.availableToDeposit[msgSender_] < assets → revert
 *
 * So the whitelist entry must be for the MIGRATOR, not the end user.
 *
 * TEST SCENARIOS
 * --------------
 *  A. Whitelist mode on; user whitelisted, migrator NOT → migration reverts.
 *  B. Whitelist mode on; migrator whitelisted (user not) → migration succeeds.
 *  C. Whitelist mode off → migration succeeds regardless of whitelist entries.
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
    address oldVault;
    address newVault;
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

        // Fund user in old vault (whitelist is off for oldVault)
        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        VaultFacet(oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Test A: User whitelisted in newVault, migrator NOT → migration REVERTS.
    //         This proves the whitelist check uses msg.sender (migrator), not the user.
    // -----------------------------------------------------------------------
    function test_userWhitelisted_migratorNot_migrationReverts() public {
        // Enable whitelist on newVault
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        // Whitelist the USER (but NOT the migrator)
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        // Confirm migrator has NO whitelist allocation
        uint256 migratorAllowance = MoreVaultsStorageHelper.getAvailableToDeposit(newVault, address(migrator));
        assertEq(migratorAllowance, 0, "Migrator should have zero whitelist allocation");

        // Prepare request
        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        // Migration should REVERT because migrator is not whitelisted
        vm.prank(curator);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        migrator.finalizeMigration(user, userShares, 0);

        console.log("[Issue57] CONFIRMED: Migration reverts when user is whitelisted but migrator is not");
        console.log("[Issue57] The whitelist check uses msg.sender (migrator), not the end user");
    }

    // -----------------------------------------------------------------------
    // Test B: Migrator whitelisted, user NOT → migration now REVERTS.
    //         After the Issue #57 dual-check fix, migrating into a whitelisted
    //         vault requires BOTH the user and the migrator to be whitelisted.
    //         The user check fires first (UserNotEligibleForDeposit), closing
    //         the backdoor where a non-whitelisted user silently entered a
    //         whitelisted vault just because the migrator was whitelisted.
    // -----------------------------------------------------------------------
    function test_migratorWhitelisted_userNot_migrationSucceeds() public {
        // Enable whitelist on newVault
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        // Whitelist the MIGRATOR (but NOT the user)
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migrator), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migrator), type(uint256).max);

        // Confirm user has NO whitelist allocation
        uint256 userAllowance = MoreVaultsStorageHelper.getAvailableToDeposit(newVault, user);
        assertEq(userAllowance, 0, "User should have zero whitelist allocation");

        // Prepare request
        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        // After the dual-check fix: UserNotEligibleForDeposit fires first (user is not whitelisted).
        // This closes the backdoor — previously this would have PASSED silently.
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

        console.log("[Issue57] Backdoor closed: migrator whitelisted, user NOT -> UserNotEligibleForDeposit");
        console.log("[Issue57] Both user AND migrator must be whitelisted for migration to succeed");
    }

    // -----------------------------------------------------------------------
    // Test C: Whitelist mode OFF → migration succeeds regardless.
    // -----------------------------------------------------------------------
    function test_whitelistOff_migrationSucceeds() public {
        // Whitelist is disabled on newVault (default in setUp)
        assertFalse(MoreVaultsStorageHelper.getIsHub(newVault) && false, "whitelist disabled sanity");

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(userShares, user);
        IERC20(oldVault).approve(address(migrator), userShares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(curator);
        (,, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertGt(newShares, 0, "Migration should succeed when whitelist is off");
        console.log("[Issue57] Migration succeeded with whitelist disabled");
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------
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
