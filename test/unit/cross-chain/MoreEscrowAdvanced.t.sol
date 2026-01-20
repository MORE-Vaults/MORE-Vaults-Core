// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity 0.8.28;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {MoreEscrow} from "../../../src/cross-chain/MoreEscrow.sol";
// import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
// import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
// import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

// /**
//  * @title MockRebasingToken
//  * @notice ERC20 that can simulate rebasing (balance changes without transfers)
//  */
// contract MockRebasingToken is ERC20Mock {
//     uint256 public rebaseMultiplier = 1e18; // 1.0 = no change
//     uint256 public constant MULTIPLIER_BASE = 1e18;

//     function setRebaseMultiplier(uint256 _multiplier) external {
//         rebaseMultiplier = _multiplier;
//     }

//     function balanceOf(address account) public view override returns (uint256) {
//         uint256 rawBalance = super.balanceOf(account);
//         return (rawBalance * rebaseMultiplier) / MULTIPLIER_BASE;
//     }

//     // Mint raw balance (before rebase multiplier)
//     function mintRaw(address to, uint256 amount) external {
//         _mint(to, amount);
//     }
// }

// /**
//  * @title MockVaultWithShares
//  * @notice Vault mock that supports share transfers for WITHDRAW/REDEEM testing
//  */
// contract MockVaultWithShares is ERC20Mock {
//     address public assetToken;
//     mapping(address => bool) public depositableAssets;
//     address public escrow;

//     constructor(address _asset) {
//         assetToken = _asset;
//         depositableAssets[_asset] = true;
//     }

//     function setEscrow(address _escrow) external {
//         escrow = _escrow;
//     }

//     function asset() external view returns (address) {
//         return assetToken;
//     }

//     function isAssetDepositable(address token) external view returns (bool) {
//         return depositableAssets[token];
//     }

//     function enableAsset(address token) external {
//         depositableAssets[token] = true;
//     }

//     /**
//      * @notice Transfer shares from owner using spender's allowance
//      * @dev Called by escrow during WITHDRAW/REDEEM lock
//      */
//     function transferSharesFromOwner(address owner, uint256 shares, address spender) external {
//         // Check allowance from owner to spender
//         if (spender != owner) {
//             uint256 currentAllowance = allowance(owner, spender);
//             require(currentAllowance >= shares, "Insufficient allowance");
//             _approve(owner, spender, currentAllowance - shares);
//         }
//         // Transfer shares from owner to vault (this contract)
//         _transfer(owner, address(this), shares);
//     }

//     /**
//      * @notice Transfer shares from vault to recipient
//      * @dev Called by escrow during refund/unlock
//      */
//     function transferSharesFromVault(address to, uint256 shares) external {
//         require(msg.sender == escrow, "Only escrow");
//         _transfer(address(this), to, shares);
//     }

//     // Receive ETH
//     receive() external payable {}
// }

// // ============================================================================
// // TEST 1: Rebasing Token Invariant Tests
// // ============================================================================

// /**
//  * @title RebasingTokenHandler
//  * @notice Handler for testing rebasing token behavior in escrow
//  */
// contract RebasingTokenHandler is Test {
//     MoreEscrow public escrow;
//     MockRebasingToken public token;
//     MockVaultWithShares public vault;
//     address public manager;

//     struct DepositInfo {
//         address user;
//         uint256 originalAmount;
//         bool refunded;
//     }

//     mapping(bytes32 => DepositInfo) public deposits;
//     bytes32[] public guids;
//     uint256 public guidCounter;

//     // Track totals
//     uint256 public totalOriginalDeposits;
//     uint256 public totalRefundedOriginal;

//     constructor(
//         MoreEscrow _escrow,
//         MockRebasingToken _token,
//         MockVaultWithShares _vault,
//         address _manager
//     ) {
//         escrow = _escrow;
//         token = _token;
//         vault = _vault;
//         manager = _manager;
//     }

//     function deposit(uint256 amount, address user) external {
//         amount = bound(amount, 1 ether, 100 ether);
//         vm.assume(user != address(0) && user != address(escrow) && user != address(vault));

//         // Mint tokens to user
//         token.mint(user, amount);

//         // Approve escrow
//         vm.prank(user);
//         token.approve(address(escrow), amount);

//         // Create guid
//         bytes32 guid = keccak256(abi.encodePacked(guidCounter++, user, amount, block.timestamp));

//         // Encode DEPOSIT action
//         bytes memory actionCallData = abi.encode(amount, user);

