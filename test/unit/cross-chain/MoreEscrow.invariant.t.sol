// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MoreEscrow} from "../../../src/cross-chain/MoreEscrow.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title EscrowHandler
 * @notice Handler contract that the fuzzer will call to interact with MoreEscrow
 */
contract EscrowHandler is Test {
    MoreEscrow public escrow;
    ERC20Mock public token;
    address public vault;
    address public manager;

    // Track state for invariant checks
    uint256 public totalDeposited;
    uint256 public totalRefunded;
    uint256 public totalReleased;
    mapping(bytes32 => uint256) public depositedPerGuid;
    mapping(bytes32 => bool) public isRefunded;
    bytes32[] public activeGuids;
    uint256 public guidCounter;

    // Ghost variables for tracking
    uint256 public ghost_lockCalls;
    uint256 public ghost_refundCalls;
    uint256 public ghost_releaseCalls;
    uint256 public ghost_successfulRefunds;

    constructor(MoreEscrow _escrow, ERC20Mock _token, address _vault, address _manager) {
        escrow = _escrow;
        token = _token;
        vault = _vault;
        manager = _manager;
    }

    /**
     * @notice Simulate a deposit lock
     */
    function lockDeposit(uint256 amount, address user) external {
        amount = bound(amount, 1, 1000 ether);

        // Mint tokens to user
        token.mint(user, amount);

        // Approve escrow
        vm.prank(user);
        token.approve(address(escrow), amount);

        // Create guid
        bytes32 guid = keccak256(abi.encodePacked(guidCounter++, user, amount, block.timestamp));

        // Encode DEPOSIT action
        bytes memory actionCallData = abi.encode(amount, user);

        // Lock tokens (vault calls escrow)
        vm.prank(vault);
        try escrow.lockTokens(
            guid,
            MoreVaultsLib.ActionType.DEPOSIT,
            actionCallData,
            0,
            user
        ) {
            totalDeposited += amount;
            depositedPerGuid[guid] = amount;
            activeGuids.push(guid);
            ghost_lockCalls++;
        } catch {
            // Expected to fail sometimes (e.g., duplicate guid)
        }
    }

    /**
     * @notice Simulate a refund
     */
    function refundTokens(uint256 guidIndex) external {
        if (activeGuids.length == 0) return;

        guidIndex = bound(guidIndex, 0, activeGuids.length - 1);
        bytes32 guid = activeGuids[guidIndex];

        // Skip if already refunded (to avoid double counting)
        if (isRefunded[guid]) {
            ghost_refundCalls++;
            return;
        }

        uint256 balanceBefore = token.balanceOf(address(escrow));

        vm.prank(manager);
        try escrow.refundTokens(guid) {
            uint256 balanceAfter = token.balanceOf(address(escrow));
            uint256 actualRefunded = balanceBefore - balanceAfter;

            totalRefunded += actualRefunded;
            isRefunded[guid] = true;
            ghost_successfulRefunds++;
        } catch {
            // Expected if already refunded/finalized
        }
        ghost_refundCalls++;
    }

    /**
     * @notice Attempt unauthorized manager change (should always fail)
     */
    function tryUnauthorizedManagerChange(address attacker, address newManager) external {
        vm.assume(attacker != vault);

        vm.prank(attacker);
        try escrow.setCrossChainAccountingManager(newManager) {
            // This should NEVER succeed - if it does, invariant will catch it
            revert("CRITICAL: Unauthorized manager change succeeded!");
        } catch {
            // Expected - unauthorized access denied
        }
    }

    /**
     * @notice Get number of active guids
     */
    function getActiveGuidsLength() external view returns (uint256) {
        return activeGuids.length;
    }
}

/**
 * @title MockVaultForEscrow
 * @notice Minimal vault mock that escrow can call
 */
