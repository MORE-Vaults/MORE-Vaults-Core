// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MoreVaultsEscrow} from "../../../src/cross-chain/MoreVaultsEscrow.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";

/**
 * @title MockVaultForInvariant
 * @notice Mock vault for invariant testing
 */
contract MockVaultForInvariant is MockERC20, IERC4626 {
    address public assetToken;
    mapping(address => bool) public depositableAssets;

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

    // IERC4626 stub functions
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
 * @title MockFactoryForInvariant
 * @notice Mock factory for invariant testing
 */
contract MockFactoryForInvariant {
    mapping(address => bool) public isFactoryVault;

    function setIsFactoryVault(address vault, bool value) external {
        isFactoryVault[vault] = value;
    }
}

/**
 * @title EscrowInvariantHandler
 * @notice Handler for invariant testing - fuzzer calls this to interact with escrow
 */
contract EscrowInvariantHandler is Test {
    MoreVaultsEscrow public escrow;
    MockERC20 public token;
    MockVaultForInvariant public vault;

    // Ghost variables for tracking state
    uint256 public ghost_totalLocked;
    uint256 public ghost_totalRefunded;
    uint256 public ghost_totalUnlocked;
    uint256 public ghost_lockCalls;
    uint256 public ghost_refundCalls;
    uint256 public ghost_unlockCalls;
    uint256 public ghost_releaseCalls;

    bytes32[] public activeGuids;
    mapping(bytes32 => uint256) public lockedPerGuid;
    mapping(bytes32 => bool) public isFinalized;
    mapping(bytes32 => bool) public isRefunded;
    mapping(bytes32 => bool) public isReleased;

    uint256 private guidCounter;

    constructor(MoreVaultsEscrow _escrow, MockERC20 _token, MockVaultForInvariant _vault) {
        escrow = _escrow;
        token = _token;
        vault = _vault;
    }

    /**
     * @notice Lock tokens for a DEPOSIT action
     */
    function lockDeposit(uint256 amount, address user) external {
        amount = bound(amount, 1, 1000 ether);
        vm.assume(user != address(0) && user != address(escrow) && user != address(vault));

        // Mint and approve
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);

        bytes32 guid = keccak256(abi.encodePacked(guidCounter++, user, amount, block.timestamp));
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        try escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user) {
            ghost_totalLocked += amount;
            ghost_lockCalls++;
            lockedPerGuid[guid] = amount;
            activeGuids.push(guid);
        } catch {}
    }

    /**
     * @notice Release tokens for execution
     */
    function releaseForExecution(uint256 guidIndex) external {
        if (activeGuids.length == 0) return;
        guidIndex = bound(guidIndex, 0, activeGuids.length - 1);
        bytes32 guid = activeGuids[guidIndex];

        if (isFinalized[guid] || isRefunded[guid] || isReleased[guid]) return;

        vm.prank(address(vault));
        try escrow.releaseTokensForExecution(guid) {
            isReleased[guid] = true;
            ghost_releaseCalls++;
        } catch {}
    }

    /**
     * @notice Unlock tokens after execution
     */
    function unlockAfterExecution(uint256 guidIndex, uint256 usedPercent) external {
        if (activeGuids.length == 0) return;
        guidIndex = bound(guidIndex, 0, activeGuids.length - 1);
        usedPercent = bound(usedPercent, 0, 100);
        bytes32 guid = activeGuids[guidIndex];

        if (isFinalized[guid] || isRefunded[guid] || !isReleased[guid]) return;

        uint256 locked = lockedPerGuid[guid];
        uint256 used = (locked * usedPercent) / 100;

        (address[] memory tokens,,) = escrow.getEscrowInfo(address(vault), guid);
        if (tokens.length == 0) return;

        uint256[] memory usedAmounts = new uint256[](tokens.length);
        usedAmounts[0] = used;

        vm.prank(address(vault));
        try escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts) {
            isFinalized[guid] = true;
            ghost_totalUnlocked += (locked - used);
            ghost_unlockCalls++;
        } catch {}
    }

    /**
     * @notice Refund tokens
     */
    function refundTokens(uint256 guidIndex) external {
        if (activeGuids.length == 0) return;
        guidIndex = bound(guidIndex, 0, activeGuids.length - 1);
        bytes32 guid = activeGuids[guidIndex];

        if (isFinalized[guid] || isRefunded[guid]) return;

        vm.prank(address(vault));
        try escrow.refundTokens(guid) {
            isRefunded[guid] = true;
            ghost_totalRefunded += lockedPerGuid[guid];
            ghost_refundCalls++;
        } catch {}
    }

    /**
     * @notice Try unauthorized access (should always fail)
     */
    function tryUnauthorizedLock(address attacker, uint256 amount) external {
        vm.assume(attacker != address(vault) && attacker != address(0));
        amount = bound(amount, 1, 100 ether);

        bytes32 guid = keccak256(abi.encodePacked("attack", attacker, amount));
        bytes memory actionCallData = abi.encode(amount, attacker);

        vm.prank(attacker);
        try escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, attacker) {
            revert("CRITICAL: Unauthorized lock succeeded!");
        } catch {}
    }

    function getActiveGuidsLength() external view returns (uint256) {
        return activeGuids.length;
    }
}

