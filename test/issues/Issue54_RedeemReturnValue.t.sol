// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";
import {MoreVaultMigrator} from "../../src/periphery/MoreVaultMigrator.sol";

// Issue #54: VaultFacet.redeem returns gross assets before withdrawal fee.
// MoreVaultMigrator.finalizeMigration previously trusted that return value for
// the deposit amount. When withdrawal fees are enabled the migrator receives less
// than what redeem returned, so the deposit would revert or consume a stale balance.
// Fix: use a balance diff around the redeem call instead of its return value.
contract Issue54_RedeemReturnValue is Test {
    address owner       = address(0xA11CE);
    address curator     = address(0xC0FFEE);
    address guardian    = address(0x600D);
    address feeRecip    = address(0xFEEF);
    address user        = address(0xB0B);
    address router      = address(0xBEEF01);
    address registry    = address(0x1000);
    address factory     = address(0x1001);
    address oReg        = address(0x1002);

    MockERC20            asset;
    MockMoreVaultsEscrow escrowOld;
    MockMoreVaultsEscrow escrowNew;
    address              oldVault;
    address              newVault;
    MoreVaultMigrator    migrator;

    uint256 constant DEPOSIT_AMOUNT = 10_000e18;
    uint96  constant FEE_10PCT      = 1000; // 10% of 10 000 basis points

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        asset     = new MockERC20("Token", "TK");
        escrowOld = new MockMoreVaultsEscrow();
        escrowNew = new MockMoreVaultsEscrow();

        oldVault = _deployVault(escrowOld, 0);
        newVault = _deployVault(escrowNew, 0);

        escrowOld.setUnderlyingToken(oldVault, address(asset));
        escrowNew.setUnderlyingToken(newVault, address(asset));

        migrator = new MoreVaultMigrator(oldVault, newVault, owner, curator);
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.migrator.selector), abi.encode(address(migrator)));

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        VaultFacet(oldVault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    function test_noFee_assetsReceivedMatchesRedeem() public {
        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        _requestAndApprove(userShares);

        vm.prank(curator);
        (, uint256 assetsReceived,) = migrator.finalizeMigration(user, userShares, 0);

        assertEq(assetsReceived, expectedAssets);
    }

    function test_withFee_assetsReceivedIsNetAfterFee() public {
        MoreVaultsStorageHelper.setWithdrawalFee(oldVault, FEE_10PCT);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        uint256 grossAssets = VaultFacet(oldVault).convertToAssets(userShares);
        uint256 expectedNet = grossAssets - (grossAssets * FEE_10PCT / 10_000);

        _requestAndApprove(userShares);

        vm.prank(curator);
        (, uint256 assetsReceived, uint256 newShares) = migrator.finalizeMigration(user, userShares, 0);

        assertEq(assetsReceived, expectedNet);
        assertGt(newShares, 0);
        assertEq(VaultFacet(newVault).balanceOf(user), newShares);
    }

    function test_withFee_staleBalanceNotConsumed() public {
        MoreVaultsStorageHelper.setWithdrawalFee(oldVault, FEE_10PCT);

        uint256 stale = 5_000e18;
        asset.mint(address(migrator), stale);

        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        uint256 grossAssets = VaultFacet(oldVault).convertToAssets(userShares);
        uint256 expectedNet = grossAssets - (grossAssets * FEE_10PCT / 10_000);

        _requestAndApprove(userShares);

        vm.prank(curator);
        (, uint256 assetsReceived,) = migrator.finalizeMigration(user, userShares, 0);

        assertEq(assetsReceived, expectedNet);
        assertEq(asset.balanceOf(address(migrator)), stale);
    }

    function test_donationCannotInflateAssetsReceived() public {
        uint256 userShares = VaultFacet(oldVault).balanceOf(user);
        uint256 expectedAssets = VaultFacet(oldVault).previewRedeem(userShares);

        _requestAndApprove(userShares);

        // Attacker donates tokens to migrator between balanceOf calls (simulated by minting before finalize)
        uint256 donation = 50_000e18;
        asset.mint(address(migrator), donation);

        vm.prank(curator);
        (, uint256 assetsReceived,) = migrator.finalizeMigration(user, userShares, 0);

        assertEq(assetsReceived, expectedAssets);
        assertGt(asset.balanceOf(address(migrator)), 0);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _requestAndApprove(uint256 shares) internal {
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(shares, user);
        IERC20(oldVault).approve(address(migrator), shares);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
    }

    function _deployVault(MockMoreVaultsEscrow escrow, uint96 fee) internal returns (address vault) {
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

        bytes memory initData = abi.encode("Test Vault", "TV", address(asset), feeRecip, fee, type(uint256).max);
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