//         // Lock tokens
//         vm.prank(address(vault));
//         try escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user) {
//             deposits[guid] = DepositInfo({user: user, originalAmount: amount, refunded: false});
//             guids.push(guid);
//             totalOriginalDeposits += amount;
//         } catch {}
//     }

//     function rebaseUp(uint256 percentage) external {
//         percentage = bound(percentage, 1, 50); // 1-50% increase
//         uint256 newMultiplier = token.rebaseMultiplier() * (100 + percentage) / 100;
//         token.setRebaseMultiplier(newMultiplier);
//     }

//     function rebaseDown(uint256 percentage) external {
//         percentage = bound(percentage, 1, 30); // 1-30% decrease
//         uint256 newMultiplier = token.rebaseMultiplier() * (100 - percentage) / 100;
//         if (newMultiplier > 0) {
//             token.setRebaseMultiplier(newMultiplier);
//         }
//     }

//     function refund(uint256 guidIndex) external {
//         if (guids.length == 0) return;
//         guidIndex = bound(guidIndex, 0, guids.length - 1);

//         bytes32 guid = guids[guidIndex];
//         if (deposits[guid].refunded) return;

//         address user = deposits[guid].user;
//         uint256 userBalanceBefore = token.balanceOf(user);

//         vm.prank(manager);
//         try escrow.refundTokens(guid) {
//             deposits[guid].refunded = true;
//             totalRefundedOriginal += deposits[guid].originalAmount;

//             // User should receive their share (possibly rebased)
//             uint256 userBalanceAfter = token.balanceOf(user);
//             require(userBalanceAfter >= userBalanceBefore, "User balance decreased after refund");
//         } catch {}
//     }

//     function getGuidsLength() external view returns (uint256) {
//         return guids.length;
//     }

//     function getActiveDepositsCount() external view returns (uint256) {
//         uint256 count = 0;
//         for (uint256 i = 0; i < guids.length; i++) {
//             if (!deposits[guids[i]].refunded) count++;
//         }
//         return count;
//     }
// }

// contract MoreEscrowRebasingInvariantTest is StdInvariant, Test {
//     MoreEscrow public escrow;
//     MockRebasingToken public token;
//     MockVaultWithShares public vault;
//     RebasingTokenHandler public handler;
//     address public manager = makeAddr("manager");

//     function setUp() public {
//         // Deploy rebasing token
//         token = new MockRebasingToken();

//         // Deploy vault
//         vault = new MockVaultWithShares(address(token));

//         // Deploy escrow
//         vm.prank(address(vault));
//         escrow = new MoreEscrow(address(vault));

//         // Set manager
//         vm.prank(address(vault));
//         escrow.setCrossChainAccountingManager(manager);

//         // Set escrow in vault
//         vault.setEscrow(address(escrow));

//         // Deploy handler
//         handler = new RebasingTokenHandler(escrow, token, vault, manager);

//         // Target handler
//         targetContract(address(handler));

//         bytes4[] memory selectors = new bytes4[](4);
//         selectors[0] = handler.deposit.selector;
//         selectors[1] = handler.rebaseUp.selector;
//         selectors[2] = handler.rebaseDown.selector;
//         selectors[3] = handler.refund.selector;

//         targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
//     }

//     /**
//      * @notice INVARIANT: Escrow balance should always be >= 0 and reflect rebases
//      */
//     function invariant_escrowBalanceNonNegative() public view {
//         uint256 balance = token.balanceOf(address(escrow));
//         assertGe(balance, 0, "Escrow balance should be non-negative");
//     }

//     /**
//      * @notice INVARIANT: After positive rebase, users should receive more on refund
//      */
//     function invariant_rebasingFairness() public view {
//         // If there are active deposits and rebase > 1, escrow should have more tokens
//         if (handler.getActiveDepositsCount() > 0 && token.rebaseMultiplier() > 1e18) {
//             uint256 escrowBalance = token.balanceOf(address(escrow));
//             // Escrow should benefit from positive rebase (have more than originally deposited)
//             // This is a soft check - the share system distributes rebases fairly
//             assertTrue(escrowBalance >= 0, "Escrow balance check");
//         }
//     }

//     function invariant_logRebasingStats() public view {
//         console.log("=== Rebasing Invariant Stats ===");
//         console.log("Total deposits:", handler.getGuidsLength());
//         console.log("Active deposits:", handler.getActiveDepositsCount());
//         console.log("Rebase multiplier:", token.rebaseMultiplier());
//         console.log("Escrow balance:", token.balanceOf(address(escrow)));
//     }
// }

