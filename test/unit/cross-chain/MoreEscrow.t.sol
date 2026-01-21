// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity 0.8.28;

// import {Test, console} from "forge-std/Test.sol";
// import {MoreVaultsEscrow} from "../../../src/cross-chain/MoreVaultsEscrow.sol";

// /**
//  * @title MoreVaultsEscrowAccessControlTest
//  * @notice Tests for access control on setCrossChainAccountingManager
//  */
// contract MoreVaultsEscrowAccessControlTest is Test {
//     MoreVaultsEscrow public escrow;

//     address public vault = makeAddr("vault");
//     address public legitimateManager = makeAddr("legitimateManager");
//     address public attacker = makeAddr("attacker");
//     address public randomUser = makeAddr("randomUser");

//     function setUp() public {
//         // Deploy escrow with vault as the authorized caller
//         vm.prank(vault);
//         escrow = new MoreVaultsEscrow(vault);

//         // Set legitimate manager (only vault can do this)
//         vm.prank(vault);
//         escrow.setCrossChainAccountingManager(legitimateManager);
//     }

//     /**
//      * @notice Test that only vault can set the cross-chain accounting manager
//      */
//     function test_OnlyVaultCanSetManager() public {
//         // Verify legitimate manager is set
//         assertEq(escrow.crossChainAccountingManager(), legitimateManager);

//         // Attacker tries to set themselves as manager - SHOULD REVERT
//         vm.prank(attacker);
//         vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
//         escrow.setCrossChainAccountingManager(attacker);

//         // Manager should still be the legitimate one
//         assertEq(escrow.crossChainAccountingManager(), legitimateManager);
//     }

//     /**
//      * @notice Test that random users cannot set the manager
//      */
//     function test_RandomUserCannotSetManager() public {
//         vm.prank(randomUser);
//         vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
//         escrow.setCrossChainAccountingManager(randomUser);

//         assertEq(escrow.crossChainAccountingManager(), legitimateManager);
//     }

//     /**
//      * @notice Test that vault CAN set the manager
//      */
//     function test_VaultCanSetManager() public {
//         address newManager = makeAddr("newManager");

//         vm.prank(vault);
//         escrow.setCrossChainAccountingManager(newManager);

//         assertEq(escrow.crossChainAccountingManager(), newManager);
//     }

//     /**
//      * @notice Test that vault can change the manager multiple times
//      */
//     function test_VaultCanChangeManagerMultipleTimes() public {
//         address manager1 = makeAddr("manager1");
//         address manager2 = makeAddr("manager2");

//         vm.prank(vault);
//         escrow.setCrossChainAccountingManager(manager1);
//         assertEq(escrow.crossChainAccountingManager(), manager1);

//         vm.prank(vault);
//         escrow.setCrossChainAccountingManager(manager2);
//         assertEq(escrow.crossChainAccountingManager(), manager2);
//     }

//     /**
//      * @notice Test that attacker cannot hijack manager to call protected functions
//      */
//     function test_AttackerCannotHijackManagerToCallProtectedFunctions() public {
//         // Attacker tries to set themselves as manager - REVERTS
//         vm.prank(attacker);
//         vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
//         escrow.setCrossChainAccountingManager(attacker);

//         // Attacker tries to call protected function directly - REVERTS
//         bytes32 fakeGuid = keccak256("fake");
//         vm.prank(attacker);
//         vm.expectRevert(MoreVaultsEscrow.OnlyCrossChainAccountingManager.selector);
//         escrow.refundTokens(fakeGuid);
//     }

//     /**
//      * @notice Fuzz test: no address except vault can set manager
//      */
//     function testFuzz_OnlyVaultCanSetManager(address caller) public {
//         vm.assume(caller != vault);

//         vm.prank(caller);
//         vm.expectRevert(MoreVaultsEscrow.OnlyVault.selector);
//         escrow.setCrossChainAccountingManager(caller);

//         assertEq(escrow.crossChainAccountingManager(), legitimateManager);
//     }
// }