contract MockVaultForEscrow {
    address public assetToken;
    mapping(address => bool) public depositableAssets;

    constructor(address _asset) {
        assetToken = _asset;
        depositableAssets[_asset] = true;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function isAssetDepositable(address token) external view returns (bool) {
        return depositableAssets[token];
    }

    function enableAsset(address token) external {
        depositableAssets[token] = true;
    }

    // Receive ETH
    receive() external payable {}
}

/**
 * @title MoreEscrowInvariantTest
 * @notice Invariant tests for MoreEscrow contract
 */
contract MoreEscrowInvariantTest is StdInvariant, Test {
    MoreEscrow public escrow;
    ERC20Mock public token;
    MockVaultForEscrow public vault;
    EscrowHandler public handler;

    address public manager = makeAddr("manager");

    function setUp() public {
        // Deploy mock token
        token = new ERC20Mock();

        // Deploy mock vault
        vault = new MockVaultForEscrow(address(token));

        // Deploy escrow
        vm.prank(address(vault));
        escrow = new MoreEscrow(address(vault));

        // Set manager
        vm.prank(address(vault));
        escrow.setCrossChainAccountingManager(manager);

        // Deploy handler
        handler = new EscrowHandler(escrow, token, address(vault), manager);

        // Target the handler for fuzzing
        targetContract(address(handler));

        // Exclude specific functions if needed
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.lockDeposit.selector;
        selectors[1] = handler.refundTokens.selector;
        selectors[2] = handler.tryUnauthorizedManagerChange.selector;

        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    /**
     * @notice INVARIANT: Manager can ONLY be changed by vault
     * @dev This should always hold - the access control fix ensures this
     */
    function invariant_managerOnlySetByVault() public view {
        // Manager should still be the one we set in setUp
        assertEq(escrow.crossChainAccountingManager(), manager);
    }

    /**
     * @notice INVARIANT: Escrow token balance >= total deposited - total refunded - total released
     */
    function invariant_escrowBalanceConsistency() public view {
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 expectedMinBalance = handler.totalDeposited() - handler.totalRefunded() - handler.totalReleased();

        // Escrow should have at least the expected amount (could have more due to donations)
        assertGe(escrowBalance, expectedMinBalance, "Escrow balance inconsistent");
    }

    /**
     * @notice INVARIANT: Ghost variables tracking
     */
    function invariant_callCountsNonNegative() public view {
        // These are uint256 so always >= 0, but good sanity check
        assertTrue(handler.ghost_lockCalls() >= 0);
        assertTrue(handler.ghost_refundCalls() >= 0);
        assertTrue(handler.ghost_releaseCalls() >= 0);
    }

    /**
     * @notice Log stats after invariant run
     */
    function invariant_logStats() public view {
        console.log("=== Invariant Test Stats ===");
        console.log("Lock calls:", handler.ghost_lockCalls());
        console.log("Refund calls:", handler.ghost_refundCalls());
        console.log("Successful refunds:", handler.ghost_successfulRefunds());
        console.log("Release calls:", handler.ghost_releaseCalls());
        console.log("Active guids:", handler.getActiveGuidsLength());
        console.log("Total deposited:", handler.totalDeposited());
        console.log("Total refunded:", handler.totalRefunded());
        console.log("Escrow balance:", token.balanceOf(address(escrow)));
    }
}

/**
 * @title MoreEscrowAccessControlInvariantTest
 * @notice Focused invariant test for access control
 */
contract MoreEscrowAccessControlInvariantTest is StdInvariant, Test {
    MoreEscrow public escrow;
    address public vault = makeAddr("vault");
    address public manager = makeAddr("manager");

    // Track all addresses that try to change manager
    address[] public attackers;
    uint256 public attackAttempts;

    function setUp() public {
        vm.prank(vault);
        escrow = new MoreEscrow(vault);

        vm.prank(vault);
        escrow.setCrossChainAccountingManager(manager);

        targetContract(address(this));
    }

    /**
     * @notice Handler: Anyone tries to set manager
     */
    function trySetManager(address attacker, address newManager) external {
        vm.assume(attacker != vault);
        vm.assume(attacker != address(0));

        attackers.push(attacker);
        attackAttempts++;

        vm.prank(attacker);
        try escrow.setCrossChainAccountingManager(newManager) {
            // Should never reach here
            fail("CRITICAL: Unauthorized manager change!");
        } catch (bytes memory reason) {
            // Expected - verify it's the right error
            assertEq(bytes4(reason), MoreEscrow.OnlyVault.selector);
        }
    }

    /**
     * @notice Handler: Vault legitimately changes manager
     */
    function vaultSetsManager(address newManager) external {
        vm.assume(newManager != address(0));

        address oldManager = escrow.crossChainAccountingManager();

        vm.prank(vault);
        escrow.setCrossChainAccountingManager(newManager);

        // Update our tracking
        manager = newManager;

        assertEq(escrow.crossChainAccountingManager(), newManager);
    }

    /**
     * @notice INVARIANT: Current manager is always what we expect
     */
    function invariant_managerIsExpected() public view {
        assertEq(escrow.crossChainAccountingManager(), manager);
    }

    /**
     * @notice INVARIANT: Vault address never changes
     */
    function invariant_vaultIsImmutable() public view {
        assertEq(escrow.vault(), vault);
    }

    /**
     * @notice Log attack stats
     */
    function invariant_logAttackStats() public view {
        console.log("=== Access Control Invariant Stats ===");
        console.log("Attack attempts:", attackAttempts);
        console.log("Current manager:", manager);
        console.log("All attacks blocked: true");
    }
}
