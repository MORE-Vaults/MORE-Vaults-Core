// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

/**
 * @title Issue57MigratorFix
 * @notice Attack / regression tests for the migrator msgSender_ remapping fix.
 *
 * The fix adds a second special-case in _getInfoForAction:
 *   if (msgSender_ == registry.migrator()) msgSender_ = receiver;
 *
 * This means the registered migrator's deposits consume the RECEIVER's quota,
 * not the migrator's own quota — mirroring the existing router behaviour.
 *
 * Key mechanics (from VaultFacet):
 *   - _validateCapacity(msgSender_, ...) checks msgSender_'s quota, and emits
 *     ERC4626ExceededMaxDeposit(msgSender_, ...) on failure.
 *   - After the fix, for the real migrator: msgSender_ = receiver (victim).
 *   - For any other caller: msgSender_ = caller (not remapped).
 */
contract Issue57MigratorFix is Test {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public facet;
    address public registry     = address(0x1000);
    address public vaultFactory = address(0x1001);
    address public oracleReg    = address(0x1002);
    address public oracle       = address(0x1003);

    address public vaultOwner = address(0x9999);
    address public migrator   = address(0xBEEF);
    address public router     = address(0xCAFE);
    address public victim     = address(0x1111);
    address public attacker   = address(0x2222);

    address public asset;
    MockMoreVaultsEscrow public escrow;

    string constant VAULT_NAME      = "Test Vault";
    string constant VAULT_SYMBOL    = "TV";
    uint96  constant FEE            = 0;
    uint256 constant DEPOSIT_CAP    = 1_000_000 ether;
    uint256 constant USER_QUOTA     = 10_000 ether;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        // Deploy facet (used directly, not through Diamond proxy)
        VaultFacet vaultFacet = new VaultFacet();
        facet = address(vaultFacet);

        // Deploy mock asset
        MockERC20 mockAsset = new MockERC20("Test Asset", "TA");
        asset = address(mockAsset);

        // Deploy mock escrow
        escrow = new MockMoreVaultsEscrow();
        escrow.setUnderlyingToken(facet, asset);

        // Storage bootstrap (before init)
        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setOwner(facet, vaultOwner);
        MoreVaultsStorageHelper.setFactory(facet, vaultFactory);

        // Oracle mocks required by initialize()
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleReg));
        vm.mockCall(
            oracleReg,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(0x2000), uint96(1000))
        );

        // Initialize vault
        bytes memory initData = abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, address(0x5555), FEE, DEPOSIT_CAP);
        VaultFacet(facet).initialize(initData);

        // Post-init storage setup
        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setIsHub(facet, true);

        // Registry mocks
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector),   abi.encode(router));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.migrator.selector), abi.encode(migrator));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector),   abi.encode(address(escrow)));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"),            abi.encode(address(0), uint96(0)));

        // Factory mocks (non-cross-chain hub)
        vm.mockCall(vaultFactory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid)));
        vm.mockCall(
            vaultFactory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), facet),
            abi.encode(false)
        );
        uint32[] memory eids   = new uint32[](0);
        address[] memory vaultArr = new address[](0);
        vm.mockCall(vaultFactory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaultArr));

        // Enable whitelist; only victim has quota
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, victim, USER_QUOTA);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, victim, USER_QUOTA);

        // Fund addresses and approve
        MockERC20(asset).mint(migrator, DEPOSIT_CAP);
        MockERC20(asset).mint(victim,   DEPOSIT_CAP);
        MockERC20(asset).mint(attacker, DEPOSIT_CAP);

        vm.prank(migrator); IERC20(asset).approve(facet, type(uint256).max);
        vm.prank(victim);   IERC20(asset).approve(facet, type(uint256).max);
        vm.prank(attacker); IERC20(asset).approve(facet, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helper
    // -------------------------------------------------------------------------

    function _quota(address who) internal view returns (uint256) {
        return MoreVaultsStorageHelper.getAvailableToDeposit(facet, who);
    }

    // =========================================================================
    // Test 1: Normal migration works
    // Migrator deposits for victim → victim's quota consumed, migrator's quota untouched.
    // =========================================================================

    function test_migration_consumesReceiverQuota() public {
        uint256 depositAmount = 1_000 ether;

        uint256 victimBefore   = _quota(victim);
        uint256 migratorBefore = _quota(migrator);

        vm.prank(migrator);
        VaultFacet(facet).deposit(depositAmount, victim);

        assertEq(_quota(victim),   victimBefore - depositAmount, "victim quota should decrease by deposit");
        assertEq(_quota(migrator), migratorBefore,               "migrator quota should not change");
        // Victim received shares
        assertGt(IERC20(facet).balanceOf(victim), 0, "victim should receive shares");
    }

    // =========================================================================
    // Test 2: Attack — random EOA impersonating migrator
    // Random EOA calls deposit(assets, victim). Not remapped → msgSender_ = fakeEOA.
    // _validateCapacity checks fakeEOA quota (0) → reverts with ERC4626ExceededMaxDeposit(fakeEOA, ...).
    // Victim quota stays intact.
    // =========================================================================

    function test_attack_randomEOA_cannotConsumeVictimQuota() public {
        address fakeEOA = address(0x3333);
        MockERC20(asset).mint(fakeEOA, 1_000 ether);
        vm.prank(fakeEOA);
        IERC20(asset).approve(facet, type(uint256).max);

        uint256 victimBefore = _quota(victim);

        // fakeEOA is not the registered migrator, so msgSender_ = fakeEOA (0 quota) → revert
        vm.prank(fakeEOA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                fakeEOA,   // msgSender_ after no-remap = fakeEOA
                1_000 ether,
                0
            )
        );
        VaultFacet(facet).deposit(1_000 ether, victim);

        assertEq(_quota(victim), victimBefore, "victim quota must remain unchanged");
    }

    // =========================================================================
    // Test 3: Attack — unregistered contract calling deposit
    // Same as Test 2 but from a contract.
    // =========================================================================

    function test_attack_unregisteredContract_cannotConsumeVictimQuota() public {
        FakeMigratorContract fakeContract = new FakeMigratorContract(facet, asset);
        MockERC20(asset).mint(address(fakeContract), 1_000 ether);

        uint256 victimBefore = _quota(victim);

        // fakeContract is not the registered migrator, so msgSender_ = fakeContract (0 quota) → revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                address(fakeContract),  // msgSender_ = fakeContract
                1_000 ether,
                0
            )
        );
        fakeContract.depositForVictim(1_000 ether, victim);

        assertEq(_quota(victim), victimBefore, "victim quota must remain unchanged");
    }

    // =========================================================================
    // Test 4: Attack — migrator depositing for itself (receiver == migrator)
    // After remapping: msgSender_ = receiver = migrator.
    // _validateCapacity checks migrator's quota (0) → revert.
    // Fix does NOT grant migrator a free pass to deposit for itself.
    // =========================================================================

    function test_attack_migratorDepositForItself_usesOwnQuota() public {
        assertEq(_quota(migrator), 0, "precondition: migrator has zero quota");

        // msgSender_ remapped to receiver = migrator → migrator has 0 quota → revert
        vm.prank(migrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                migrator,    // msgSender_ = remapped to receiver = migrator
                1_000 ether,
                0
            )
        );
        VaultFacet(facet).deposit(1_000 ether, migrator);
    }

    // =========================================================================
    // Test 5: Attack — quota exhaustion griefing via fake migrator contract
    // Attacker deploys a contract and tries to exhaust victim's quota.
    // Not the registered migrator → fails immediately.
    // =========================================================================

    function test_attack_fakeMigratorGriefing_fails() public {
        FakeMigratorContract fakeMigrator = new FakeMigratorContract(facet, asset);
        MockERC20(asset).mint(address(fakeMigrator), USER_QUOTA);

        uint256 victimBefore = _quota(victim);

        // fakeMigrator is NOT registered → msgSender_ = address(fakeMigrator), quota = 0 → revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                address(fakeMigrator),
                USER_QUOTA,
                0
            )
        );
        fakeMigrator.depositForVictim(USER_QUOTA, victim);

        assertEq(_quota(victim), victimBefore, "victim quota must remain unchanged after griefing attempt");
    }

    // =========================================================================
    // Test 6: Attack — double deposit after migration
    // Migrator fully consumes victim quota, then victim tries to deposit more.
    // Second deposit must revert — victim's quota is fully exhausted.
    // =========================================================================

    function test_attack_doubleDeposit_afterMigration_reverts() public {
        // Migrator fully consumes victim's quota
        vm.prank(migrator);
        VaultFacet(facet).deposit(USER_QUOTA, victim);

        assertEq(_quota(victim), 0, "victim quota should be zero after full migration");

        // Victim tries to deposit 1 wei more → reverts (msgSender_ = victim, quota = 0)
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                victim,
                1,
                0
            )
        );
        VaultFacet(facet).deposit(1, victim);
    }

    // =========================================================================
    // Test 7: Migrator address(0) edge case
    // When migrator is not set (address(0)), no real caller matches → no privilege given.
    // =========================================================================

    function test_migratorAddressZero_noSideEffects() public {
        // Override: migrator is address(0)
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.migrator.selector), abi.encode(address(0)));

        address randomCaller = address(0x4444);
        MockERC20(asset).mint(randomCaller, 1_000 ether);
        vm.prank(randomCaller);
        IERC20(asset).approve(facet, type(uint256).max);

        uint256 victimBefore = _quota(victim);

        // randomCaller has no quota and migrator = address(0) gives no privilege → revert
        vm.prank(randomCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                randomCaller,  // msgSender_ = randomCaller, not remapped
                1_000 ether,
                0
            )
        );
        VaultFacet(facet).deposit(1_000 ether, victim);

        assertEq(_quota(victim), victimBefore, "victim quota must remain unchanged when migrator is address(0)");
    }
}

// =============================================================================
// Helper — simulates an unregistered contract attempting the attack
// =============================================================================

contract FakeMigratorContract {
    address public vault;
    address public token;

    constructor(address _vault, address _token) {
        vault = _vault;
        token = _token;
        IERC20(_token).approve(_vault, type(uint256).max);
    }

    function depositForVictim(uint256 amount, address victim_) external {
        VaultFacet(vault).deposit(amount, victim_);
    }
}