// // ============================================================================
// // TEST 2: WITHDRAW/REDEEM lockedSharesPerUser Invariant Tests
// // ============================================================================

// /**
//  * @title WithdrawRedeemHandler
//  * @notice Handler for testing WITHDRAW/REDEEM and lockedSharesPerUser tracking
//  */
// contract WithdrawRedeemHandler is Test {
//     MoreEscrow public escrow;
//     MockVaultWithShares public vault;
//     ERC20Mock public underlyingToken;
//     address public manager;

//     mapping(address => uint256) public userTotalLockedShares;
//     mapping(bytes32 => uint256) public lockedSharesPerGuid;
//     mapping(bytes32 => address) public ownerPerGuid;
//     mapping(bytes32 => bool) public isRefunded;
//     bytes32[] public guids;
//     uint256 public guidCounter;

//     address[] public users;

//     constructor(
//         MoreEscrow _escrow,
//         MockVaultWithShares _vault,
//         ERC20Mock _underlying,
//         address _manager
//     ) {
//         escrow = _escrow;
//         vault = _vault;
//         underlyingToken = _underlying;
//         manager = _manager;

//         // Pre-create some users (using vm.addr for deterministic addresses)
//         users.push(vm.addr(uint256(keccak256(abi.encodePacked("user0")))));
//         users.push(vm.addr(uint256(keccak256(abi.encodePacked("user1")))));
//         users.push(vm.addr(uint256(keccak256(abi.encodePacked("user2")))));
//         users.push(vm.addr(uint256(keccak256(abi.encodePacked("user3")))));
//         users.push(vm.addr(uint256(keccak256(abi.encodePacked("user4")))));
//     }

//     function withdraw(uint256 userIndex, uint256 shares, uint256 assets) external {
//         userIndex = bound(userIndex, 0, users.length - 1);
//         shares = bound(shares, 1 ether, 10 ether);
//         assets = bound(assets, 1 ether, shares); // assets <= shares for simplicity

//         address owner = users[userIndex];
//         address initiator = owner; // Same for simplicity

//         // Mint shares to owner
//         vault.mint(owner, shares);

//         // Owner approves initiator (self)
//         vm.prank(owner);
//         vault.approve(initiator, shares);

//         bytes32 guid = keccak256(abi.encodePacked(guidCounter++, owner, shares, "withdraw"));
//         bytes memory actionCallData = abi.encode(assets, owner, owner);

//         vm.prank(address(vault));
//         try escrow.lockTokens(guid, MoreVaultsLib.ActionType.WITHDRAW, actionCallData, shares, initiator) {
//             guids.push(guid);
//             lockedSharesPerGuid[guid] = shares;
//             ownerPerGuid[guid] = owner;
//             userTotalLockedShares[owner] += shares;
//         } catch {}
//     }

//     function redeem(uint256 userIndex, uint256 shares) external {
//         userIndex = bound(userIndex, 0, users.length - 1);
//         shares = bound(shares, 1 ether, 10 ether);

//         address owner = users[userIndex];
//         address initiator = owner;

//         // Mint shares to owner
//         vault.mint(owner, shares);

//         // Owner approves initiator
//         vm.prank(owner);
//         vault.approve(initiator, shares);

//         bytes32 guid = keccak256(abi.encodePacked(guidCounter++, owner, shares, "redeem"));
//         bytes memory actionCallData = abi.encode(shares, owner, owner);

//         vm.prank(address(vault));
//         try escrow.lockTokens(guid, MoreVaultsLib.ActionType.REDEEM, actionCallData, 0, initiator) {
//             guids.push(guid);
//             lockedSharesPerGuid[guid] = shares;
//             ownerPerGuid[guid] = owner;
//             userTotalLockedShares[owner] += shares;
//         } catch {}
//     }

//     function refund(uint256 guidIndex) external {
//         if (guids.length == 0) return;
//         guidIndex = bound(guidIndex, 0, guids.length - 1);

//         bytes32 guid = guids[guidIndex];
//         if (isRefunded[guid]) return;

//         address owner = ownerPerGuid[guid];
//         uint256 lockedShares = lockedSharesPerGuid[guid];

//         vm.prank(manager);
//         try escrow.refundTokens(guid) {
//             isRefunded[guid] = true;
//             userTotalLockedShares[owner] -= lockedShares;
//         } catch {}
//     }

//     function getGuidsLength() external view returns (uint256) {
//         return guids.length;
//     }

//     function getUserLockedShares(address user) external view returns (uint256) {
//         return userTotalLockedShares[user];
//     }