/**
 * @title MoreVaultsEscrowInvariantTest
 * @notice Invariant tests for MoreVaultsEscrow
 */
contract MoreVaultsEscrowInvariantTest is StdInvariant, Test {
    MoreVaultsEscrow public escrow;
    MockFactoryForInvariant public factory;
    MockVaultForInvariant public vault;
    MockERC20 public token;
    EscrowInvariantHandler public handler;

    function setUp() public {
        // Deploy mocks
        token = new MockERC20("Test Token", "TT");
        factory = new MockFactoryForInvariant();
        vault = new MockVaultForInvariant(address(token));

        // Register vault
        factory.setIsFactoryVault(address(vault), true);

        // Deploy escrow
        escrow = new MoreVaultsEscrow(address(factory));

        // Deploy handler
        handler = new EscrowInvariantHandler(escrow, token, vault);

        // Target handler
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.lockDeposit.selector;
        selectors[1] = handler.releaseForExecution.selector;
        selectors[2] = handler.unlockAfterExecution.selector;
        selectors[3] = handler.refundTokens.selector;
        selectors[4] = handler.tryUnauthorizedLock.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /**
     * @notice INVARIANT: Factory address is immutable
     */
    function invariant_factoryImmutable() public view {
        assertEq(escrow.vaultsFactory(), address(factory), "Factory changed!");
    }

    /**
     * @notice INVARIANT: Escrow balance >= locked - refunded - unlocked
     */
    function invariant_balanceConsistency() public view {
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 expectedMin = handler.ghost_totalLocked() - handler.ghost_totalRefunded() - handler.ghost_totalUnlocked();

        assertGe(escrowBalance, expectedMin, "Escrow balance inconsistent with tracking");
    }

    /**
     * @notice INVARIANT: Cannot have both finalized and refunded
     */
    function invariant_mutualExclusiveStates() public view {
        uint256 len = handler.getActiveGuidsLength();
        for (uint256 i = 0; i < len && i < 10; i++) {
            bytes32 guid = handler.activeGuids(i);
            bool finalized = handler.isFinalized(guid);
            bool refunded = handler.isRefunded(guid);

            assertFalse(finalized && refunded, "Request is both finalized and refunded!");
        }
    }

    /**
     * @notice Log stats after run
     */
    function invariant_logStats() public view {
        console.log("=== Escrow Invariant Stats ===");
        console.log("Lock calls:", handler.ghost_lockCalls());
        console.log("Release calls:", handler.ghost_releaseCalls());
        console.log("Unlock calls:", handler.ghost_unlockCalls());
        console.log("Refund calls:", handler.ghost_refundCalls());
        console.log("Total locked:", handler.ghost_totalLocked());
        console.log("Total refunded:", handler.ghost_totalRefunded());
        console.log("Total unlocked:", handler.ghost_totalUnlocked());
        console.log("Escrow balance:", token.balanceOf(address(escrow)));
    }
}

/**
 * @title MoreVaultsEscrowFuzzTest
 * @notice Fuzz tests for MoreVaultsEscrow critical functions
 */
contract MoreVaultsEscrowFuzzTest is Test {
    MoreVaultsEscrow public escrow;
    MockFactoryForInvariant public factory;
    MockVaultForInvariant public vault;
    MockERC20 public token;

    address public user = makeAddr("user");

    function setUp() public {
        token = new MockERC20("Test Token", "TT");
        factory = new MockFactoryForInvariant();
        vault = new MockVaultForInvariant(address(token));
        factory.setIsFactoryVault(address(vault), true);
        escrow = new MoreVaultsEscrow(address(factory));
    }

    /**
     * @notice Fuzz test: lockTokens DEPOSIT with random amounts
     */
    function testFuzz_lockTokens_DEPOSIT(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);

        bytes32 guid = keccak256(abi.encodePacked(amount, user));
        bytes memory actionCallData = abi.encode(amount, user);

        uint256 escrowBalanceBefore = token.balanceOf(address(escrow));

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        uint256 escrowBalanceAfter = token.balanceOf(address(escrow));
        assertEq(escrowBalanceAfter - escrowBalanceBefore, amount, "Wrong amount locked");
    }

    /**
     * @notice Fuzz test: lockTokens REDEEM with random shares
     */
    function testFuzz_lockTokens_REDEEM(uint256 shares) public {
        shares = bound(shares, 1, 1e30);

        // Mint vault shares to user
        vault.mint(user, shares);
        vm.prank(user);
        vault.approve(address(escrow), shares);

        bytes32 guid = keccak256(abi.encodePacked(shares, user, "redeem"));
        bytes memory actionCallData = abi.encode(shares, user, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, user);

        assertEq(escrow.lockedSharesPerUser(address(vault), user), shares, "Wrong shares locked");
    }

    /**
     * @notice Fuzz test: unlockTokensAfterExecution with various used amounts
     */
    function testFuzz_unlockTokensAfterExecution(uint256 locked, uint256 usedPercent) public {
        locked = bound(locked, 1, 1e24);
        usedPercent = bound(usedPercent, 0, 100);
        uint256 used = (locked * usedPercent) / 100;

        // Setup: lock tokens
        token.mint(user, locked);
        vm.prank(user);
        token.approve(address(escrow), locked);

        bytes32 guid = keccak256(abi.encodePacked(locked, user, usedPercent));
        bytes memory actionCallData = abi.encode(locked, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        // Release
        vm.prank(address(vault));
        escrow.releaseTokensForExecution(guid);

        // Unlock with fuzzed used amount
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = used;

        uint256 userBalanceBefore = token.balanceOf(user);

        vm.prank(address(vault));
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);

        uint256 userBalanceAfter = token.balanceOf(user);
        uint256 excess = locked - used;

        assertEq(userBalanceAfter - userBalanceBefore, excess, "Wrong excess returned");
    }

    /**
     * @notice Fuzz test: refundTokens returns full amount
     */
    function testFuzz_refundTokens(uint256 amount) public {
        amount = bound(amount, 1, 1e24);

        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);

        bytes32 guid = keccak256(abi.encodePacked(amount, user, "refund"));
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        uint256 userBalanceBefore = token.balanceOf(user);

        vm.prank(address(vault));
        escrow.refundTokens(guid);

        uint256 userBalanceAfter = token.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, amount, "Wrong refund amount");
    }

    /**
     * @notice Fuzz test: TokensMismatch validation (tests the fix we added)
     */
    function testFuzz_unlockTokensAfterExecution_TokensMismatch(uint256 amount) public {
        amount = bound(amount, 1, 1e24);

        // Setup
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);

        bytes32 guid = keccak256(abi.encodePacked(amount, user, "mismatch"));
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(guid);

        // Try to unlock with wrong token array
        MockERC20 wrongToken = new MockERC20("Wrong", "W");
        address[] memory wrongTokens = new address[](1);
        wrongTokens[0] = address(wrongToken);
        uint256[] memory usedAmounts = new uint256[](1);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.TokensMismatch.selector);
        escrow.unlockTokensAfterExecution(guid, wrongTokens, usedAmounts);
    }

    /**
     * @notice Fuzz test: Cannot unlock with wrong array length
     */
    function testFuzz_unlockTokensAfterExecution_ArrayLengthMismatch(uint256 amount, uint8 extraElements) public {
        amount = bound(amount, 1, 1e24);
        extraElements = uint8(bound(extraElements, 1, 5));

        // Setup
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);

        bytes32 guid = keccak256(abi.encodePacked(amount, user, "length"));
        bytes memory actionCallData = abi.encode(amount, user);

        vm.prank(address(vault));
        escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

        vm.prank(address(vault));
        escrow.releaseTokensForExecution(guid);

        // Try with wrong length arrays
        address[] memory tokens = new address[](1 + extraElements);
        tokens[0] = address(token);
        for (uint8 i = 1; i <= extraElements; i++) {
            tokens[i] = address(uint160(i));
        }

        uint256[] memory usedAmounts = new uint256[](1 + extraElements);
        usedAmounts[0] = amount;

        vm.prank(address(vault));
        vm.expectRevert(MoreVaultsEscrow.ArraysLengthMismatch.selector);
        escrow.unlockTokensAfterExecution(guid, tokens, usedAmounts);
    }
}
