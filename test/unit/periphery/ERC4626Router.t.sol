// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Router} from "../../../src/periphery/ERC4626Router.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is ERC4626 {
    uint256 public slippageBps; // Simulates price change between preview and execution
    bool public whitelistEnabled;
    bool public withdrawalQueueEnabled;

    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Mock Vault", "vMOCK") {}

    function setWhitelistEnabled(bool _enabled) external {
        whitelistEnabled = _enabled;
    }

    function setWithdrawalQueueEnabled(bool _enabled) external {
        withdrawalQueueEnabled = _enabled;
    }

    function isDepositWhitelistEnabled() external view returns (bool) {
        return whitelistEnabled;
    }

    function getWithdrawalQueueStatus() external view returns (bool) {
        return withdrawalQueueEnabled;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        // Simulate slippage: reduce shares by slippageBps
        if (slippageBps > 0) {
            uint256 reduction = (shares * slippageBps) / 10000;
            _burn(receiver, reduction);
            shares -= reduction;
        }
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        // Simulate slippage: increase assets cost
        if (slippageBps > 0) {
            assets += (assets * slippageBps) / 10000;
        }
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner);
        // Simulate slippage: burn more shares
        if (slippageBps > 0) {
            uint256 extra = (shares * slippageBps) / 10000;
            _burn(owner, extra);
            shares += extra;
        }
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
        // Simulate slippage: reduce assets received
        if (slippageBps > 0) {
            uint256 reduction = (assets * slippageBps) / 10000;
            assets -= reduction;
        }
    }

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC4626RouterTest is Test {
    ERC4626Router public router;
    MockAsset public asset;
    MockVault public vault;

    address public user = address(0x1);
    address public receiver = address(0x2);

    function setUp() public {
        router = new ERC4626Router();
        asset = new MockAsset();
        vault = new MockVault(address(asset));

        // Setup user with assets
        asset.mint(user, 100_000e18);
        vm.prank(user);
        asset.approve(address(router), type(uint256).max);
    }

    // ========== DEPOSIT TESTS ==========

    function test_depositWithSlippage_Success() public {
        uint256 assets = 1000e18;
        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 minShares = (expectedShares * 99) / 100; // 1% tolerance

        vm.prank(user);
        uint256 shares = router.depositWithSlippage(vault, assets, minShares, receiver);

        assertGe(shares, minShares);
        assertEq(vault.balanceOf(receiver), shares);
    }

    function test_depositWithSlippage_RevertsOnSlippage() public {
        uint256 assets = 1000e18;
        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 minShares = expectedShares; // Exact amount, no tolerance

        vault.setSlippage(100); // 1% slippage

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Router.SlippageExceeded.selector, expectedShares * 99 / 100, minShares)
        );
        router.depositWithSlippage(vault, assets, minShares, receiver);
    }

    function test_depositWithSlippage_AcceptsWithinTolerance() public {
        uint256 assets = 1000e18;
        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 minShares = (expectedShares * 98) / 100; // 2% tolerance

        vault.setSlippage(100); // 1% slippage (within tolerance)

        vm.prank(user);
        uint256 shares = router.depositWithSlippage(vault, assets, minShares, receiver);

        assertGe(shares, minShares);
    }

    // ========== MINT TESTS ==========

    function test_mintWithSlippage_Success() public {
        uint256 shares = 1000e18;
        uint256 expectedAssets = vault.previewMint(shares);
        uint256 maxAssets = (expectedAssets * 101) / 100; // 1% tolerance

        vm.prank(user);
        uint256 assets = router.mintWithSlippage(vault, shares, maxAssets, receiver);

        assertLe(assets, maxAssets);
        assertEq(vault.balanceOf(receiver), shares);
    }

    function test_mintWithSlippage_RefundsExcess() public {
        uint256 shares = 1000e18;
        uint256 expectedAssets = vault.previewMint(shares);
        uint256 maxAssets = expectedAssets * 2; // Double the needed amount

        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        uint256 assets = router.mintWithSlippage(vault, shares, maxAssets, receiver);

        uint256 balanceAfter = asset.balanceOf(user);
        assertEq(balanceBefore - balanceAfter, assets); // Only spent what was needed
    }

    // ========== WITHDRAW TESTS ==========

    function test_withdrawWithSlippage_Success() public {
        // First deposit to get shares
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);

        // Approve router to pull shares
        vault.approve(address(router), type(uint256).max);

        uint256 withdrawAssets = 500e18;
        uint256 expectedShares = vault.previewWithdraw(withdrawAssets);
        uint256 maxShares = (expectedShares * 102) / 100; // 2% tolerance

        uint256 shares = router.withdrawWithSlippage(vault, withdrawAssets, maxShares, receiver, user);
        vm.stopPrank();

        assertLe(shares, maxShares);
        assertEq(asset.balanceOf(receiver), withdrawAssets);
    }

    function test_withdrawWithSlippage_RefundsUnusedShares() public {
        // First deposit
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);

        vault.approve(address(router), type(uint256).max);

        uint256 withdrawAssets = 500e18;
        uint256 maxShares = userShares; // Send all shares

        uint256 sharesBefore = vault.balanceOf(user);
        uint256 shares = router.withdrawWithSlippage(vault, withdrawAssets, maxShares, receiver, user);
        uint256 sharesAfter = vault.balanceOf(user);
        vm.stopPrank();

        // Should get refund of unused shares
        assertEq(sharesBefore - sharesAfter, shares);
    }

    // ========== REDEEM TESTS ==========

    function test_redeemWithSlippage_Success() public {
        // First deposit
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);

        vault.approve(address(router), type(uint256).max);

        uint256 redeemShares = userShares / 2;
        uint256 expectedAssets = vault.previewRedeem(redeemShares);
        uint256 minAssets = (expectedAssets * 99) / 100; // 1% tolerance

        uint256 assets = router.redeemWithSlippage(vault, redeemShares, minAssets, receiver, user);
        vm.stopPrank();

        assertGe(assets, minAssets);
        assertEq(asset.balanceOf(receiver), assets);
    }

    function test_redeemWithSlippage_RevertsOnSlippage() public {
        // First deposit
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);

        vault.approve(address(router), type(uint256).max);

        uint256 redeemShares = userShares / 2;
        uint256 expectedAssets = vault.previewRedeem(redeemShares);
        uint256 minAssets = expectedAssets; // Exact amount

        vault.setSlippage(200); // 2% slippage

        vm.expectRevert(); // SlippageExceeded
        router.redeemWithSlippage(vault, redeemShares, minAssets, receiver, user);
        vm.stopPrank();
    }

    // ========== WHITELIST AND WITHDRAWAL QUEUE CHECKS ==========

    function test_depositWithSlippage_RevertsWhenWhitelistEnabled() public {
        vault.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(ERC4626Router.DepositWhitelistEnabled.selector);
        router.depositWithSlippage(vault, 1000e18, 0, receiver);
    }

    function test_mintWithSlippage_RevertsWhenWhitelistEnabled() public {
        vault.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(ERC4626Router.DepositWhitelistEnabled.selector);
        router.mintWithSlippage(vault, 1000e18, type(uint256).max, receiver);
    }

    function test_withdrawWithSlippage_RevertsWhenWithdrawalQueueEnabled() public {
        // First deposit to get shares
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        vault.deposit(depositAssets, user);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vault.setWithdrawalQueueEnabled(true);

        vm.prank(user);
        vm.expectRevert(ERC4626Router.WithdrawalQueueEnabled.selector);
        router.withdrawWithSlippage(vault, 500e18, type(uint256).max, receiver, user);
    }

    function test_redeemWithSlippage_RevertsWhenWithdrawalQueueEnabled() public {
        // First deposit to get shares
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 shares = vault.deposit(depositAssets, user);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vault.setWithdrawalQueueEnabled(true);

        vm.prank(user);
        vm.expectRevert(ERC4626Router.WithdrawalQueueEnabled.selector);
        router.redeemWithSlippage(vault, shares, 0, receiver, user);
    }

    function test_depositWithSlippage_WorksWhenWhitelistDisabled() public {
        vault.setWhitelistEnabled(false);

        vm.prank(user);
        uint256 shares = router.depositWithSlippage(vault, 1000e18, 0, receiver);

        assertGt(shares, 0);
    }

    function test_withdrawWithSlippage_WorksWhenWithdrawalQueueDisabled() public {
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();

        vault.setWithdrawalQueueEnabled(false);

        vm.prank(user);
        uint256 shares = router.withdrawWithSlippage(vault, 500e18, userShares, receiver, user);

        assertGt(shares, 0);
    }

    // ========== EDGE CASES ==========

    function test_depositWithSlippage_ZeroMinShares() public {
        uint256 assets = 1000e18;

        vm.prank(user);
        uint256 shares = router.depositWithSlippage(vault, assets, 0, receiver);

        assertGt(shares, 0);
    }

    function test_redeemWithSlippage_ZeroMinAssets() public {
        uint256 depositAssets = 1000e18;
        vm.startPrank(user);
        asset.approve(address(vault), depositAssets);
        uint256 userShares = vault.deposit(depositAssets, user);

        vault.approve(address(router), type(uint256).max);

        uint256 assets = router.redeemWithSlippage(vault, userShares, 0, receiver, user);
        vm.stopPrank();

        assertGt(assets, 0);
    }

    // ========== FUZZ TESTS ==========

    function testFuzz_depositWithSlippage(uint256 assets, uint256 slippageBps) public {
        assets = bound(assets, 1e18, 10_000e18);
        slippageBps = bound(slippageBps, 0, 500); // 0-5%

        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 minShares = (expectedShares * (10000 - slippageBps)) / 10000;

        vm.prank(user);
        uint256 shares = router.depositWithSlippage(vault, assets, minShares, receiver);

        assertGe(shares, minShares);
        assertEq(vault.balanceOf(receiver), shares);
    }

    function testFuzz_mintWithSlippage(uint256 shares, uint256 toleranceBps) public {
        shares = bound(shares, 1e18, 10_000e18);
        toleranceBps = bound(toleranceBps, 100, 1000); // 1-10% tolerance

        uint256 expectedAssets = vault.previewMint(shares);
        uint256 maxAssets = (expectedAssets * (10000 + toleranceBps)) / 10000;

        vm.prank(user);
        uint256 assets = router.mintWithSlippage(vault, shares, maxAssets, receiver);

        assertLe(assets, maxAssets);
        assertEq(vault.balanceOf(receiver), shares);
    }

    function testFuzz_redeemWithSlippage(uint256 depositAmount, uint256 redeemPct, uint256 slippageBps) public {
        depositAmount = bound(depositAmount, 1e18, 10_000e18);
        redeemPct = bound(redeemPct, 10, 100); // 10-100%
        slippageBps = bound(slippageBps, 0, 500); // 0-5%

        // Deposit first
        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        uint256 userShares = vault.deposit(depositAmount, user);

        vault.approve(address(router), type(uint256).max);

        uint256 redeemShares = (userShares * redeemPct) / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 expectedAssets = vault.previewRedeem(redeemShares);
        uint256 minAssets = (expectedAssets * (10000 - slippageBps)) / 10000;

        uint256 assets = router.redeemWithSlippage(vault, redeemShares, minAssets, receiver, user);
        vm.stopPrank();

        assertGe(assets, minAssets);
    }

    function testFuzz_withdrawWithSlippage(uint256 depositAmount, uint256 withdrawPct, uint256 toleranceBps) public {
        depositAmount = bound(depositAmount, 1e18, 10_000e18);
        withdrawPct = bound(withdrawPct, 10, 90); // 10-90%
        toleranceBps = bound(toleranceBps, 100, 1000); // 1-10%

        // Deposit first
        vm.startPrank(user);
        asset.approve(address(vault), depositAmount);
        uint256 userShares = vault.deposit(depositAmount, user);

        vault.approve(address(router), type(uint256).max);

        uint256 withdrawAssets = (depositAmount * withdrawPct) / 100;
        if (withdrawAssets == 0) withdrawAssets = 1;

        uint256 expectedShares = vault.previewWithdraw(withdrawAssets);
        uint256 maxShares = (expectedShares * (10000 + toleranceBps)) / 10000;

        uint256 shares = router.withdrawWithSlippage(vault, withdrawAssets, maxShares, receiver, user);
        vm.stopPrank();

        assertLe(shares, maxShares);
    }
}