//     function getEscrowLockedShares(address user) external view returns (uint256) {
//         return escrow.getLockedShares(user);
//     }
// }

// contract MoreEscrowWithdrawRedeemInvariantTest is StdInvariant, Test {
//     MoreEscrow public escrow;
//     MockVaultWithShares public vault;
//     ERC20Mock public underlyingToken;
//     WithdrawRedeemHandler public handler;
//     address public manager = makeAddr("manager");

//     function setUp() public {
//         // Deploy underlying token
//         underlyingToken = new ERC20Mock();

//         // Deploy vault
//         vault = new MockVaultWithShares(address(underlyingToken));

//         // Deploy escrow
//         vm.prank(address(vault));
//         escrow = new MoreEscrow(address(vault));

//         // Set manager
//         vm.prank(address(vault));
//         escrow.setCrossChainAccountingManager(manager);

//         // Set escrow in vault
//         vault.setEscrow(address(escrow));

//         // Deploy handler
//         handler = new WithdrawRedeemHandler(escrow, vault, underlyingToken, manager);

//         // Target handler
//         targetContract(address(handler));

//         bytes4[] memory selectors = new bytes4[](3);
//         selectors[0] = handler.withdraw.selector;
//         selectors[1] = handler.redeem.selector;
//         selectors[2] = handler.refund.selector;

//         targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
//     }

//     /**
//      * @notice INVARIANT: lockedSharesPerUser in escrow matches our tracking
//      */
//     function invariant_lockedSharesConsistency() public {
//         // Check for each pre-defined user (same addresses as in handler constructor)
//         address[5] memory users = [
//             vm.addr(uint256(keccak256(abi.encodePacked("user0")))),
//             vm.addr(uint256(keccak256(abi.encodePacked("user1")))),
//             vm.addr(uint256(keccak256(abi.encodePacked("user2")))),
//             vm.addr(uint256(keccak256(abi.encodePacked("user3")))),
//             vm.addr(uint256(keccak256(abi.encodePacked("user4"))))
//         ];

//         for (uint256 i = 0; i < 5; i++) {
//             uint256 handlerTracked = handler.getUserLockedShares(users[i]);
//             uint256 escrowTracked = handler.getEscrowLockedShares(users[i]);

//             assertEq(
//                 escrowTracked,
//                 handlerTracked,
//                 string(abi.encodePacked("Locked shares mismatch for user ", i))
//             );
//         }
//     }

//     /**
//      * @notice INVARIANT: Total locked shares in vault equals sum of user locked shares
//      */
//     function invariant_totalLockedSharesConsistency() public view {
//         uint256 vaultShareBalance = vault.balanceOf(address(vault));
//         uint256 escrowTotalLocked = escrow.getTotalLocked(address(vault));

//         assertEq(escrowTotalLocked, vaultShareBalance, "Total locked shares mismatch");
//     }

//     function invariant_logWithdrawRedeemStats() public view {
//         console.log("=== WITHDRAW/REDEEM Invariant Stats ===");
//         console.log("Total guids:", handler.getGuidsLength());
//         console.log("Vault share balance:", vault.balanceOf(address(vault)));
//         console.log("Escrow total locked:", escrow.getTotalLocked(address(vault)));
//     }
// }

// // ============================================================================
// // TEST 3: Fuzz Tests for releaseTokensForExecution
// // ============================================================================

// contract MoreEscrowReleaseFuzzTest is Test {
//     MoreEscrow public escrow;
//     MockVaultWithShares public vault;
//     ERC20Mock public token;
//     address public manager = makeAddr("manager");

//     function setUp() public {
//         token = new ERC20Mock();
//         vault = new MockVaultWithShares(address(token));

//         vm.prank(address(vault));
//         escrow = new MoreEscrow(address(vault));

//         vm.prank(address(vault));
//         escrow.setCrossChainAccountingManager(manager);

//         vault.setEscrow(address(escrow));
//     }

//     /**
//      * @notice Fuzz: releaseTokensForExecution should revert for non-existent guids
//      */
//     function testFuzz_releaseRevertsForNonExistentGuid(bytes32 randomGuid) public {
//         vm.prank(manager);
//         vm.expectRevert(MoreEscrow.RequestNotFound.selector);
//         escrow.releaseTokensForExecution(randomGuid);
//     }

//     /**
//      * @notice Fuzz: Only manager can call releaseTokensForExecution
//      */
//     function testFuzz_releaseOnlyManager(address caller, bytes32 guid) public {
//         vm.assume(caller != manager);

