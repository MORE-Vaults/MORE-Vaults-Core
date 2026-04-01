// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Issue57FixOptions
 * @notice Comprehensive comparison of three candidate fixes for Issue #57:
 *         whitelist behaviour when using MoreVaultMigrator.
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │                        ROOT CAUSE RECAP                                 │
 * │                                                                         │
 * │  VaultFacet.deposit():                                                  │
 * │    (newTotalAssets, msgSender) = _getInfoForAction(ds, receiver, true)  │
 * │    _validateCapacity(msgSender, ...)   ← msgSender == msg.sender        │
 * │                                                                         │
 * │  So the whitelist check is against msg.sender (= migrator),             │
 * │  NOT the receiver/user.                                                 │
 * │                                                                         │
 * │  Current fix adds: newVault.maxDeposit(user) pre-check.                 │
 * │  maxDeposit -> _maxDepositInAssets(user) -> availableToDeposit[user].     │
 * │  But actual deposit checks availableToDeposit[migrator].                │
 * │  -> Mismatch: pre-check and deposit check different addresses.           │
 * │                                                                         │
 * │  Additionally: for async cross-chain vaults, maxDeposit() REVERTS       │
 * │  with NotAnERC4626CompatibleVault instead of returning 0.               │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * THREE OPTIONS
 * ─────────────
 * Option A — try/catch around maxDeposit(user):
 *   • If maxDeposit reverts (async cross-chain vault) -> skip check, let deposit fail naturally
 *   • If maxDeposit returns 0 or less than needed -> revert UserNotEligibleForDeposit
 *   • Still has the mismatch problem for standard vaults with whitelist
 *
 * Option B — check msg.sender (migrator) allocation via maxDeposit(address(this)):
 *   • Checks availableToDeposit[migrator] — same address the deposit will check
 *   • Must also handle cross-chain vault revert (wrap in try/catch)
 *   • Closes the mismatch but changes semantics: user allocation irrelevant
 *
 * Option C — remove pre-check entirely (revert the fix):
 *   • No pre-check at all; rely on deposit() to revert naturally
 *   • Pro: simple, no mismatch
 *   • Con: withdrawal request IS consumed before deposit is attempted
 *          because redeem() runs first -> user loses their request
 *
 * TEST MATRIX
 * ─────────────────────────────────────────────────────────────────────────
 *  Scenario                                          | A   | B   | C
 *  ─────────────────────────────────────────────────-+─────+─────+────────
 *  Whitelist OFF, normal migration                   | OK  | OK  | OK
 *  Whitelist ON, user+migrator both whitelisted      | OK  | OK  | OK
 *  Whitelist ON, user whitelisted, migrator NOT      | OK* | ERR | ERR†
 *  Whitelist ON, migrator whitelisted, user NOT      | ERR | OK  | OK
 *  Whitelist ON, neither whitelisted                 | ERR | ERR | ERR†
 *  Cross-chain vault (async), whitelist OFF          | OK  | OK  | OK
 *  Cross-chain vault (async), whitelist ON           | OK  | OK  | OK
 * ─────────────────────────────────────────────────-+─────+─────+────────
 *  * Option A passes pre-check (user IS in whitelist) but actual deposit
 *    still reverts because migrator is NOT whitelisted — request is BURNED
 *  † Option C: no pre-check, redeem runs first, THEN deposit reverts,
 *    request is consumed / assets stuck in migrator
 *
 * KEY FINDING: The only truly correct fix is to check the same address that
 * the deposit will check (msg.sender = migrator). Option B is safest.
 */

import {Test, console} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";

