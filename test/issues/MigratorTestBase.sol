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

/// @notice Shared base for migrator-related issue tests.
/// Deploys two VaultFacet instances (oldVault, newVault) with a common ERC20 asset.
/// All vault-level mocks (registry, factory, escrow, oracle) are wired up.
abstract contract MigratorTestBase is Test {
    // Named test accounts
    address public owner       = address(0xA11CE);
    address public curator     = address(0xC0FFEE);
    address public guardian    = address(0x600D);
    address public feeRecipient = address(0xFEEF);
    address public user        = address(0xB0B);
    address public router      = address(0xBEEF01);

    // External mocks (shared addresses)
    address public registry     = address(0x1000);
    address public factory      = address(0x1001);
    address public oracleRegistry = address(0x1002);

    MockERC20           public asset;
    MockMoreVaultsEscrow public escrowOld;
    MockMoreVaultsEscrow public escrowNew;
    address public oldVault;
    address public newVault;

    uint96 constant FEE_10PCT = 1000;   // 10%
    uint96 constant NO_FEE    = 0;

    // ---------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------

    function _deployVault(
        address _asset,
        address _feeRecipient,
        uint96  _fee,
        MockMoreVaultsEscrow _escrow
    ) internal returns (address vault) {
        VaultFacet facet = new VaultFacet();
        vault = address(facet);

        // Wire storage
        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setOwner(vault, owner);
        MoreVaultsStorageHelper.setFactory(vault, factory);

        // Mock external calls required by initialize + accounting
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, _asset),
            abi.encode(address(0x9000), uint96(1 hours))
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), uint96(0))
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.router.selector),
            abi.encode(router)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector),
            abi.encode(address(_escrow))
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

        // Initialize vault
        bytes memory initData = abi.encode(
            "Test Vault",
            "TV",
            _asset,
            _feeRecipient,
            _fee,
            type(uint256).max  // depositCapacity: unlimited
        );
        VaultFacet(vault).initialize(initData);

        // Post-init storage config
        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setCurator(vault, curator);
        MoreVaultsStorageHelper.setGuardian(vault, guardian);
        MoreVaultsStorageHelper.setIsHub(vault, true);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(vault, 1 days);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(vault, 7 days);
    }

    function _baseSetUp() internal {
        vm.warp(block.timestamp + 1 days);

        // Deploy asset token
        asset = new MockERC20("Test Token", "TT");

        // Deploy escrows
        escrowOld = new MockMoreVaultsEscrow();
        escrowNew = new MockMoreVaultsEscrow();

        // Deploy vaults
        oldVault = _deployVault(address(asset), feeRecipient, FEE_10PCT, escrowOld);
        newVault = _deployVault(address(asset), feeRecipient, FEE_10PCT, escrowNew);

        escrowOld.setUnderlyingToken(oldVault, address(asset));
        escrowNew.setUnderlyingToken(newVault, address(asset));
    }

    /// @notice Fund user and deposit into oldVault.
    function _fundAndDepositUser(uint256 amount) internal returns (uint256 shares) {
        asset.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(asset)).approve(oldVault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(oldVault, user, type(uint256).max);
        shares = VaultFacet(oldVault).deposit(amount, user);
        vm.stopPrank();
    }

    /// @notice Request redeem and approve migrator for user's shares.
    function _requestRedeemAndApprove(address migrator, uint256 shares) internal {
        vm.startPrank(user);
        VaultFacet(oldVault).requestRedeem(shares, user);
        IERC20(oldVault).approve(migrator, shares);
        vm.stopPrank();
        // Fast-forward past timelock
        vm.warp(block.timestamp + 1 days + 1);
    }

    /// @notice Simulate yield by minting tokens directly to the vault.
    function _simulateYield(address vault_, uint256 amount) internal {
        asset.mint(vault_, amount);
    }
}