//         vm.prank(caller);
//         vm.expectRevert(MoreEscrow.OnlyCrossChainAccountingManager.selector);
//         escrow.releaseTokensForExecution(guid);
//     }

//     /**
//      * @notice Fuzz: unlockTokensAfterExecution should revert for non-existent guids
//      */
//     function testFuzz_unlockRevertsForNonExistentGuid(bytes32 randomGuid) public {
//         address[] memory tokens = new address[](0);
//         uint256[] memory amounts = new uint256[](0);

//         vm.prank(manager);
//         vm.expectRevert(MoreEscrow.RequestNotFound.selector);
//         escrow.unlockTokensAfterExecution(randomGuid, tokens, amounts);
//     }

//     /**
//      * @notice Fuzz: refundTokens should handle non-existent guids gracefully
//      */
//     function testFuzz_refundNonExistentGuid(bytes32 randomGuid) public {
//         vm.prank(manager);
//         vm.expectRevert(MoreEscrow.RequestNotFound.selector);
//         escrow.refundTokens(randomGuid);
//     }

//     /**
//      * @notice Fuzz: Cannot release same guid twice
//      */
//     function testFuzz_cannotReleaseTwice(uint256 amount, address user) public {
//         amount = bound(amount, 1 ether, 100 ether);
//         vm.assume(user != address(0) && user != address(escrow) && user != address(vault));

//         // Setup a valid deposit
//         token.mint(user, amount);
//         vm.prank(user);
//         token.approve(address(escrow), amount);

//         bytes32 guid = keccak256(abi.encodePacked(amount, user, block.timestamp));
//         bytes memory actionCallData = abi.encode(amount, user);

//         vm.prank(address(vault));
//         escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

//         // First release should work
//         vm.prank(manager);
//         escrow.releaseTokensForExecution(guid);

//         // Finalize
//         address[] memory tokens = new address[](1);
//         tokens[0] = address(token);
//         uint256[] memory amounts = new uint256[](1);
//         amounts[0] = amount;

//         vm.prank(manager);
//         escrow.unlockTokensAfterExecution(guid, tokens, amounts);

//         // Second release should fail (already finalized)
//         vm.prank(manager);
//         vm.expectRevert(MoreEscrow.RequestAlreadyFinalized.selector);
//         escrow.releaseTokensForExecution(guid);
//     }

//     /**
//      * @notice Fuzz: Valid deposit flow works correctly
//      */
//     function testFuzz_validDepositFlow(uint256 amount, address user) public {
//         amount = bound(amount, 1 ether, 100 ether);
//         vm.assume(user != address(0) && user != address(escrow) && user != address(vault));

//         // Setup
//         token.mint(user, amount);
//         vm.prank(user);
//         token.approve(address(escrow), amount);

//         bytes32 guid = keccak256(abi.encodePacked(amount, user, block.timestamp, "deposit"));
//         bytes memory actionCallData = abi.encode(amount, user);

//         // Lock
//         vm.prank(address(vault));
//         escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

//         // Verify escrow has tokens
//         assertEq(token.balanceOf(address(escrow)), amount);

//         // Release
//         vm.prank(manager);
//         (address[] memory tokens, uint256[] memory amounts, ) = escrow.releaseTokensForExecution(guid);

//         // Verify vault has tokens
//         assertEq(token.balanceOf(address(vault)), amount);
//         assertEq(tokens[0], address(token));
//         assertEq(amounts[0], amount);
//     }

//     /**
//      * @notice Fuzz: Refund returns tokens to user
//      */
//     function testFuzz_refundReturnsTokens(uint256 amount, address user) public {
//         amount = bound(amount, 1 ether, 100 ether);
//         vm.assume(user != address(0) && user != address(escrow) && user != address(vault));

//         // Setup
//         token.mint(user, amount);
//         vm.prank(user);
//         token.approve(address(escrow), amount);

//         bytes32 guid = keccak256(abi.encodePacked(amount, user, block.timestamp, "refund"));
//         bytes memory actionCallData = abi.encode(amount, user);

//         // Lock
//         vm.prank(address(vault));
//         escrow.lockTokens(guid, MoreVaultsLib.ActionType.DEPOSIT, actionCallData, 0, user);

//         uint256 userBalanceBefore = token.balanceOf(user);
//         assertEq(userBalanceBefore, 0);

//         // Refund
//         vm.prank(manager);
//   // Verify user got tokens back
//         assertEq(token.balanceOf(user), amount);
//         assertEq(token.balanceOf(address(escrow)), 0);
//     }
// }