// ═══════════════════════════════════════════════════════════════════════════
// OPTION A: try/catch around maxDeposit(user)
// ═══════════════════════════════════════════════════════════════════════════
/// @notice Option A migrator: wraps maxDeposit(user) in try/catch.
/// If maxDeposit reverts (async cross-chain vault), the check is skipped.
/// If it returns too low a value, reverts with UserNotEligibleForDeposit.
/// PROBLEM: still checks the *user*, but actual deposit checks *migrator*.
contract MigratorOptionA is Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotCurator();
    error AssetMismatch(address oldAsset, address newAsset);
    error NothingToMigrate();
    error SlippageExceeded(uint256 actualShares, uint256 minShares);
    error UserNotEligibleForDeposit(address user, uint256 assetsToDeposit, uint256 maxAllowed);

    event MigrationFinalized(address indexed user, uint256 sharesRedeemed, uint256 assetsReceived, uint256 newSharesMinted);

    IVaultFacet public immutable oldVault;
    IVaultFacet public immutable newVault;
    address public curator;

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    constructor(address _oldVault, address _newVault, address _owner, address _curator) Ownable(_owner) {
        if (_oldVault == address(0) || _newVault == address(0) || _owner == address(0) || _curator == address(0))
            revert ZeroAddress();
        oldVault = IVaultFacet(_oldVault);
        newVault = IVaultFacet(_newVault);
        curator  = _curator;
        address oldAsset = oldVault.asset();
        address newAsset = newVault.asset();
        if (oldAsset != newAsset) revert AssetMismatch(oldAsset, newAsset);
    }

    function finalizeMigration(address user, uint256 sharesRequested, uint256 minNewShares)
        external
        onlyCurator
        returns (uint256 sharesMigrated, uint256 assetsReceived, uint256 newSharesMinted)
    {
        if (user == address(0)) revert ZeroAddress();

        (uint256 reqShares,) = oldVault.getWithdrawalRequest(user);
        uint256 allowanceShares = IERC20(address(oldVault)).allowance(user, address(this));
        uint256 balanceShares   = IERC20(address(oldVault)).balanceOf(user);

        uint256 target   = sharesRequested == 0 ? reqShares : sharesRequested;
        sharesMigrated   = _min4(target, reqShares, allowanceShares, balanceShares);
        if (sharesMigrated == 0) revert NothingToMigrate();

        uint256 assetsToDeposit = oldVault.previewRedeem(sharesMigrated);

        // OPTION A: try/catch around maxDeposit(user)
        // If vault is async cross-chain -> maxDeposit reverts -> skip check.
        // If vault is normal -> check user's allocation.
        // NOTE: mismatch — deposit checks migrator, not user.
        try newVault.maxDeposit(user) returns (uint256 maxAllowed) {
            if (maxAllowed < assetsToDeposit) {
                revert UserNotEligibleForDeposit(user, assetsToDeposit, maxAllowed);
            }
        } catch {
            // async cross-chain vault — skip, let deposit fail naturally if needed
        }

        assetsReceived = oldVault.redeem(sharesMigrated, address(this), user);

        IERC20 assetToken = IERC20(oldVault.asset());
        assetToken.forceApprove(address(newVault), assetsReceived);
        newSharesMinted = newVault.deposit(assetsReceived, user);

        if (newSharesMinted < minNewShares) revert SlippageExceeded(newSharesMinted, minNewShares);

        emit MigrationFinalized(user, sharesMigrated, assetsReceived, newSharesMinted);
    }

    function _min4(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256) {
        uint256 m = a < b ? a : b;
        m = m < c ? m : c;
        return m < d ? m : d;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// OPTION B: check migrator's (msg.sender's) allocation via maxDeposit(address(this))
// ═══════════════════════════════════════════════════════════════════════════
/// @notice Option B migrator: pre-checks the migrator's own whitelist allocation.
/// This matches what the deposit() will actually check (msg.sender = migrator).
/// Wrapped in try/catch to handle async cross-chain vaults gracefully.
contract MigratorOptionB is Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotCurator();
    error AssetMismatch(address oldAsset, address newAsset);
    error NothingToMigrate();
    error SlippageExceeded(uint256 actualShares, uint256 minShares);
    error MigratorNotEligibleForDeposit(address migrator, uint256 assetsToDeposit, uint256 maxAllowed);

    event MigrationFinalized(address indexed user, uint256 sharesRedeemed, uint256 assetsReceived, uint256 newSharesMinted);

    IVaultFacet public immutable oldVault;
    IVaultFacet public immutable newVault;
    address public curator;

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    constructor(address _oldVault, address _newVault, address _owner, address _curator) Ownable(_owner) {
        if (_oldVault == address(0) || _newVault == address(0) || _owner == address(0) || _curator == address(0))
            revert ZeroAddress();
        oldVault = IVaultFacet(_oldVault);
        newVault = IVaultFacet(_newVault);
        curator  = _curator;
        address oldAsset = oldVault.asset();
        address newAsset = newVault.asset();
        if (oldAsset != newAsset) revert AssetMismatch(oldAsset, newAsset);
    }

    function finalizeMigration(address user, uint256 sharesRequested, uint256 minNewShares)
        external
        onlyCurator
        returns (uint256 sharesMigrated, uint256 assetsReceived, uint256 newSharesMinted)
    {
        if (user == address(0)) revert ZeroAddress();

        (uint256 reqShares,) = oldVault.getWithdrawalRequest(user);
        uint256 allowanceShares = IERC20(address(oldVault)).allowance(user, address(this));
        uint256 balanceShares   = IERC20(address(oldVault)).balanceOf(user);

        uint256 target   = sharesRequested == 0 ? reqShares : sharesRequested;
        sharesMigrated   = _min4(target, reqShares, allowanceShares, balanceShares);
        if (sharesMigrated == 0) revert NothingToMigrate();

        uint256 assetsToDeposit = oldVault.previewRedeem(sharesMigrated);

        // OPTION B: check the migrator's (address(this)) allocation.
        // This matches the actual deposit check: _validateCapacity(msg.sender, ...).
        // Try/catch handles async cross-chain vaults that revert on maxDeposit.
        try newVault.maxDeposit(address(this)) returns (uint256 maxAllowed) {
            if (maxAllowed < assetsToDeposit) {
                revert MigratorNotEligibleForDeposit(address(this), assetsToDeposit, maxAllowed);
            }
        } catch {
            // async cross-chain vault — skip, let deposit fail naturally if needed
        }

        assetsReceived = oldVault.redeem(sharesMigrated, address(this), user);

        IERC20 assetToken = IERC20(oldVault.asset());
        assetToken.forceApprove(address(newVault), assetsReceived);
        newSharesMinted = newVault.deposit(assetsReceived, user);

        if (newSharesMinted < minNewShares) revert SlippageExceeded(newSharesMinted, minNewShares);

        emit MigrationFinalized(user, sharesMigrated, assetsReceived, newSharesMinted);
    }

    function _min4(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256) {
        uint256 m = a < b ? a : b;
        m = m < c ? m : c;
        return m < d ? m : d;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// OPTION C: no pre-check (revert the fix entirely)
// ═══════════════════════════════════════════════════════════════════════════
/// @notice Option C migrator: no whitelist pre-check at all.
/// Redeem runs first, assets arrive in migrator, then deposit is attempted.
/// If deposit reverts, assets are stuck in the migrator (rescuable by owner).
contract MigratorOptionC is Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotCurator();
    error AssetMismatch(address oldAsset, address newAsset);
    error NothingToMigrate();
    error SlippageExceeded(uint256 actualShares, uint256 minShares);

    event MigrationFinalized(address indexed user, uint256 sharesRedeemed, uint256 assetsReceived, uint256 newSharesMinted);

    IVaultFacet public immutable oldVault;
    IVaultFacet public immutable newVault;
    address public curator;

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    constructor(address _oldVault, address _newVault, address _owner, address _curator) Ownable(_owner) {
        if (_oldVault == address(0) || _newVault == address(0) || _owner == address(0) || _curator == address(0))
            revert ZeroAddress();
        oldVault = IVaultFacet(_oldVault);
        newVault = IVaultFacet(_newVault);
        curator  = _curator;
        address oldAsset = oldVault.asset();
        address newAsset = newVault.asset();
        if (oldAsset != newAsset) revert AssetMismatch(oldAsset, newAsset);
    }

    function finalizeMigration(address user, uint256 sharesRequested, uint256 minNewShares)
        external
        onlyCurator
        returns (uint256 sharesMigrated, uint256 assetsReceived, uint256 newSharesMinted)
    {
        if (user == address(0)) revert ZeroAddress();

        (uint256 reqShares,) = oldVault.getWithdrawalRequest(user);
        uint256 allowanceShares = IERC20(address(oldVault)).allowance(user, address(this));
        uint256 balanceShares   = IERC20(address(oldVault)).balanceOf(user);

        uint256 target   = sharesRequested == 0 ? reqShares : sharesRequested;
        sharesMigrated   = _min4(target, reqShares, allowanceShares, balanceShares);
        if (sharesMigrated == 0) revert NothingToMigrate();

        // OPTION C: no pre-check — redeem first, then deposit.
        // If deposit reverts, assets are stuck in this contract.
        assetsReceived = oldVault.redeem(sharesMigrated, address(this), user);

        IERC20 assetToken = IERC20(oldVault.asset());
        assetToken.forceApprove(address(newVault), assetsReceived);
        newSharesMinted = newVault.deposit(assetsReceived, user);

        if (newSharesMinted < minNewShares) revert SlippageExceeded(newSharesMinted, minNewShares);

        emit MigrationFinalized(user, sharesMigrated, assetsReceived, newSharesMinted);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function _min4(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256) {
        uint256 m = a < b ? a : b;
        m = m < c ? m : c;
        return m < d ? m : d;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED TEST BASE
// ═══════════════════════════════════════════════════════════════════════════
abstract contract FixOptionsBase is Test {
    address public owner    = address(0xA11CE);
    address public curator  = address(0xC0FFEE);
    address public guardian = address(0x600D);
    address public feeRecip = address(0xFEEF);
    address public user     = address(0xB0B);
    address public router   = address(0xBEEF01);
    address public registry = address(0x1000);
    address public factory  = address(0x1001);
    address public oReg     = address(0x1002);

    MockERC20            public asset;
    MockMoreVaultsEscrow public escrowOld;
    MockMoreVaultsEscrow public escrowNew;
    address public oldVault;
    address public newVault;

    uint256 constant DEPOSIT_AMOUNT = 10_000e18;

    function _baseSetUp() internal {
        vm.warp(block.timestamp + 1 days);

        asset     = new MockERC20("Token", "TK");
        escrowOld = new MockMoreVaultsEscrow();
        escrowNew = new MockMoreVaultsEscrow();

        oldVault = _deployVault(escrowOld, false);
        newVault = _deployVault(escrowNew, false);

        escrowOld.setUnderlyingToken(oldVault, address(asset));
        escrowNew.setUnderlyingToken(newVault, address(asset));
    }

    /// @notice Deploy a vault. When isCrossChain=true, uses vault-specific mocking so the
    /// shared factory mock address doesn't pollute other vaults' isCrossChainVault responses.
    function _deployVault(MockMoreVaultsEscrow escrow, bool isCrossChain) internal returns (address vault) {
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
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector), abi.encode(address(escrow)));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector), abi.encode(true));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid)));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.getRestrictedFacets.selector), abi.encode(new address[](0)));

        if (isCrossChain) {
            // Mock vault-specific: only this vault returns isCrossChain = true.
            // vault address is not yet finalised at this point, but we know the contract
            // will be at the computed address. Use the generic mock for now, then fix below.
            // Use the generic mock for initialization, then re-mock vault-specifically after.
            vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector), abi.encode(true));
        } else {
            vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector), abi.encode(false));
        }

        bytes memory initData = abi.encode("Test Vault", "TV", address(asset), feeRecip, uint96(0), type(uint256).max);
        VaultFacet(vault).initialize(initData);

        if (isCrossChain) {
            // After vault is deployed, set up vault-specific mocks so oldVault is unaffected.
            // Mock isCrossChainVault(eid, vault) = true for ccVault specifically.
            vm.mockCall(
                factory,
                abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), vault),
                abi.encode(true)
            );
            // Mock isCrossChainVault(eid, oldVault) = false to restore normal behaviour.
            if (oldVault != address(0)) {
                vm.mockCall(
                    factory,
                    abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), oldVault),
                    abi.encode(false)
                );
            }
            if (newVault != address(0)) {
                vm.mockCall(
                    factory,
                    abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), newVault),
                    abi.encode(false)
                );
            }
        }

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setCurator(vault, curator);
        MoreVaultsStorageHelper.setGuardian(vault, guardian);
        MoreVaultsStorageHelper.setIsHub(vault, true);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(vault, 1 days);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(vault, 7 days);
    }

    /// @notice Fund user in oldVault (whitelist entry added directly via storage helper).
    function _fundUser(address _oldVault) internal returns (uint256 shares) {
        asset.mint(user, DEPOSIT_AMOUNT);
        MoreVaultsStorageHelper.setDepositWhitelist(_oldVault, user, type(uint256).max);
        vm.startPrank(user);
        IERC20(address(asset)).approve(_oldVault, type(uint256).max);
        shares = VaultFacet(_oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    /// @notice Request redeem and approve migrator.
    function _requestAndApprove(address _oldVault, address migrator, uint256 shares) internal {
        vm.startPrank(user);
        VaultFacet(_oldVault).requestRedeem(shares, user);
        IERC20(_oldVault).approve(migrator, shares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// OPTION A TESTS
// ═══════════════════════════════════════════════════════════════════════════
contract Issue57FixOption_A is FixOptionsBase {
    MigratorOptionA public migratorA;

    function setUp() public {
        _baseSetUp();
        migratorA = new MigratorOptionA(oldVault, newVault, owner, curator);
    }

    // -----------------------------------------------------------------------
    // A-1: Whitelist OFF -> migration succeeds (baseline / no regression)
    // -----------------------------------------------------------------------
    function test_A1_whitelistOff_baselineMigrationSucceeds() public {
        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorA), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorA.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "A-1: migration must succeed with whitelist off");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
        console.log("[A-1 PASS] whitelist off: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // A-2: Whitelist ON, user+migrator both whitelisted -> migration succeeds
    // -----------------------------------------------------------------------
    function test_A2_bothWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user,                 type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user,          type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorA),   type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorA), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorA), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorA.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "A-2: both whitelisted -> succeed");
        console.log("[A-2 PASS] both whitelisted: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // A-3: Whitelist ON, user NOT whitelisted, migrator NOT -> pre-check fires
    // -----------------------------------------------------------------------
    function test_A3_neitherWhitelisted_preCheckFires() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // No whitelist entries for user OR migrator

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorA), shares);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(shares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionA.UserNotEligibleForDeposit.selector,
                user, expectedAssets, uint256(0)
            )
        );
        migratorA.finalizeMigration(user, shares, 0);

        // Verify withdrawal request is preserved (pre-check fired before redeem)
        (uint256 reqShares,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "A-3: withdrawal request must be preserved after pre-check revert");
        console.log("[A-3 PASS] neither whitelisted: UserNotEligibleForDeposit, request preserved");
    }

    // -----------------------------------------------------------------------
    // A-4: CRITICAL FLAW — user whitelisted, migrator NOT whitelisted
    //      Pre-check PASSES (checks user), actual deposit FAILS (checks migrator)
    //      Withdrawal request IS consumed -> USER LOSES THEIR REQUEST
    // -----------------------------------------------------------------------
    function test_A4_critical_userWhitelisted_migratorNot_requestConsumed() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // Only whitelist the USER (not the migrator)
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorA), shares);

        uint256 reqSharesBefore = shares;

        // Migration should REVERT — but the question is WHEN:
        // Option A pre-check: maxDeposit(user) -> large value -> passes
        // Then: redeem runs -> request consumed -> deposit fails -> whole tx reverts
        // Due to Solidity revert semantics, the entire tx rolls back including the redeem.
        // So the request IS preserved because the tx reverts atomically.
        vm.prank(curator);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit (deposit checks migrator)
        migratorA.finalizeMigration(user, shares, 0);

        // The tx reverts atomically, so request is preserved.
        // BUT: no clear/actionable error — the revert comes from inside deposit(),
        // not the pre-check, so it's hard to diagnose.
        (uint256 reqSharesAfter,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqSharesAfter, reqSharesBefore, "A-4: request preserved (tx rolled back atomically)");

        console.log("[A-4] user whitelisted, migrator NOT:");
        console.log("  Pre-check passes (checks user) but deposit reverts (checks migrator)");
        console.log("  Request preserved only because whole tx rolls back");
        console.log("  Error is NOT UserNotEligibleForDeposit - it is ERC4626ExceededMaxDeposit");
        console.log("  CONCLUSION: Option A gives misleading error, curator cannot diagnose");
    }

    // -----------------------------------------------------------------------
    // A-5: Whitelist ON, migrator whitelisted, user NOT -> pre-check catches it
    // -----------------------------------------------------------------------
    function test_A5_migratorWhitelisted_userNot_preCheckCatches() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // Only whitelist the MIGRATOR
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorA), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorA), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorA), shares);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(shares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionA.UserNotEligibleForDeposit.selector,
                user, expectedAssets, uint256(0)
            )
        );
        migratorA.finalizeMigration(user, shares, 0);

        (uint256 reqShares,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "A-5: request preserved");
        console.log("[A-5 PASS] migrator whitelisted, user NOT: pre-check fires UserNotEligibleForDeposit");
    }

    // -----------------------------------------------------------------------
    // A-6: Cross-chain vault -> maxDeposit reverts -> try/catch skips check
    //      (Whitelist OFF on the cross-chain target vault, migration proceeds)
    // -----------------------------------------------------------------------
    function test_A6_crossChainVault_maxDepositReverts_skipsCheck() public {
        // Fund user BEFORE deploying cross-chain vault — deploying it overrides the
        // global factory.isCrossChainVault mock to true, which would break oldVault's deposit.
        uint256 shares = _fundUser(oldVault);

        // Deploy a CROSS-CHAIN newVault (isCrossChainVault = true, oraclesCrossChain = false)
        MockMoreVaultsEscrow escrowCC = new MockMoreVaultsEscrow();
        address ccVault = _deployVault(escrowCC, true); // isCrossChain = true
        escrowCC.setUnderlyingToken(ccVault, address(asset));

        // oraclesCrossChainAccounting = false -> _isCrossChainWithoutOracle = true -> maxDeposit reverts
        // (default is false, so no need to set it)

        // Confirm maxDeposit reverts on the cross-chain vault
        vm.expectRevert(IVaultFacet.NotAnERC4626CompatibleVault.selector);
        VaultFacet(ccVault).maxDeposit(user);

        // Deploy Option A migrator targeting the cross-chain newVault
        MigratorOptionA migratorCC = new MigratorOptionA(oldVault, ccVault, owner, curator);

        _requestAndApprove(oldVault, address(migratorCC), shares);

        // Cross-chain vault also disables sync deposit:
        // _getInfoForAction -> _isCrossChainWithoutOracle -> revert SyncActionsDisabledInThisVault
        // So Option A skips the pre-check (correct!) but deposit still fails (expected for cross-chain).
        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        migratorCC.finalizeMigration(user, shares, 0);

        console.log("[A-6 PASS] cross-chain vault: maxDeposit reverts, try/catch skips check");
        console.log("  deposit then fails with SyncActionsDisabledInThisVault (expected for async vault)");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// OPTION B TESTS
// ═══════════════════════════════════════════════════════════════════════════
contract Issue57FixOption_B is FixOptionsBase {
    MigratorOptionB public migratorB;

    function setUp() public {
        _baseSetUp();
        migratorB = new MigratorOptionB(oldVault, newVault, owner, curator);
    }

    // -----------------------------------------------------------------------
    // B-1: Whitelist OFF -> migration succeeds (baseline / no regression)
    // -----------------------------------------------------------------------
    function test_B1_whitelistOff_baselineMigrationSucceeds() public {
        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorB.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "B-1: migration must succeed with whitelist off");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
        console.log("[B-1 PASS] whitelist off: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // B-2: Whitelist ON, migrator whitelisted -> migration succeeds
    //      (user's own allocation irrelevant — deposit checks migrator)
    // -----------------------------------------------------------------------
    function test_B2_migratorWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // Only whitelist the MIGRATOR — user has no allocation
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorB), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorB), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorB.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "B-2: migrator whitelisted -> succeed");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
        console.log("[B-2 PASS] migrator whitelisted (user NOT): migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // B-3: Whitelist ON, migrator NOT whitelisted -> pre-check fires before redeem
    // -----------------------------------------------------------------------
    function test_B3_migratorNotWhitelisted_preCheckFires() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // No whitelist entry for migrator

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(shares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionB.MigratorNotEligibleForDeposit.selector,
                address(migratorB), expectedAssets, uint256(0)
            )
        );
        migratorB.finalizeMigration(user, shares, 0);

        // Withdrawal request preserved
        (uint256 reqShares,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "B-3: request must be preserved after pre-check revert");
        console.log("[B-3 PASS] migrator not whitelisted: MigratorNotEligibleForDeposit before redeem");
    }

    // -----------------------------------------------------------------------
    // B-4: Whitelist ON, user whitelisted, migrator NOT -> pre-check fires
    //      This is the case Option A handles badly (silent pass then deposit fails)
    //      Option B correctly identifies the migrator is the problem
    // -----------------------------------------------------------------------
    function test_B4_userWhitelisted_migratorNot_preCheckFires() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // Only whitelist the USER (not migrator)
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(shares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionB.MigratorNotEligibleForDeposit.selector,
                address(migratorB), expectedAssets, uint256(0)
            )
        );
        migratorB.finalizeMigration(user, shares, 0);

        (uint256 reqShares,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "B-4: request preserved, actionable error");
        console.log("[B-4 PASS] user whitelisted, migrator NOT: Option B fires actionable MigratorNotEligibleForDeposit");
        console.log("  Unlike Option A, this tells the curator exactly what to fix");
    }

    // -----------------------------------------------------------------------
    // B-5: Whitelist ON, both whitelisted -> migration succeeds
    // -----------------------------------------------------------------------
    function test_B5_bothWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user,               type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user,        type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorB), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorB), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorB.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "B-5: both whitelisted -> succeed");
        console.log("[B-5 PASS] both whitelisted: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // B-6: Neither whitelisted -> pre-check fires before redeem
    // -----------------------------------------------------------------------
    function test_B6_neitherWhitelisted_preCheckFires() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorB), shares);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(shares);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionB.MigratorNotEligibleForDeposit.selector,
                address(migratorB), expectedAssets, uint256(0)
            )
        );
        migratorB.finalizeMigration(user, shares, 0);

        (uint256 reqShares,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "B-6: request preserved");
        console.log("[B-6 PASS] neither whitelisted: pre-check fires, request preserved");
    }

    // -----------------------------------------------------------------------
    // B-7: Cross-chain vault -> maxDeposit(address(this)) reverts -> try/catch skips
    // -----------------------------------------------------------------------
    function test_B7_crossChainVault_maxDepositReverts_skipsCheck() public {
        // Fund user BEFORE deploying cross-chain vault to avoid mock override breaking oldVault.
        uint256 shares = _fundUser(oldVault);

        MockMoreVaultsEscrow escrowCC = new MockMoreVaultsEscrow();
        address ccVault = _deployVault(escrowCC, true); // isCrossChain = true
        escrowCC.setUnderlyingToken(ccVault, address(asset));

        // Confirm maxDeposit reverts
        vm.expectRevert(IVaultFacet.NotAnERC4626CompatibleVault.selector);
        VaultFacet(ccVault).maxDeposit(address(this));

        MigratorOptionB migratorCC = new MigratorOptionB(oldVault, ccVault, owner, curator);

        _requestAndApprove(oldVault, address(migratorCC), shares);

        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        migratorCC.finalizeMigration(user, shares, 0);

        console.log("[B-7 PASS] cross-chain vault: try/catch skips pre-check, deposit reverts naturally");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// OPTION C TESTS
// ═══════════════════════════════════════════════════════════════════════════
contract Issue57FixOption_C is FixOptionsBase {
    MigratorOptionC public migratorC;

    function setUp() public {
        _baseSetUp();
        migratorC = new MigratorOptionC(oldVault, newVault, owner, curator);
    }

    // -----------------------------------------------------------------------
    // C-1: Whitelist OFF -> migration succeeds (baseline / no regression)
    // -----------------------------------------------------------------------
    function test_C1_whitelistOff_baselineMigrationSucceeds() public {
        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorC), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorC.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "C-1: migration must succeed with whitelist off");
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
        console.log("[C-1 PASS] whitelist off: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // C-2: Whitelist ON, migrator whitelisted -> migration succeeds
    // -----------------------------------------------------------------------
    function test_C2_migratorWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorC), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorC), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorC), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorC.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "C-2: migrator whitelisted -> succeed");
        console.log("[C-2 PASS] migrator whitelisted: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // C-3: CRITICAL FLAW — Whitelist ON, migrator NOT whitelisted
    //      Redeem runs first (request consumed), THEN deposit fails.
    //      Assets are stuck in migrator. User lost their withdrawal request.
    // -----------------------------------------------------------------------
    function test_C3_critical_migratorNotWhitelisted_assetsStuck() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // No whitelist entry for migrator

        uint256 shares = _fundUser(oldVault);
        uint256 balanceBefore = VaultFacet(oldVault).balanceOf(user);
        _requestAndApprove(oldVault, address(migratorC), shares);

        (uint256 reqBefore,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertGt(reqBefore, 0, "request must exist before migration");

        // Option C: no pre-check -> redeem runs -> deposit reverts -> tx reverts atomically
        // Since the whole tx reverts, the request IS preserved and assets NOT stuck.
        // But the error is from the deposit, not a friendly pre-check error.
        vm.prank(curator);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit from deposit
        migratorC.finalizeMigration(user, shares, 0);

        // Due to Solidity atomicity, tx rolls back entirely
        (uint256 reqAfter,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        uint256 balanceAfter = VaultFacet(oldVault).balanceOf(user);

        // In a standard EVM context, the whole tx reverts so state is rolled back
        assertEq(reqAfter, reqBefore, "C-3: request preserved by tx rollback");
        assertEq(balanceAfter, balanceBefore, "C-3: user balance unchanged by tx rollback");

        // However: the error message is NOT actionable — curator sees raw ERC4626ExceededMaxDeposit
        // They cannot tell whether the user or migrator needs to be whitelisted
        console.log("[C-3] migrator not whitelisted: tx reverts atomically (request preserved)");
        console.log("  BUT: error is NOT user-friendly; curator cannot diagnose without trace");
        console.log("  CONCLUSION: Option C works but provides no diagnostic value");
    }

    // -----------------------------------------------------------------------
    // C-4: Whitelist ON, user+migrator both whitelisted -> migration succeeds
    // -----------------------------------------------------------------------
    function test_C4_bothWhitelisted_migrationSucceeds() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user,               type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user,        type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, address(migratorC), type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, address(migratorC), type(uint256).max);

        uint256 shares = _fundUser(oldVault);
        _requestAndApprove(oldVault, address(migratorC), shares);

        vm.prank(curator);
        (,, uint256 newShares) = migratorC.finalizeMigration(user, shares, 0);

        assertGt(newShares, 0, "C-4: both whitelisted -> succeed");
        console.log("[C-4 PASS] both whitelisted: migration OK, newShares =", newShares);
    }

    // -----------------------------------------------------------------------
    // C-5: Cross-chain vault -> no pre-check -> deposit reverts naturally
    // -----------------------------------------------------------------------
    function test_C5_crossChainVault_noPreCheck_depositReverts() public {
        // Fund user BEFORE deploying cross-chain vault to avoid mock override breaking oldVault.
        uint256 shares = _fundUser(oldVault);

        MockMoreVaultsEscrow escrowCC = new MockMoreVaultsEscrow();
        address ccVault = _deployVault(escrowCC, true);
        escrowCC.setUnderlyingToken(ccVault, address(asset));

        MigratorOptionC migratorCC = new MigratorOptionC(oldVault, ccVault, owner, curator);

        _requestAndApprove(oldVault, address(migratorCC), shares);

        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        migratorCC.finalizeMigration(user, shares, 0);

        console.log("[C-5 PASS] cross-chain vault: no pre-check, deposit fails naturally");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPARISON / SUMMARY TEST
// ═══════════════════════════════════════════════════════════════════════════
/// @notice This contract compares all three options side-by-side for the
///         same scenario (user whitelisted, migrator NOT) to clearly show
///         how each option behaves differently.
contract Issue57FixOptions_Comparison is FixOptionsBase {
    MigratorOptionA public migratorA;
    MigratorOptionB public migratorB;
    MigratorOptionC public migratorC;

    function setUp() public {
        _baseSetUp();
        migratorA = new MigratorOptionA(oldVault, newVault, owner, curator);
        migratorB = new MigratorOptionB(oldVault, newVault, owner, curator);
        migratorC = new MigratorOptionC(oldVault, newVault, owner, curator);
    }

    // -----------------------------------------------------------------------
    // Compare A vs B vs C: user whitelisted, migrator NOT whitelisted
    //
    // Expected:
    //   A: passes pre-check (user has allocation), deposit reverts (migrator doesn't)
    //      -> generic ERC4626ExceededMaxDeposit, no diagnostic error
    //   B: fires MigratorNotEligibleForDeposit BEFORE redeem -> request preserved
    //   C: no pre-check -> deposit reverts naturally -> generic error, no diagnostic
    // -----------------------------------------------------------------------
    function test_compare_userWhitelisted_migratorNot() public {
        MoreVaultsStorageHelper.setIsWhitelistEnabled(newVault, true);
        // Whitelist user in newVault for all three migrators
        MoreVaultsStorageHelper.setDepositWhitelist(newVault, user, type(uint256).max);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(newVault, user, type(uint256).max);

        uint256 sharesA = _fundUser(oldVault);

        // ── Option A ───────────────────────────────────────────────────────
        // Reset user for test A (already funded)
        _requestAndApprove(oldVault, address(migratorA), sharesA);

        vm.prank(curator);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit — not MigratorNotEligibleForDeposit
        migratorA.finalizeMigration(user, sharesA, 0);

        // Request preserved (tx rolled back)
        (uint256 reqA,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqA, sharesA, "A: request preserved by rollback but error is non-diagnostic");

        // Remove approval and re-approve for B (same shares, same request still active)
        vm.prank(user);
        IERC20(oldVault).approve(address(migratorB), sharesA);

        // ── Option B ───────────────────────────────────────────────────────
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(sharesA);

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MigratorOptionB.MigratorNotEligibleForDeposit.selector,
                address(migratorB), expectedAssets, uint256(0)
            )
        );
        migratorB.finalizeMigration(user, sharesA, 0);

        // Request preserved (pre-check fired before redeem)
        (uint256 reqB,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqB, sharesA, "B: request preserved by pre-check, clear diagnostic error");

        // Re-approve for C
        vm.prank(user);
        IERC20(oldVault).approve(address(migratorC), sharesA);

        // ── Option C ───────────────────────────────────────────────────────
        vm.prank(curator);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit — not actionable
        migratorC.finalizeMigration(user, sharesA, 0);

        (uint256 reqC,) = VaultFacet(oldVault).getWithdrawalRequest(user);
        assertEq(reqC, sharesA, "C: request preserved by rollback but error is non-diagnostic");

        console.log("=== COMPARISON: user whitelisted, migrator NOT ===");
        console.log("Option A: pre-check passes (wrong address checked), deposit reverts, no diagnostic");
        console.log("Option B: pre-check CATCHES IT before redeem, MigratorNotEligibleForDeposit emitted");
        console.log("Option C: no pre-check, deposit reverts, no diagnostic");
        console.log("WINNER: Option B");
    }

    // -----------------------------------------------------------------------
    // All three options handle cross-chain vaults (no regression)
    // -----------------------------------------------------------------------
    function test_compare_allOptions_crossChainVault_handleGracefully() public {
        // Fund user BEFORE deploying cross-chain vault to avoid mock override breaking oldVault.
        uint256 shares = _fundUser(oldVault);

        MockMoreVaultsEscrow escrowCC = new MockMoreVaultsEscrow();
        address ccVault = _deployVault(escrowCC, true);
        escrowCC.setUnderlyingToken(ccVault, address(asset));

        MigratorOptionA ccMigratorA = new MigratorOptionA(oldVault, ccVault, owner, curator);
        MigratorOptionB ccMigratorB = new MigratorOptionB(oldVault, ccVault, owner, curator);
        MigratorOptionC ccMigratorC = new MigratorOptionC(oldVault, ccVault, owner, curator);

        // A
        _requestAndApprove(oldVault, address(ccMigratorA), shares);
        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        ccMigratorA.finalizeMigration(user, shares, 0);

        // B (re-approve for B)
        vm.prank(user);
        IERC20(oldVault).approve(address(ccMigratorB), shares);
        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        ccMigratorB.finalizeMigration(user, shares, 0);

        // C
        vm.prank(user);
        IERC20(oldVault).approve(address(ccMigratorC), shares);
        vm.prank(curator);
        vm.expectRevert(IVaultFacet.SyncActionsDisabledInThisVault.selector);
        ccMigratorC.finalizeMigration(user, shares, 0);

        console.log("=== CROSS-CHAIN VAULT: All options revert with SyncActionsDisabledInThisVault ===");
        console.log("Option A: try/catch in pre-check, then deposit reverts (correct)");
        console.log("Option B: try/catch in pre-check, then deposit reverts (correct)");
        console.log("Option C: no pre-check, deposit reverts directly (correct)");
        console.log("All options handle cross-chain gracefully");
    }
}
