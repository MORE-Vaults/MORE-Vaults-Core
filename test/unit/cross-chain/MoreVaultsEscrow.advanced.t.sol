// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MoreVaultsEscrow} from "../../../src/cross-chain/MoreVaultsEscrow.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MockVaultAdvanced
 * @notice Mock vault for advanced testing including reentrancy scenarios
 */
contract MockVaultAdvanced is MockERC20, IERC4626 {
    address public assetToken;
    mapping(address => bool) public depositableAssets;
    address public crossChainAccountingManager;

    constructor(address _asset) MockERC20("MockVault", "MV") {
        assetToken = _asset;
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

    function getCrossChainAccountingManager() external view returns (address) {
        return crossChainAccountingManager;
    }

    function setCrossChainAccountingManager(address manager) external {
        crossChainAccountingManager = manager;
    }

    // IERC4626 stubs
    function totalAssets() external pure override returns (uint256) { return 0; }
    function convertToShares(uint256 assets) external pure override returns (uint256) { return assets; }
    function convertToAssets(uint256 shares) external pure override returns (uint256) { return shares; }
    function maxDeposit(address) external pure override returns (uint256) { return type(uint256).max; }
    function maxMint(address) external pure override returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address owner) external view override returns (uint256) { return balanceOf(owner); }
    function maxRedeem(address owner) external view override returns (uint256) { return balanceOf(owner); }
    function previewDeposit(uint256 assets) external pure override returns (uint256) { return assets; }
    function previewMint(uint256 shares) external pure override returns (uint256) { return shares; }
    function previewWithdraw(uint256 assets) external pure override returns (uint256) { return assets; }
    function previewRedeem(uint256 shares) external pure override returns (uint256) { return shares; }
    function deposit(uint256 assets, address) external pure override returns (uint256) { return assets; }
    function mint(uint256 shares, address) external pure override returns (uint256) { return shares; }
    function withdraw(uint256, address, address) external pure override returns (uint256) { return 0; }
    function redeem(uint256, address, address) external pure override returns (uint256) { return 0; }

    receive() external payable {}
}

/**
 * @title MockFactoryAdvanced
 */
contract MockFactoryAdvanced {
    mapping(address => bool) public isFactoryVault;

    function setIsFactoryVault(address vault, bool value) external {
        isFactoryVault[vault] = value;
    }
}

/**
 * @title ReentrancyAttacker
 * @notice Contract that attempts reentrancy attacks on escrow
 */
contract ReentrancyAttacker {
    MoreVaultsEscrow public escrow;
    MockVaultAdvanced public vault;
    MockERC20 public token;
    bytes32 public attackGuid;
    uint256 public attackCount;
    uint256 public maxAttacks;
    bool public attacking;

    enum AttackType { LOCK, RELEASE, UNLOCK, REFUND }
    AttackType public currentAttack;

    constructor(MoreVaultsEscrow _escrow, MockVaultAdvanced _vault, MockERC20 _token) {
        escrow = _escrow;
        vault = _vault;
        token = _token;
    }

    function setupAttack(bytes32 guid, AttackType attackType, uint256 _maxAttacks) external {
        attackGuid = guid;
        currentAttack = attackType;
        maxAttacks = _maxAttacks;
        attackCount = 0;
        attacking = true;
    }

    // Called when receiving native tokens during refund
    receive() external payable {
        if (!attacking || attackCount >= maxAttacks) return;
        attackCount++;

        if (currentAttack == AttackType.REFUND) {
            // Try to call refund again (reentrancy)
            try escrow.refundTokens(attackGuid) {
                // If this succeeds, reentrancy protection failed!
            } catch {}
        }
    }

    // ERC20 callback hook (some tokens have this)
    function tokensReceived(address, address, uint256) external {
        if (!attacking || attackCount >= maxAttacks) return;
        attackCount++;

        if (currentAttack == AttackType.LOCK) {
            bytes memory actionCallData = abi.encode(1 ether, address(this));
            bytes32 newGuid = keccak256(abi.encodePacked("reentrant", attackCount));
            try escrow.lockTokens(newGuid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, address(this)) {
                // Reentrancy succeeded - bad!
            } catch {}
        }
    }
}

