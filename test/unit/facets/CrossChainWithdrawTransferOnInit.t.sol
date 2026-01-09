// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MockVaultsFactory} from "../../mocks/MockVaultsFactory.sol";
import {MockMoreVaultsRegistry} from "../../mocks/MockMoreVaultsRegistry.sol";
import {MockBridgeAdapter} from "../../mocks/MockBridgeAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";

/**
 * @title CrossChainWithdrawTransferOnInitTest
 * @notice Tests for cross-chain withdraw/redeem with transfer on init.
 *
 * These tests verify the EXPECTED CORRECT behavior:
 * - FAIL if bugs exist (double spendAllowance, burn from wrong address)
 * - PASS when the fix is correct
 *
 * BUG 1: Double/Wrong spendAllowance
 * - transferSharesFromOwner consumes allowance (owner -> initiator)
 * - _withdraw tries to consume different allowance (owner -> vault) which doesn't exist
 *
 * BUG 2: _burn from wrong address
 * - After transferSharesFromOwner, shares are in vault
 * - _withdraw tries to _burn(owner, shares) but owner has no shares
 */
contract CrossChainWithdrawTransferOnInitTest is Test {
    VaultFacet public vault;
    address public factory;
    address public registry;
    address public oracleRegistry;
    address public adapter;
    MockERC20 public underlying;

    address public vaultOwner = address(1);
    address public curator = address(2);
    address public guardian = address(3);
    address public feeRecipient = address(4);
    address public router = address(5);

    // Users for testing
    address public shareOwner = address(0x1111);
    address public initiator = address(0x2222);

    uint256 constant INITIAL_DEPOSIT = 1000 ether;

    function setUp() public {
        // Deploy contracts
        factory = address(new MockVaultsFactory());
        registry = address(new MockMoreVaultsRegistry());
        oracleRegistry = address(100);
        adapter = address(new MockBridgeAdapter());
        underlying = new MockERC20("Underlying", "UND");

        // Deploy vault
        vault = new VaultFacet();

        // Setup mocks before initialization
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleRegistry)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(underlying)),
            abi.encode(address(2000), uint96(1000))
        );

        // Initialize vault
        bytes memory initData = abi.encode(
            "Test Vault",
            "TV",
            address(underlying),
            feeRecipient,
            uint96(0),
            uint256(0)
        );

        // Set storage before initialize
        MoreVaultsStorageHelper.setOwner(address(vault), vaultOwner);
        MoreVaultsStorageHelper.setFactory(address(vault), factory);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(vault), registry);
        MoreVaultsStorageHelper.setFeeRecipient(address(vault), feeRecipient);

        vault.initialize(initData);

        // Setup additional storage after initialize
        MoreVaultsStorageHelper.setCurator(address(vault), curator);
        MoreVaultsStorageHelper.setGuardian(address(vault), guardian);
        MoreVaultsStorageHelper.setIsHub(address(vault), true);
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(vault), adapter);

        // Setup factory mocks
        vm.mockCall(
            factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), address(vault)),
            abi.encode(false)
        );
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector),
            abi.encode(eids, vaults)
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector), abi.encode(address(0), 0));

        // Mint underlying to shareOwner and deposit to get shares
        underlying.mint(shareOwner, 10000 ether);
        vm.startPrank(shareOwner);
        IERC20(address(underlying)).approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_DEPOSIT, shareOwner);
        vm.stopPrank();

        // Verify deposit was successful
        assertGt(vault.balanceOf(shareOwner), 0, "shareOwner should have shares after deposit");
    }

    /**
     * @notice Test: Cross-chain withdraw flow should work with exact allowance
     *
     * EXPECTED BEHAVIOR:
     * 1. User approves initiator for exact shares needed
     * 2. initVaultActionRequest calls transferSharesFromOwner (uses allowance, moves shares to vault)
     * 3. executeRequest processes the withdraw successfully
     * 4. User receives their assets
     */
    function test_crossChainWithdraw_shouldSucceedWithExactAllowance() public {
        uint256 ownerShares = vault.balanceOf(shareOwner);
        uint256 sharesToWithdraw = ownerShares / 2;
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToWithdraw);

        // Step 1: Owner approves initiator for exact shares
        vm.prank(shareOwner);
        IERC20(address(vault)).approve(initiator, sharesToWithdraw);

        // Step 2: Simulate transferSharesFromOwner (called via address(this).call in BridgeFacet)
        vm.prank(address(vault));
        vault.transferSharesFromOwner(shareOwner, sharesToWithdraw, initiator);

        // Verify shares moved to vault
        assertEq(vault.balanceOf(address(vault)), sharesToWithdraw, "Vault should hold the shares");

        // Step 3: Simulate executeRequest calling withdraw
        // Set finalizationGuid to simulate cross-chain execution context
        MoreVaultsStorageHelper.setFinalizationGuid(address(vault), bytes32(uint256(1)));

        uint256 receiverBalanceBefore = underlying.balanceOf(shareOwner);

        // This should succeed - vault burns its own locked shares
        vm.prank(address(vault));
        uint256 sharesReturned = vault.withdraw(assetsToWithdraw, shareOwner, shareOwner);

        // Verify the withdrawal succeeded
        uint256 receiverBalanceAfter = underlying.balanceOf(shareOwner);
        assertGt(receiverBalanceAfter, receiverBalanceBefore, "Receiver should have received assets");
        assertEq(sharesReturned, sharesToWithdraw, "Correct shares should be burned");
    }

    /**
     * @notice Test: Cross-chain redeem flow should work with exact allowance
     */
    function test_crossChainRedeem_shouldSucceedWithExactAllowance() public {
        uint256 ownerShares = vault.balanceOf(shareOwner);
        uint256 sharesToRedeem = ownerShares / 2;

        vm.prank(shareOwner);
        IERC20(address(vault)).approve(initiator, sharesToRedeem);

        vm.prank(address(vault));
        vault.transferSharesFromOwner(shareOwner, sharesToRedeem, initiator);

        assertEq(vault.balanceOf(address(vault)), sharesToRedeem);

        // Set finalizationGuid to simulate cross-chain execution context
        MoreVaultsStorageHelper.setFinalizationGuid(address(vault), bytes32(uint256(1)));

        uint256 receiverBalanceBefore = underlying.balanceOf(shareOwner);

        vm.prank(address(vault));
        uint256 assetsReturned = vault.redeem(sharesToRedeem, shareOwner, shareOwner);

        uint256 receiverBalanceAfter = underlying.balanceOf(shareOwner);
        assertGt(receiverBalanceAfter, receiverBalanceBefore, "Receiver should have received assets");
        assertGt(assetsReturned, 0, "Should return assets");
    }

    /**
     * @notice Test: Shares should be burned from vault, not from original owner
     */
    function test_withdrawShouldBurnSharesFromVault_notFromOwner() public {
        uint256 ownerShares = vault.balanceOf(shareOwner);
        uint256 sharesToWithdraw = ownerShares; // ALL shares
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToWithdraw);

        vm.prank(shareOwner);
        IERC20(address(vault)).approve(initiator, sharesToWithdraw);

        vm.prank(address(vault));
        vault.transferSharesFromOwner(shareOwner, sharesToWithdraw, initiator);

        // Owner now has 0 shares, vault has all of them
        assertEq(vault.balanceOf(shareOwner), 0, "Owner should have 0 shares");
        assertEq(vault.balanceOf(address(vault)), sharesToWithdraw, "Vault should have all shares");

        // Set finalizationGuid to simulate cross-chain execution context
        MoreVaultsStorageHelper.setFinalizationGuid(address(vault), bytes32(uint256(1)));

        // Should succeed by burning vault's shares
        vm.prank(address(vault));
        vault.withdraw(assetsToWithdraw, shareOwner, shareOwner);

        assertEq(vault.balanceOf(address(vault)), 0, "Vault shares should be burned");
    }

    /**
     * @notice Test: No second allowance should be needed for cross-chain withdraw
     */
    function test_crossChainWithdraw_shouldNotRequireVaultAllowance() public {
        uint256 sharesToWithdraw = vault.balanceOf(shareOwner) / 2;
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToWithdraw);

        // User ONLY approves initiator, NOT the vault
        vm.prank(shareOwner);
        IERC20(address(vault)).approve(initiator, sharesToWithdraw);

        assertEq(vault.allowance(shareOwner, address(vault)), 0, "User should NOT have approved vault");

        vm.prank(address(vault));
        vault.transferSharesFromOwner(shareOwner, sharesToWithdraw, initiator);

        // Set finalizationGuid to simulate cross-chain execution context
        MoreVaultsStorageHelper.setFinalizationGuid(address(vault), bytes32(uint256(1)));

        // Should succeed without vault allowance
        vm.prank(address(vault));
        vault.withdraw(assetsToWithdraw, shareOwner, shareOwner);
    }

    /**
     * @notice Test: Interest accrual should handle locked shares correctly
     */
    function test_accrueInterest_shouldHandleLockedSharesCorrectly() public {
        // Enable fee
        vm.prank(address(vault));
        vault.setFee(1000); // 10%

        uint256 initialTotalSupply = vault.totalSupply();
        uint256 sharesToLock = vault.balanceOf(shareOwner) / 2;

        vm.prank(shareOwner);
        IERC20(address(vault)).approve(initiator, sharesToLock);

        vm.prank(address(vault));
        vault.transferSharesFromOwner(shareOwner, sharesToLock, initiator);

        assertEq(vault.totalSupply(), initialTotalSupply, "TotalSupply should not change");

        vm.warp(block.timestamp + 365 days);

        uint256 totalAssets = vault.totalAssets();
        assertTrue(totalAssets > 0, "totalAssets should be positive");

        // Set finalizationGuid to simulate cross-chain execution context
        MoreVaultsStorageHelper.setFinalizationGuid(address(vault), bytes32(uint256(1)));

        // Should work correctly
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToLock);
        vm.prank(address(vault));
        vault.withdraw(assetsToWithdraw, shareOwner, shareOwner);
    }

    /**
     * @notice Test: Normal (non-cross-chain) withdraw should still work correctly
     * Ensures the fix doesn't break regular withdrawals
     */
    function test_normalWithdraw_shouldStillWork() public {
        uint256 ownerShares = vault.balanceOf(shareOwner);
        uint256 sharesToWithdraw = ownerShares / 2;
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToWithdraw);

        uint256 receiverBalanceBefore = underlying.balanceOf(shareOwner);

        // Normal withdraw (NOT setting finalizationGuid)
        vm.prank(shareOwner);
        vault.withdraw(assetsToWithdraw, shareOwner, shareOwner);

        uint256 receiverBalanceAfter = underlying.balanceOf(shareOwner);
        assertGt(receiverBalanceAfter, receiverBalanceBefore, "Receiver should have received assets");
        assertEq(vault.balanceOf(shareOwner), ownerShares - sharesToWithdraw, "Owner shares should decrease");
    }

    /**
     * @notice Test: Normal (non-cross-chain) redeem should still work correctly
     */
    function test_normalRedeem_shouldStillWork() public {
        uint256 ownerShares = vault.balanceOf(shareOwner);
        uint256 sharesToRedeem = ownerShares / 2;

        uint256 receiverBalanceBefore = underlying.balanceOf(shareOwner);

        // Normal redeem (NOT setting finalizationGuid)
        vm.prank(shareOwner);
        vault.redeem(sharesToRedeem, shareOwner, shareOwner);

        uint256 receiverBalanceAfter = underlying.balanceOf(shareOwner);
        assertGt(receiverBalanceAfter, receiverBalanceBefore, "Receiver should have received assets");
        assertEq(vault.balanceOf(shareOwner), ownerShares - sharesToRedeem, "Owner shares should decrease");
    }
}
