// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {MoreVaultMigrator} from "../../../src/periphery/MoreVaultMigrator.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal queued ERC4626 vault that mimics MoreVault's requestRedeem + redeem gate.
contract MockQueuedVault is ERC4626, IVaultFacet {
    using SafeERC20 for IERC20;

    struct WithdrawRequest {
        uint256 timelockEndsAt;
        uint256 shares;
    }

    mapping(address => WithdrawRequest) internal requests;

    uint64 public withdrawTimelock;
    uint32 public maxWithdrawalDelay; // seconds
    bool public withdrawalQueueEnabled = true;

    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Mock Queued Vault", "vqMOCK") {
        withdrawTimelock = 1 days;
        maxWithdrawalDelay = 7 days;
    }

    function setQueueEnabled(bool enabled) external {
        withdrawalQueueEnabled = enabled;
    }

    function setWithdrawTimelock(uint64 tl) external {
        withdrawTimelock = tl;
    }

    function setMaxWithdrawalDelay(uint32 d) external {
        maxWithdrawalDelay = d;
    }

    function requestRedeem(uint256 shares, address onBehalfOf) external override {
        require(shares > 0, "shares=0");
        if (msg.sender != onBehalfOf) {
            uint256 currentAllowance = allowance(onBehalfOf, msg.sender);
            require(currentAllowance >= shares, "insufficient allowance");
        }
        requests[onBehalfOf] = WithdrawRequest({shares: shares, timelockEndsAt: block.timestamp + withdrawTimelock});
    }
    function requestRedeem(uint256 shares) external {
        require(shares > 0, "shares=0");
        requests[msg.sender] = WithdrawRequest({shares: shares, timelockEndsAt: block.timestamp + withdrawTimelock});
    }

    function requestWithdraw(uint256, address) external override {}

    function getWithdrawalRequest(address owner) external view override returns (uint256 shares, uint256 timelockEndsAt) {
        WithdrawRequest memory r = requests[owner];
        return (r.shares, r.timelockEndsAt);
    }

    function clearRequest() external override {
        delete requests[msg.sender];
    }

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 assets)
    {
        if (withdrawalQueueEnabled) {
            WithdrawRequest storage r = requests[owner];
            bool matured = block.timestamp >= r.timelockEndsAt
                && block.timestamp - r.timelockEndsAt <= (maxWithdrawalDelay < 1 days ? 1 days : maxWithdrawalDelay);
            require(matured, "not matured");
            require(r.shares >= shares, "insufficient requested");
            r.shares -= shares;
        }
        assets = super.redeem(shares, receiver, owner);
    }

    // Stub implementations for IVaultFacet interface (not used in these tests)
    function pause() external override {}
    function unpause() external override {}
    function paused() external view override returns (bool) { return false; }
    function totalAssets() public view override(ERC4626, IVaultFacet) returns (uint256) { return ERC4626.totalAssets(); }
    function totalAssetsUsd() external override returns (uint256, bool) { return (0, false); }
    function deposit(address[] calldata, uint256[] calldata, address, uint256)
        external
        payable
        override
        returns (uint256)
    {
        return 0;
    }
    function setFee(uint96) external override {}
    function accrueFees(address) external override {}
    function initialize(bytes calldata) external override {}
    function onFacetRemoval(bool) external override {}
    function facetName() external pure returns (string memory) { return "MockQueuedVault"; }
    function facetVersion() external pure returns (string memory) { return "1.0.0"; }
}