/**
 * @title MaliciousToken
 * @notice Token that calls back during transfers (for reentrancy testing)
 */
contract MaliciousToken is MockERC20 {
    address public callbackTarget;
    bool public callbackEnabled;

    constructor() MockERC20("Malicious", "MAL") {}

    function setCallback(address target) external {
        callbackTarget = target;
        callbackEnabled = true;
    }

    function disableCallback() external {
        callbackEnabled = false;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        // Callback on transfers if enabled
        if (callbackEnabled && callbackTarget != address(0) && to == callbackTarget) {
            // Call tokensReceived on target
            (bool success,) = callbackTarget.call(
                abi.encodeWithSignature("tokensReceived(address,address,uint256)", from, to, value)
            );
            success; // Silence unused variable warning
        }
    }
}

/**
 * @title MoreVaultsEscrowAdvancedTest
 * @notice Advanced tests: integration, reentrancy, multi-assets
 */
contract MoreVaultsEscrowAdvancedTest is Test {
    MoreVaultsEscrow public escrow;
    MockFactoryAdvanced public factory;
    MockVaultAdvanced public vault;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;

    address public user = makeAddr("user");
    address public manager = makeAddr("manager");

    function setUp() public {
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        token3 = new MockERC20("Token3", "TK3");

        factory = new MockFactoryAdvanced();
        vault = new MockVaultAdvanced(address(token1));
        vault.enableAsset(address(token2));
        vault.enableAsset(address(token3));
        vault.setCrossChainAccountingManager(manager);

        factory.setIsFactoryVault(address(vault), true);
        escrow = new MoreVaultsEscrow(address(factory));
    }

    // ============ MULTI_ASSETS_DEPOSIT TESTS ============

    /**
     * @notice Test MULTI_ASSETS_DEPOSIT with 2 tokens
     */
    function test_multiAssets_TwoTokens() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;

        token1.mint(user, amount1);
        token2.mint(user, amount2);

        vm.startPrank(user);
        token1.approve(address(escrow), amount1);
        token2.approve(address(escrow), amount2);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, uint256(0));
        bytes32 guid = keccak256("multi2");

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        assertEq(token1.balanceOf(address(escrow)), amount1);
        assertEq(token2.balanceOf(address(escrow)), amount2);
    }

    /**
     * @notice Test MULTI_ASSETS_DEPOSIT with 3 tokens + native
     */
    function test_multiAssets_ThreeTokensWithNative() public {
        uint256 amount1 = 50 ether;
        uint256 amount2 = 75 ether;
        uint256 amount3 = 100 ether;
        uint256 nativeAmount = 1 ether;

        token1.mint(user, amount1);
        token2.mint(user, amount2);
        token3.mint(user, amount3);
        vm.deal(address(vault), nativeAmount); // Native goes to vault since vault calls escrow

        vm.startPrank(user);
        token1.approve(address(escrow), amount1);
        token2.approve(address(escrow), amount2);
        token3.approve(address(escrow), amount3);
        vm.stopPrank();

        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount1;
        amounts[1] = amount2;
        amounts[2] = amount3;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, nativeAmount);
        bytes32 guid = keccak256("multi3native");

        vm.prank(address(vault));
        escrow.lockTokens{value: nativeAmount}(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        assertEq(token1.balanceOf(address(escrow)), amount1);
        assertEq(token2.balanceOf(address(escrow)), amount2);
        assertEq(token3.balanceOf(address(escrow)), amount3);
        assertEq(address(escrow).balance, nativeAmount);
    }

    /**
     * @notice Fuzz test: MULTI_ASSETS_DEPOSIT with random amounts
     */
    function testFuzz_multiAssets_RandomAmounts(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3,
        uint256 nativeAmount
    ) public {
        amount1 = bound(amount1, 1, 1e24);
        amount2 = bound(amount2, 1, 1e24);
        amount3 = bound(amount3, 1, 1e24);
        nativeAmount = bound(nativeAmount, 0, 100 ether);

        token1.mint(user, amount1);
        token2.mint(user, amount2);
        token3.mint(user, amount3);
        vm.deal(address(vault), nativeAmount); // Native goes to vault

        vm.startPrank(user);
        token1.approve(address(escrow), amount1);
        token2.approve(address(escrow), amount2);
        token3.approve(address(escrow), amount3);
        vm.stopPrank();

        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount1;
        amounts[1] = amount2;
        amounts[2] = amount3;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, nativeAmount);
        bytes32 guid = keccak256(abi.encodePacked(amount1, amount2, amount3, nativeAmount));

        vm.prank(address(vault));
        escrow.lockTokens{value: nativeAmount}(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        assertEq(token1.balanceOf(address(escrow)), amount1);
        assertEq(token2.balanceOf(address(escrow)), amount2);
        assertEq(token3.balanceOf(address(escrow)), amount3);
        assertEq(address(escrow).balance, nativeAmount);
    }

    /**
     * @notice Test MULTI_ASSETS_DEPOSIT with duplicate token (should aggregate)
     */
    function test_multiAssets_DuplicateToken() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 50 ether;

        token1.mint(user, amount1 + amount2);

        vm.startPrank(user);
        token1.approve(address(escrow), amount1 + amount2);
        vm.stopPrank();

        // Same token appears twice
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, uint256(0));
        bytes32 guid = keccak256("duplicate");

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        // Total should be aggregated
        assertEq(token1.balanceOf(address(escrow)), amount1 + amount2);
    }

    /**
     * @notice Test MULTI_ASSETS_DEPOSIT full flow: lock -> release -> unlock
     */
    function test_multiAssets_FullFlow() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        uint256 nativeAmount = 1 ether;

        token1.mint(user, amount1);
        token2.mint(user, amount2);
        vm.deal(address(vault), nativeAmount); // Native goes to vault

        vm.startPrank(user);
        token1.approve(address(escrow), amount1);
        token2.approve(address(escrow), amount2);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, nativeAmount);
        bytes32 guid = keccak256("fullflow");

        // Lock
        vm.prank(address(vault));
        escrow.lockTokens{value: nativeAmount}(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        // Release
        vm.prank(address(vault));
        (address[] memory releasedTokens, uint256[] memory releasedAmounts, uint256 releasedNative) =
            escrow.releaseTokensForExecution(guid);

        assertEq(releasedTokens.length, 2);
        assertEq(releasedAmounts[0], amount1);
        assertEq(releasedAmounts[1], amount2);
        assertEq(releasedNative, nativeAmount);

        // Unlock with partial use
        uint256[] memory usedAmounts = new uint256[](2);
        usedAmounts[0] = amount1 / 2; // Use half of token1
        usedAmounts[1] = amount2;     // Use all of token2

        uint256 userToken1Before = token1.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);

        // User should receive excess token1
        uint256 userToken1After = token1.balanceOf(user);
        assertEq(userToken1After - userToken1Before, amount1 / 2);
    }

    /**
     * @notice Test MULTI_ASSETS_DEPOSIT refund returns all tokens + native
     */
    function test_multiAssets_RefundAll() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        uint256 nativeAmount = 1 ether;

        token1.mint(user, amount1);
        token2.mint(user, amount2);
        vm.deal(address(vault), nativeAmount); // Native goes to vault

        vm.startPrank(user);
        token1.approve(address(escrow), amount1);
        token2.approve(address(escrow), amount2);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        bytes memory actionCallData = abi.encode(tokens, amounts, user, 0, nativeAmount);
        bytes32 guid = keccak256("refund");

        vm.prank(address(vault));
        escrow.lockTokens{value: nativeAmount}(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, user);

        uint256 userToken1Before = token1.balanceOf(user);
        uint256 userToken2Before = token2.balanceOf(user);
        uint256 userNativeBefore = user.balance;

        vm.prank(address(vault));
        escrow.refundTokens(guid);

        assertEq(token1.balanceOf(user) - userToken1Before, amount1);
        assertEq(token2.balanceOf(user) - userToken2Before, amount2);
        assertEq(user.balance - userNativeBefore, nativeAmount);
    }

    // ============ REENTRANCY TESTS ============

    /**
     * @notice Test reentrancy protection on refundTokens via native transfer callback
     */
    function test_reentrancy_RefundTokensNativeCallback() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(escrow, vault, token1);

        // Setup: lock tokens for attacker
        uint256 amount = 100 ether;
        uint256 nativeAmount = 1 ether;

        token1.mint(address(attacker), amount);
        vm.deal(address(vault), nativeAmount);

        vm.prank(address(attacker));
        token1.approve(address(escrow), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        bytes memory actionCallData = abi.encode(tokens, amounts, address(attacker), 0, nativeAmount);
        bytes32 guid = keccak256("reentrancy");

        vm.prank(address(vault));
        escrow.lockTokens{value: nativeAmount}(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, address(attacker));

        // Setup attack
        attacker.setupAttack(guid, ReentrancyAttacker.AttackType.REFUND, 3);

        // Attempt refund - should not allow reentrancy
        vm.prank(address(vault));
        escrow.refundTokens(guid);

        // Verify only one refund happened
        assertEq(token1.balanceOf(address(attacker)), amount);
    }

    /**
     * @notice Test reentrancy protection on lockTokens via malicious token callback
     */
    function test_reentrancy_LockTokensMaliciousToken() public {
        MaliciousToken malToken = new MaliciousToken();

        // Enable malicious token in vault
        vault.enableAsset(address(malToken));

        ReentrancyAttacker attacker = new ReentrancyAttacker(escrow, vault, token1);
        malToken.setCallback(address(attacker));

        uint256 amount = 100 ether;
        malToken.mint(address(attacker), amount * 10); // Extra for potential reentrancy

        vm.prank(address(attacker));
        malToken.approve(address(escrow), amount * 10);

        address[] memory tokens = new address[](1);
        tokens[0] = address(malToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        bytes memory actionCallData = abi.encode(tokens, amounts, address(attacker), 0, uint256(0));
        bytes32 guid = keccak256("malicious");

        attacker.setupAttack(guid, ReentrancyAttacker.AttackType.LOCK, 3);

        // This should complete without allowing reentrancy
        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, actionCallData, 0, address(attacker));

        // Only original amount should be locked
        assertEq(malToken.balanceOf(address(escrow)), amount);
    }

    /**
     * @notice Test that double refund is prevented
     */
    function test_doubleRefund_Prevented() public {
        uint256 amount = 100 ether;
        token1.mint(user, amount);

        vm.prank(user);
        token1.approve(address(escrow), amount);

        bytes32 guid = keccak256("double");
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        // First refund succeeds
        vm.prank(address(vault));
        escrow.refundTokens(guid);

        // Second refund should be no-op (already refunded)
        uint256 balanceBefore = token1.balanceOf(user);
        vm.prank(address(vault));
        escrow.refundTokens(guid);
        uint256 balanceAfter = token1.balanceOf(user);

        // No additional tokens transferred
        assertEq(balanceAfter, balanceBefore);
    }

    /**
     * @notice Test that finalize then refund is prevented
     */
    function test_finalizeThenRefund_Prevented() public {
        uint256 amount = 100 ether;
        token1.mint(user, amount);

        vm.prank(user);
        token1.approve(address(escrow), amount);

        bytes32 guid = keccak256("finalize_then_refund");
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        // Release and finalize
        vm.prank(address(vault));
        escrow.releaseTokensForExecution(guid);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);

        // Refund should be no-op (already finalized)
        uint256 balanceBefore = token1.balanceOf(user);
        vm.prank(address(vault));
        escrow.refundTokens(guid);
        uint256 balanceAfter = token1.balanceOf(user);

        assertEq(balanceAfter, balanceBefore);
    }

    /**
     * @notice Test unauthorized vault cannot call escrow functions
     */
    function test_unauthorizedVault_Reverts() public {
        address fakeVault = makeAddr("fakeVault");

        bytes32 guid = keccak256("fake");
        bytes memory actionCallData = abi.encode(100 ether, user);

        vm.prank(fakeVault);
        vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);
    }

    // ============ INTEGRATION FLOW TESTS ============

    /**
     * @notice Test complete DEPOSIT flow: lock -> release -> execute -> unlock
     */
    function test_integration_DepositFlow() public {
        uint256 depositAmount = 500 ether;

        token1.mint(user, depositAmount);
        vm.prank(user);
        token1.approve(address(escrow), depositAmount);

        bytes32 guid = keccak256("deposit_flow");
        bytes memory actionCallData = abi.encode(depositAmount, user);

        // Step 1: Lock
        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        assertEq(token1.balanceOf(address(escrow)), depositAmount);
        assertEq(token1.balanceOf(user), 0);

        // Step 2: Release for execution
        vm.prank(address(vault));
        (address[] memory tokens, uint256[] memory amounts,) = escrow.releaseTokensForExecution(guid);

        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(token1));
        assertEq(amounts[0], depositAmount);

        // Vault should now have approval
        uint256 allowance = token1.allowance(address(escrow), address(vault));
        assertEq(allowance, depositAmount);

        // Step 3: Vault "executes" by pulling tokens
        vm.prank(address(vault));
        token1.transferFrom(address(escrow), address(vault), depositAmount);

        // Step 4: Unlock (all used)
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = depositAmount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);

        // No excess returned to user
        assertEq(token1.balanceOf(user), 0);
    }

    /**
     * @notice Test complete REDEEM flow: lock shares -> release -> burn -> unlock
     */
    function test_integration_RedeemFlow() public {
        uint256 shareAmount = 100 ether;

        // Mint shares to user
        vault.mint(user, shareAmount);

        vm.prank(user);
        vault.approve(address(escrow), shareAmount);

        bytes32 guid = keccak256("redeem_flow");
        bytes memory actionCallData = abi.encode(shareAmount, user, user);

        // Step 1: Lock shares
        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        assertEq(vault.balanceOf(address(escrow)), shareAmount);
        assertEq(escrow.lockedSharesPerUser(address(vault), user), shareAmount);

        // Step 2: Release
        vm.prank(address(vault));
        (address[] memory tokens, uint256[] memory amounts,) = escrow.releaseTokensForExecution(guid);

        assertEq(tokens[0], address(vault)); // Share token is vault itself

        // Step 3: Vault burns shares from escrow
        vm.prank(address(vault));
        vault.burn(address(escrow), shareAmount);

        // Step 4: Unlock
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = shareAmount;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);

        // Locked shares tracking updated
        assertEq(escrow.lockedSharesPerUser(address(vault), user), 0);
    }

    /**
     * @notice Test concurrent requests from same user
     */
    function test_integration_ConcurrentRequests() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;

        token1.mint(user, amount1 + amount2);
        vm.prank(user);
        token1.approve(address(escrow), amount1 + amount2);

        bytes32 guid1 = keccak256("concurrent1");
        bytes32 guid2 = keccak256("concurrent2");

        bytes memory actionCallData1 = abi.encode(amount1, user);
        bytes memory actionCallData2 = abi.encode(amount2, user);

        // Lock both
        vm.startPrank(address(vault));
        escrow.lockTokens(guid1, MoreVaultsLib.ActionType.DEPOSIT, actionCallData1, 0, user);
        escrow.lockTokens(guid2, MoreVaultsLib.ActionType.DEPOSIT, actionCallData2, 0, user);
        vm.stopPrank();

        assertEq(token1.balanceOf(address(escrow)), amount1 + amount2);

        // Refund one, finalize other
        vm.prank(address(vault));
        escrow.refundTokens(guid1);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(guid2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount2;

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid2, tokens, usedAmounts);

        // User got refund from guid1
        assertEq(token1.balanceOf(user), amount1);
    }
}
