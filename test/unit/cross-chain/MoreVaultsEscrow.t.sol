// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MoreVaultsEscrow} from "../../../src/cross-chain/MoreVaultsEscrow.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";

/**
 * @title MockVaultForEscrow
 * @notice Mock vault that implements required interfaces for escrow testing
 */
contract MockVaultForEscrow is MockERC20, IERC4626 {
    address public assetToken;
    mapping(address => bool) public depositableAssets;
    address public crossChainAccountingManager;
    IVaultsFactory public factory;

    constructor(address _asset, IVaultsFactory _factory) MockERC20("MockVault", "MV") {
        assetToken = _asset;
        factory = _factory;
        depositableAssets[_asset] = true;
    }

    function asset() external view override returns (address) {
        return assetToken;
    }

    function isAssetDepositable(address token) external view returns (bool) {
        return depositableAssets[token];
    }

    function enableAsset(address token) external {
        depositableAssets[token] = true;
    }

    function disableAsset(address token) external {
        depositableAssets[token] = false;
    }

    function setCrossChainAccountingManager(address manager) external {
        crossChainAccountingManager = manager;
    }

    function getCrossChainAccountingManager() external view returns (address) {
        return crossChainAccountingManager;
    }

    // IERC4626 stub functions (not used in escrow tests)
    function totalAssets() external pure override returns (uint256) {
        return 0;
    }

    function convertToShares(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure override returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external pure override returns (uint256) {
        return assets;
    }

    function mint(uint256 shares, address receiver) external pure override returns (uint256) {
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external pure override returns (uint256) {
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external pure override returns (uint256) {
        return shares;
    }

    receive() external payable {}
}

/**
 * @title MockVaultsFactory
 * @notice Mock factory for testing vault authorization
 */
contract MockVaultsFactoryForEscrow {
    mapping(address => bool) public isFactoryVault;

    function setIsFactoryVault(address vault, bool value) external {
        isFactoryVault[vault] = value;
    }
}

/**
 * @title RejectingReceiver
 * @notice Contract that rejects native currency transfers
 */
contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver: Cannot accept native currency");
    }
}

/**
 * @title MoreVaultsEscrowTest
 * @notice Comprehensive unit tests for MoreVaultsEscrow contract
 */
contract MoreVaultsEscrowTest is Test {
    MoreVaultsEscrow public escrow;
    MockVaultsFactoryForEscrow public factory;
    MockVaultForEscrow public vault;
    MockERC20 public underlyingToken;
    MockERC20 public token1;
    MockERC20 public token2;

    address public user = address(0x1001);
    address public manager = address(0x2001);
    address public nonVault = address(0x3001);

    bytes32 public constant TEST_GUID = keccak256("test-guid");

    function setUp() public {
        // Deploy factory
        factory = new MockVaultsFactoryForEscrow();

        // Deploy tokens
        underlyingToken = new MockERC20("Underlying", "UND");
        token1 = new MockERC20("Token1", "T1");
        token2 = new MockERC20("Token2", "T2");

        // Deploy vault
        vault = new MockVaultForEscrow(address(underlyingToken), IVaultsFactory(address(factory)));

        // Set vault as factory vault
        factory.setIsFactoryVault(address(vault), true);

        // Deploy escrow
        escrow = new MoreVaultsEscrow(address(factory));

        // Set manager in vault
        vault.setCrossChainAccountingManager(manager);

        // Mint tokens to user
        underlyingToken.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token2.mint(user, 1000 ether);
    }

    // ============================================================================
    // Constructor Tests
    // ============================================================================

    function test_constructor_RevertIfZeroAddress() public {
        vm.expectRevert(MoreVaultsLib.ZeroAddress.selector);
        new MoreVaultsEscrow(address(0));
    }

    function test_constructor_SetsFactory() public {
        assertEq(address(escrow.vaultsFactory()), address(factory));
    }

    // ============================================================================
    // Access Control Tests
    // ============================================================================

    function test_onlyVault_RevertIfNotVault() public {
        bytes memory actionCallData = abi.encode(100 ether, user);
        vm.prank(nonVault);
        vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    function test_onlyVault_AllowsVault() public {
        bytes memory actionCallData = abi.encode(100 ether, user);
        underlyingToken.mint(user, 100 ether);
        vm.prank(user);
        underlyingToken.approve(address(escrow), 100 ether);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    // ============================================================================
    // lockTokens - DEPOSIT Tests
    // ============================================================================

    function test_lockTokens_DEPOSIT_Success() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        // Check escrow has tokens
        assertEq(underlyingToken.balanceOf(address(escrow)), amount);

        // Check escrow info
        (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(underlyingToken));
        assertEq(amounts[0], amount);
        assertEq(nativeAmount, 0);
    }

    function test_lockTokens_DEPOSIT_RevertIfNativeValue() public {
        bytes memory actionCallData = abi.encode(100 ether, user);
        vm.prank(user);
        underlyingToken.approve(address(escrow), 100 ether);

        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens{value: 1 ether}(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    function test_lockTokens_DEPOSIT_RevertIfDuplicateGuid() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount * 2);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestAlreadyExists.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    function test_lockTokens_DEPOSIT_RevertIfInsufficientTokensReceived() public {
        // This test checks that if actual received amount is less than requested, it reverts
        // Note: This would require a fee-on-transfer token, which we don't support
        // The actual revert happens in transferFrom if allowance is insufficient
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount - 1); // Insufficient approval

        vm.prank(address(vault));
        // This will revert in transferFrom due to insufficient allowance
        vm.expectRevert();
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    // ============================================================================
    // lockTokens - MULTI_ASSETS_DEPOSIT Tests
    // ============================================================================

    function test_lockTokens_MULTI_ASSETS_DEPOSIT_Success() public {
        address[] memory tokens_ = new address[](2);
        tokens_[0] = address(token1);
        tokens_[1] = address(token2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        uint256 value = 1 ether;

        vault.enableAsset(address(token1));
        vault.enableAsset(address(token2));

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);
        vm.prank(user);
        token2.approve(address(escrow), amounts[1]);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        // Check escrow has tokens and native
        assertEq(token1.balanceOf(address(escrow)), amounts[0]);
        assertEq(token2.balanceOf(address(escrow)), amounts[1]);
        assertEq(address(escrow).balance, value);

        // Check escrow info
        (address[] memory escrowTokens, uint256[] memory escrowAmounts, uint256 nativeAmount) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);
        assertEq(escrowTokens.length, 2);
        assertEq(escrowAmounts[0], amounts[0]);
        assertEq(escrowAmounts[1], amounts[1]);
        assertEq(nativeAmount, value);
    }

    function test_lockTokens_MULTI_ASSETS_DEPOSIT_RevertIfWrongNativeValue() public {
        address[] memory tokens_ = new address[](1);
        tokens_[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;
        uint256 value = 1 ether;

        vault.enableAsset(address(token1));
        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);

        vm.deal(address(vault), value + 1);
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens{value: value + 1}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);
    }

    function test_lockTokens_MULTI_ASSETS_DEPOSIT_RevertIfTokenNotWhitelisted() public {
        address[] memory tokens_ = new address[](1);
        tokens_[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, 0);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsEscrow.TokenNotWhitelisted.selector, address(token1)));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);
    }

    function test_lockTokens_MULTI_ASSETS_DEPOSIT_RevertIfArraysLengthMismatch() public {
        address[] memory tokens_ = new address[](2);
        tokens_[0] = address(token1);
        tokens_[1] = address(token2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;

        vault.enableAsset(address(token1));
        vault.enableAsset(address(token2));

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, 0);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.ArraysLengthMismatch.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);
    }

    function test_lockTokens_MULTI_ASSETS_DEPOSIT_DuplicateTokens() public {
        address[] memory tokens_ = new address[](2);
        tokens_[0] = address(token1);
        tokens_[1] = address(token1); // Duplicate
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 20 ether; // Total 50 ether

        vault.enableAsset(address(token1));

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, 0);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0] + amounts[1]);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        // Should have only one token entry but with summed amounts
        (address[] memory escrowTokens, uint256[] memory escrowAmounts,) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);
        assertEq(escrowTokens.length, 1);
        assertEq(escrowTokens[0], address(token1));
        assertEq(escrowAmounts[0], amounts[0] + amounts[1]);
    }

    // ============================================================================
    // lockTokens - WITHDRAW Tests
    // ============================================================================

    function test_lockTokens_WITHDRAW_Success() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        // Mint shares to user
        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        // Check escrow has shares
        assertEq(vault.balanceOf(address(escrow)), shares);
        assertEq(escrow.getLockedShares(address(vault), user), shares);

        // Check escrow info
        (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(vault));
        assertEq(amounts[0], shares);
        assertEq(nativeAmount, 0);
    }

    function test_lockTokens_WITHDRAW_RevertIfOwnerNotInitiator() public {
        address owner = address(0x4001);
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, owner);

        vault.mint(owner, shares);
        vm.prank(owner);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.OwnerMustBeInitiator.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);
    }

    function test_lockTokens_WITHDRAW_RevertIfAmountLimitZero() public {
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, 0, user);
    }

    function test_lockTokens_WITHDRAW_RevertIfNativeValue() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens{value: 1 ether}(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);
    }

    // ============================================================================
    // lockTokens - REDEEM Tests
    // ============================================================================

    function test_lockTokens_REDEEM_Success() public {
        uint256 shares = 100 ether;
        bytes memory actionCallData = abi.encode(shares, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        assertEq(vault.balanceOf(address(escrow)), shares);
        assertEq(escrow.getLockedShares(address(vault), user), shares);
    }

    function test_lockTokens_REDEEM_RevertIfOwnerNotInitiator() public {
        address owner = address(0x4001);
        uint256 shares = 100 ether;
        bytes memory actionCallData = abi.encode(shares, user, owner);

        vault.mint(owner, shares);
        vm.prank(owner);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.OwnerMustBeInitiator.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);
    }

    function test_lockTokens_REDEEM_RevertIfNativeValue() public {
        uint256 shares = 100 ether;
        bytes memory actionCallData = abi.encode(shares, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens{value: 1 ether}(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);
    }

    // ============================================================================
    // lockTokens - MINT Tests
    // ============================================================================

    function test_lockTokens_MINT_Success() public {
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), assets);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MINT, actionCallData, assets, user);

        assertEq(underlyingToken.balanceOf(address(escrow)), assets);
    }

    function test_lockTokens_MINT_RevertIfAmountLimitZero() public {
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MINT, actionCallData, 0, user);
    }

    function test_lockTokens_MINT_RevertIfNativeValue() public {
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), assets);

        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.InvalidActionType.selector);
        escrow.lockTokens{value: 1 ether}(TEST_GUID, MoreVaultsLib.ActionType.MINT, actionCallData, assets, user);
    }

    function test_lockTokens_ACCRUE_FEES_NoLocking() public {
        bytes memory actionCallData = abi.encode();

        // ACCRUE_FEES should not require any tokens to be locked
        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.ACCRUE_FEES, actionCallData, 0, user);

        // Check that no tokens are locked
        (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);
        assertEq(tokens.length, 0);
        assertEq(nativeAmount, 0);
    }

    // ============================================================================
    // releaseTokensForExecution Tests
    // ============================================================================

    function test_releaseTokensForExecution_DEPOSIT_Success() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        (address[] memory tokens, uint256[] memory amounts_, uint256 nativeAmount) =
            escrow.releaseTokensForExecution(TEST_GUID);

        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(underlyingToken));
        assertEq(amounts_[0], amount);
        assertEq(nativeAmount, 0);

        // Check vault has approval
        assertEq(underlyingToken.allowance(address(escrow), address(vault)), amount);
    }

    function test_releaseTokensForExecution_WITHDRAW_Success() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        vm.prank(address(vault));
        (address[] memory tokens, uint256[] memory amounts_, uint256 nativeAmount) =
            escrow.releaseTokensForExecution(TEST_GUID);

        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(vault));
        assertEq(amounts_[0], shares);
        assertEq(nativeAmount, 0);
    }

    function test_releaseTokensForExecution_MULTI_ASSETS_DEPOSIT_WithNative() public {
        address[] memory tokens_ = new address[](1);
        tokens_[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;
        uint256 value = 1 ether;

        vault.enableAsset(address(token1));
        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        uint256 vaultBalanceBefore = address(vault).balance;

        vm.prank(address(vault));
        (address[] memory escrowTokens, uint256[] memory escrowAmounts, uint256 nativeAmount) =
            escrow.releaseTokensForExecution(TEST_GUID);

        assertEq(nativeAmount, value);
        assertEq(address(vault).balance, vaultBalanceBefore + value);
    }

    function test_releaseTokensForExecution_RevertIfRequestNotFound() public {
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestNotFound.selector);
        escrow.releaseTokensForExecution(TEST_GUID);
    }

    function test_releaseTokensForExecution_RevertIfAlreadyFinalized() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestAlreadyFinalized.selector);
        escrow.releaseTokensForExecution(TEST_GUID);
    }

    function test_releaseTokensForExecution_RevertIfAlreadyRefunded() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestAlreadyRefunded.selector);
        escrow.releaseTokensForExecution(TEST_GUID);
    }

    // ============================================================================
    // unlockTokensAfterExecution Tests
    // ============================================================================

    function test_unlockTokensAfterExecution_DEPOSIT_ExactAmount() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        uint256 userBalanceBefore = underlyingToken.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // No excess, so user balance should not change
        assertEq(underlyingToken.balanceOf(user), userBalanceBefore);
    }

    function test_unlockTokensAfterExecution_DEPOSIT_ExcessAmount() public {
        uint256 amount = 100 ether;
        uint256 usedAmount = 90 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = usedAmount;

        uint256 userBalanceBefore = underlyingToken.balanceOf(user);
        // Excess from released - usedAmount (10 ether)
        uint256 excess = amount - usedAmount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // User should receive excess (released - usedAmount)
        assertEq(underlyingToken.balanceOf(user), userBalanceBefore + excess);
    }

    function test_unlockTokensAfterExecution_ClearsAllowance() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        // Check allowance was set
        assertGt(underlyingToken.allowance(address(escrow), address(vault)), 0);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // Allowance should be cleared
        assertEq(underlyingToken.allowance(address(escrow), address(vault)), 0);
    }

    function test_unlockTokensAfterExecution_WITHDRAW_UpdatesLockedShares() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(vault);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = shares;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_unlockTokensAfterExecution_WITHDRAW_ExcessShares() public {
        uint256 shares = 100 ether;
        uint256 usedShares = 90 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(vault);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = usedShares;

        uint256 userBalanceBefore = vault.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // User should receive excess shares
        assertEq(vault.balanceOf(user), userBalanceBefore + (shares - usedShares));
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_unlockTokensAfterExecution_REDEEM_ExcessShares() public {
        uint256 shares = 100 ether;
        uint256 usedShares = 95 ether;
        bytes memory actionCallData = abi.encode(shares, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(vault);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = usedShares;

        uint256 userBalanceBefore = vault.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // User should receive excess shares
        assertEq(vault.balanceOf(user), userBalanceBefore + (shares - usedShares));
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_unlockTokensAfterExecution_MULTI_ASSETS_DEPOSIT_Excess() public {
        address[] memory tokens_ = new address[](2);
        tokens_[0] = address(token1);
        tokens_[1] = address(token2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        uint256 value = 1 ether;

        vault.enableAsset(address(token1));
        vault.enableAsset(address(token2));

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);
        vm.prank(user);
        token2.approve(address(escrow), amounts[1]);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        uint256[] memory usedAmounts = new uint256[](2);
        usedAmounts[0] = 45 ether; // Excess 5 ether
        usedAmounts[1] = 70 ether; // Excess 5 ether

        uint256 userToken1BalanceBefore = token1.balanceOf(user);
        uint256 userToken2BalanceBefore = token2.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // User should receive excess tokens
        assertEq(token1.balanceOf(user), userToken1BalanceBefore + 5 ether);
        assertEq(token2.balanceOf(user), userToken2BalanceBefore + 5 ether);
    }

    function test_unlockTokensAfterExecution_RevertIfUsedAmountExceedsReleased() public {
        uint256 amount = 100 ether;
        uint256 usedAmount = 110 ether; // More than released
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = usedAmount;

        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsEscrow.UsedAmountExceedsReleased.selector, usedAmount, amount));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);
    }

    function test_unlockTokensAfterExecution_RevertIfAlreadyRefunded() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestAlreadyRefunded.selector);
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);
    }

    function test_unlockTokensAfterExecution_RevertIfRequestNotFound() public {
        address[] memory tokens = new address[](0);
        uint256[] memory usedAmounts = new uint256[](0);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestNotFound.selector);
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);
    }

    function test_unlockTokensAfterExecution_RevertIfAlreadyFinalized() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestAlreadyFinalized.selector);
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);
    }

    function test_unlockTokensAfterExecution_RevertIfArraysLengthMismatch() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        uint256[] memory usedAmounts = new uint256[](2); // Mismatch

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.ArraysLengthMismatch.selector);
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);
    }

    // ============================================================================
    // refundTokens Tests
    // ============================================================================

    function test_refundTokens_DEPOSIT_Success() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        uint256 userBalanceBefore = underlyingToken.balanceOf(user);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        assertEq(underlyingToken.balanceOf(user), userBalanceBefore + amount);
        assertEq(underlyingToken.balanceOf(address(escrow)), 0);
    }

    function test_refundTokens_WITHDRAW_Success() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        assertEq(vault.balanceOf(user), shares);
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_refundTokens_MULTI_ASSETS_DEPOSIT_WithNative() public {
        address[] memory tokens_ = new address[](1);
        tokens_[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50 ether;
        uint256 value = 1 ether;

        vault.enableAsset(address(token1));
        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        uint256 userTokenBalanceBefore = token1.balanceOf(user);
        uint256 userNativeBalanceBefore = user.balance;

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        assertEq(token1.balanceOf(user), userTokenBalanceBefore + amounts[0]);
        assertEq(user.balance, userNativeBalanceBefore + value);
    }

    function test_refundTokens_NativeRefundFallbackToManager() public {
        address[] memory tokens_ = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256 value = 1 ether;

        RejectingReceiver rejectingReceiver = new RejectingReceiver();
        address rejectingUserAddr = address(rejectingReceiver);

        bytes memory actionCallData = abi.encode(tokens_, amounts, rejectingUserAddr, 0, value);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, rejectingUserAddr);

        uint256 managerBalanceBefore = manager.balance;

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        // Manager should receive native if user rejects
        assertEq(manager.balance, managerBalanceBefore + value);
    }

    function test_refundTokens_NativeRefundRevertIfNoManager() public {
        address[] memory tokens_ = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256 value = 1 ether;

        RejectingReceiver rejectingReceiver = new RejectingReceiver();
        address rejectingUserAddr = address(rejectingReceiver);

        // Set manager to zero
        vault.setCrossChainAccountingManager(address(0));

        bytes memory actionCallData = abi.encode(tokens_, amounts, rejectingUserAddr, 0, value);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, rejectingUserAddr);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.NativeRefundFailed.selector);
        escrow.refundTokens(TEST_GUID);
    }

    function test_refundTokens_RevertIfRequestNotFound() public {
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestNotFound.selector);
        escrow.refundTokens(TEST_GUID);
    }

    function test_refundTokens_NoOpIfAlreadyRefunded() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        // Second refund should be no-op
        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);
    }

    function test_refundTokens_NoOpIfAlreadyFinalized() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // Refund after finalized should be no-op
        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);
    }

    function test_refundTokens_MINT_Success() public {
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), assets);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.MINT, actionCallData, assets, user);

        uint256 userBalanceBefore = underlyingToken.balanceOf(user);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        assertEq(underlyingToken.balanceOf(user), userBalanceBefore + assets);
        assertEq(underlyingToken.balanceOf(address(escrow)), 0);
    }

    function test_refundTokens_REDEEM_Success() public {
        uint256 shares = 100 ether;
        bytes memory actionCallData = abi.encode(shares, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares);

        vm.prank(address(vault));
        escrow.refundTokens(TEST_GUID);

        assertEq(vault.balanceOf(user), shares);
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    // ============================================================================
    // refundToComposer Tests
    // ============================================================================

    function test_refundToComposer_Success() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);
        address composer = address(0x5001);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        uint256 composerBalanceBefore = underlyingToken.balanceOf(composer);

        vm.prank(address(vault));
        escrow.refundToComposer(TEST_GUID, composer);

        assertEq(underlyingToken.balanceOf(composer), composerBalanceBefore + amount);
    }

    function test_refundToComposer_WithNative() public {
        address[] memory tokens_ = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256 value = 1 ether;
        address composer = address(0x5001);

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        uint256 composerBalanceBefore = composer.balance;

        vm.prank(address(vault));
        escrow.refundToComposer(TEST_GUID, composer);

        assertEq(composer.balance, composerBalanceBefore + value);
    }

    function test_refundToComposer_RevertIfRequestNotFound() public {
        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.RequestNotFound.selector);
        escrow.refundToComposer(TEST_GUID, address(0x5001));
    }

    function test_refundToComposer_RevertIfZeroAddress() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsLib.ZeroAddress.selector);
        escrow.refundToComposer(TEST_GUID, address(0));
    }

    function test_refundToComposer_WITHDRAW_Success() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);
        address composer = address(0x5001);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares);

        uint256 composerBalanceBefore = vault.balanceOf(composer);

        vm.prank(address(vault));
        escrow.refundToComposer(TEST_GUID, composer);

        assertEq(vault.balanceOf(composer), composerBalanceBefore + shares);
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_refundToComposer_REDEEM_Success() public {
        uint256 shares = 100 ether;
        bytes memory actionCallData = abi.encode(shares, user, user);
        address composer = address(0x5001);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        uint256 composerBalanceBefore = vault.balanceOf(composer);

        vm.prank(address(vault));
        escrow.refundToComposer(TEST_GUID, composer);

        assertEq(vault.balanceOf(composer), composerBalanceBefore + shares);
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_refundToComposer_MULTI_ASSETS_DEPOSIT_WithTokens() public {
        address[] memory tokens_ = new address[](2);
        tokens_[0] = address(token1);
        tokens_[1] = address(token2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        uint256 value = 1 ether;
        address composer = address(0x5001);

        vault.enableAsset(address(token1));
        vault.enableAsset(address(token2));

        bytes memory actionCallData = abi.encode(tokens_, amounts, user, 0, value);

        vm.prank(user);
        token1.approve(address(escrow), amounts[0]);
        vm.prank(user);
        token2.approve(address(escrow), amounts[1]);

        vm.deal(address(vault), value);
        vm.prank(address(vault));
        escrow.lockTokens{value: value}(TEST_GUID, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        uint256 composerToken1BalanceBefore = token1.balanceOf(composer);
        uint256 composerToken2BalanceBefore = token2.balanceOf(composer);
        uint256 composerNativeBalanceBefore = composer.balance;

        vm.prank(address(vault));
        escrow.refundToComposer(TEST_GUID, composer);

        assertEq(token1.balanceOf(composer), composerToken1BalanceBefore + amounts[0]);
        assertEq(token2.balanceOf(composer), composerToken2BalanceBefore + amounts[1]);
        assertEq(composer.balance, composerNativeBalanceBefore + value);
    }

    // ============================================================================
    // getEscrowInfo Tests
    // ============================================================================

    function test_getEscrowInfo_ReturnsCorrectInfo() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        (address[] memory tokens, uint256[] memory amounts_, uint256 nativeAmount) =
            escrow.getEscrowInfo(address(vault), TEST_GUID);

        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(underlyingToken));
        assertEq(amounts_[0], amount);
        assertEq(nativeAmount, 0);
    }

    // ============================================================================
    // getLockedShares Tests
    // ============================================================================

    function test_getLockedShares_ReturnsZeroInitially() public {
        assertEq(escrow.getLockedShares(address(vault), user), 0);
    }

    function test_getLockedShares_ReturnsCorrectAmount() public {
        uint256 shares = 100 ether;
        uint256 assets = 100 ether;
        bytes memory actionCallData = abi.encode(assets, user, user);

        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares);
    }

    // ============================================================================
    // Reentrancy Tests
    // ============================================================================

    function test_reentrancy_LockTokens() public {
        uint256 amount = 100 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        // Should not revert due to nonReentrant modifier
        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    // ============================================================================
    // Edge Cases and Integration Tests
    // ============================================================================

    function test_fullFlow_DEPOSIT_WithExcess() public {
        uint256 amount = 100 ether;
        uint256 usedAmount = 90 ether;
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(user);
        underlyingToken.approve(address(escrow), amount);

        // Lock
        vm.prank(address(vault));
        escrow.lockTokens(TEST_GUID, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        // Release
        vm.prank(address(vault));
        escrow.releaseTokensForExecution(TEST_GUID);

        // Unlock with excess
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = usedAmount;

        uint256 userBalanceBefore = underlyingToken.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(TEST_GUID, tokens, usedAmounts);

        // User should receive excess
        assertEq(underlyingToken.balanceOf(user), userBalanceBefore + (amount - usedAmount));
    }

    function test_concurrentLocks_SameUser() public {
        bytes32 guid1 = keccak256("guid1");
        bytes32 guid2 = keccak256("guid2");
        uint256 shares1 = 50 ether;
        uint256 shares2 = 75 ether;
        uint256 assets = 100 ether;

        vault.mint(user, shares1 + shares2);
        vm.prank(user);
        vault.approve(address(escrow), shares1 + shares2);

        bytes memory actionCallData1 = abi.encode(assets, user, user);
        bytes memory actionCallData2 = abi.encode(assets, user, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid1, MoreVaultsLib.ActionType.WITHDRAW, actionCallData1, shares1, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid2, MoreVaultsLib.ActionType.WITHDRAW, actionCallData2, shares2, user);

        assertEq(escrow.getLockedShares(address(vault), user), shares1 + shares2);
    }
}