contract MoreVaultMigratorTest is Test {
    MockAsset public asset;
    MockQueuedVault public oldVault;
    MockQueuedVault public newVault;
    MoreVaultMigrator public migrator;

    address public owner = address(0xA11CE);
    address public curator = address(0xC0FFEE);
    address public user = address(0xB0B);

    function setUp() public {
        asset = new MockAsset();
        oldVault = new MockQueuedVault(address(asset));
        newVault = new MockQueuedVault(address(asset));
        migrator = new MoreVaultMigrator(address(oldVault), address(newVault), owner, curator);

        // Fund user and deposit into old vault to get shares.
        asset.mint(user, 100_000e18);
        vm.startPrank(user);
        asset.approve(address(oldVault), type(uint256).max);
        oldVault.deposit(10_000e18, user);
        vm.stopPrank();
    }

    function test_finalizeMigration_success() public {
        uint256 sharesToMigrate = oldVault.balanceOf(user) / 2;

        // User creates request and approves migrator to burn shares.
        vm.startPrank(user);
        oldVault.requestRedeem(sharesToMigrate);
        oldVault.approve(address(migrator), sharesToMigrate);
        vm.stopPrank();

        // Warp past timelock
        (, uint256 endsAt) = oldVault.getWithdrawalRequest(user);
        vm.warp(endsAt + 1);

        uint256 userOldSharesBefore = oldVault.balanceOf(user);
        uint256 userNewSharesBefore = newVault.balanceOf(user);

        vm.prank(curator);
        (uint256 sharesMigrated, uint256 assetsReceived, uint256 newSharesMinted) =
            migrator.finalizeMigration(user, sharesToMigrate, 0);

        assertEq(sharesMigrated, sharesToMigrate);
        assertGt(assetsReceived, 0);
        assertEq(newSharesMinted, assetsReceived); // 1:1 for this mock ERC4626

        assertEq(oldVault.balanceOf(user), userOldSharesBefore - sharesToMigrate);
        assertEq(newVault.balanceOf(user), userNewSharesBefore + newSharesMinted);
        assertEq(asset.balanceOf(address(migrator)), 0);
    }

    function test_finalizeMigration_reverts_whenNotCurator() public {
        vm.prank(user);
        vm.expectRevert(MoreVaultMigrator.NotCurator.selector);
        migrator.finalizeMigration(user, 1, 0);
    }

    function test_finalizeMigration_reverts_whenNothingToMigrate_noAllowance() public {
        uint256 sharesToMigrate = oldVault.balanceOf(user) / 2;

        vm.prank(user);
        oldVault.requestRedeem(sharesToMigrate);

        (, uint256 endsAt) = oldVault.getWithdrawalRequest(user);
        vm.warp(endsAt + 1);

        vm.prank(curator);
        vm.expectRevert(MoreVaultMigrator.NothingToMigrate.selector);
        migrator.finalizeMigration(user, sharesToMigrate, 0);
    }

    function test_finalizeMigration_reverts_whenNotMatured() public {
        uint256 sharesToMigrate = oldVault.balanceOf(user) / 2;

        vm.startPrank(user);
        oldVault.requestRedeem(sharesToMigrate);
        oldVault.approve(address(migrator), sharesToMigrate);
        vm.stopPrank();

        vm.prank(curator);
        vm.expectRevert(); // mock reverts with "not matured"
        migrator.finalizeMigration(user, sharesToMigrate, 0);
    }

    function test_constructor_reverts_onAssetMismatch() public {
        MockAsset other = new MockAsset();
        MockQueuedVault otherVault = new MockQueuedVault(address(other));

        vm.expectRevert(abi.encodeWithSelector(MoreVaultMigrator.AssetMismatch.selector, address(asset), address(other)));
        new MoreVaultMigrator(address(oldVault), address(otherVault), owner, curator);
    }

    function test_finalizeMigration_respectsMinNewShares() public {
        uint256 sharesToMigrate = oldVault.balanceOf(user) / 4;

        vm.startPrank(user);
        oldVault.requestRedeem(sharesToMigrate);
        oldVault.approve(address(migrator), sharesToMigrate);
        vm.stopPrank();

        (, uint256 endsAt) = oldVault.getWithdrawalRequest(user);
        vm.warp(endsAt + 1);

        // For this mock newShares == assetsReceived, so set min higher to force revert.
        uint256 impossibleMin = 10_000_000e18;
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(MoreVaultMigrator.SlippageExceeded.selector, sharesToMigrate, impossibleMin)
        );
        migrator.finalizeMigration(user, sharesToMigrate, impossibleMin);
    }

    function test_finalizeMigration_reverts_whenNothingToMigrate_noPending() public {
        vm.prank(curator);
        vm.expectRevert(MoreVaultMigrator.NothingToMigrate.selector);
        migrator.finalizeMigration(user, 1, 0);
    }
}