contract ERC4626RouterInvariantTest is Test {
    ERC4626Router public router;
    MockAsset public asset;
    MockVault public vault;
    RouterHandler public handler;

    function setUp() public {
        router = new ERC4626Router();
        asset = new MockAsset();
        vault = new MockVault(address(asset));
        handler = new RouterHandler(router, asset, vault);

        targetContract(address(handler));
    }

    /// @notice Router should never hold assets after any operation
    function invariant_routerHoldsNoAssets() public view {
        assertEq(asset.balanceOf(address(router)), 0);
    }

    /// @notice Router should never hold vault shares after any operation
    function invariant_routerHoldsNoShares() public view {
        assertEq(vault.balanceOf(address(router)), 0);
    }
}

contract RouterHandler is Test {
    ERC4626Router public router;
    MockAsset public asset;
    MockVault public vault;

    address public user = address(0x1111);
    address public receiver = address(0x2222);

    constructor(ERC4626Router _router, MockAsset _asset, MockVault _vault) {
        router = _router;
        asset = _asset;
        vault = _vault;

        asset.mint(user, 1_000_000e18);
        vm.startPrank(user);
        asset.approve(address(router), type(uint256).max);
        asset.approve(address(vault), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function deposit(uint256 assets) external {
        assets = bound(assets, 1e18, 10_000e18);
        uint256 minShares = vault.previewDeposit(assets) * 95 / 100;

        vm.prank(user);
        router.depositWithSlippage(vault, assets, minShares, receiver);
    }

    function mint(uint256 shares) external {
        shares = bound(shares, 1e18, 10_000e18);
        uint256 maxAssets = vault.previewMint(shares) * 105 / 100;

        vm.prank(user);
        router.mintWithSlippage(vault, shares, maxAssets, receiver);
    }

    function redeem(uint256 shares) external {
        uint256 balance = vault.balanceOf(user);
        if (balance == 0) return;

        shares = bound(shares, 1, balance);
        uint256 minAssets = vault.previewRedeem(shares) * 95 / 100;

        vm.prank(user);
        router.redeemWithSlippage(vault, shares, minAssets, receiver, user);
    }

    function withdraw(uint256 assets) external {
        uint256 maxAssets = vault.convertToAssets(vault.balanceOf(user));
        if (maxAssets == 0) return;

        assets = bound(assets, 1, maxAssets * 90 / 100);
        uint256 maxShares = vault.previewWithdraw(assets) * 105 / 100;

        vm.prank(user);
        router.withdrawWithSlippage(vault, assets, maxShares, receiver, user);
    }
}
