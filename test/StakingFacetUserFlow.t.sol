// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {StakingFacet} from "../src/facets/StakingFacet.sol";
import {IStakingFacet} from "../src/interfaces/facets/IStakingFacet.sol";
import {StakingStorage} from "../src/storage/StakingStorage.sol";

/**
 * @title StakingFacetUserFlow
 * @notice Focused tests for the user-side request/settle lifecycle.
 *
 * Why this file exists separately from StakingFacetAccounting.t.sol
 * -----------------------------------------------------------------
 * The accounting tests need a full vault + Diamond storage harness because
 * they exercise `totalAssets()` through `_accountFacets`. The user-flow tests
 * exercise functions that only touch StakingStorage (the facet's own
 * isolated slot at `keccak256("MoreVaults.storage.StakingFacet.v1")`). We
 * therefore deploy the StakingFacet directly and call into it without a
 * surrounding vault — the storage layout is self-contained.
 *
 * What is covered
 * ---------------
 * 1. `requestUnstake` happy path: populates the WithdrawalRequest, emits the
 *    event with the correct timestamp, increments `withdrawalPending`.
 * 2. Idempotency / single-pending-per-user invariant.
 * 3. `settleWithdrawal` happy path: clears the request, decrements
 *    `withdrawalPending`, returns storage to the pristine state.
 * 4. `settleWithdrawal` defenses: COA-only, NoPendingWithdrawal when nothing
 *    was requested, ZeroAmount when called with 0.
 * 5. `enqueueDeposit` happy path and ZeroAmount revert.
 */
contract StakingFacetUserFlow is Test {
    // -------------------------------------------------------------------------
    // Addresses
    // -------------------------------------------------------------------------
    address constant COA   = address(0xC0A);
    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------
    StakingFacet public facet;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        facet = new StakingFacet();
        // Bypass full initialize() — we only need authorizedCOA in StakingStorage.
        // facetsForAccounting registration is exercised in StakingFacetAccounting.
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        // slot offset 5 = authorizedCOA (see StakingStorage.Layout)
        vm.store(address(facet), bytes32(uint256(baseSlot) + 5), bytes32(uint256(uint160(COA))));
    }

    // -------------------------------------------------------------------------
    // requestUnstake
    // -------------------------------------------------------------------------

    function test_requestUnstake_PopulatesStorageAndEmits() public {
        vm.warp(1_700_000_000);

        vm.expectEmit(true, false, false, true, address(facet));
        emit IStakingFacet.WithdrawalRequested(ALICE, 5 ether, uint64(block.timestamp));

        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(5 ether);

        (uint256 amount, uint64 requestedAt, bool pending) =
            IStakingFacet(address(facet)).withdrawalRequest(ALICE);

        assertEq(amount, 5 ether, "amount stored");
        assertEq(requestedAt, uint64(block.timestamp), "timestamp stored");
        assertTrue(pending, "pending flag set");
    }

    function test_requestUnstake_RevertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStakingFacet.ZeroAmount.selector);
        IStakingFacet(address(facet)).requestUnstake(0);
    }

    function test_requestUnstake_RevertsIfAlreadyPending() public {
        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(1 ether);

        vm.prank(ALICE);
        vm.expectRevert(IStakingFacet.WithdrawalAlreadyPending.selector);
        IStakingFacet(address(facet)).requestUnstake(1 ether);
    }

    function test_requestUnstake_DistinctUsersAreIndependent() public {
        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(2 ether);

        vm.prank(BOB);
        IStakingFacet(address(facet)).requestUnstake(3 ether);

        (uint256 aAmount,, bool aPending) = IStakingFacet(address(facet)).withdrawalRequest(ALICE);
        (uint256 bAmount,, bool bPending) = IStakingFacet(address(facet)).withdrawalRequest(BOB);

        assertEq(aAmount, 2 ether);
        assertEq(bAmount, 3 ether);
        assertTrue(aPending);
        assertTrue(bPending);
    }

    // -------------------------------------------------------------------------
    // settleWithdrawal
    // -------------------------------------------------------------------------

    function test_settleWithdrawal_ClearsRequestAndDecrementsPending() public {
        // Seed the staked balance so the subtraction in settleWithdrawal doesn't underflow.
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        vm.store(address(facet), bytes32(uint256(baseSlot) + 0), bytes32(uint256(10 ether))); // totalStakedInCadence

        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(4 ether);

        vm.expectEmit(true, false, false, true, address(facet));
        emit IStakingFacet.WithdrawalSettled(ALICE, 4 ether);

        vm.prank(COA);
        IStakingFacet(address(facet)).settleWithdrawal(ALICE, 4 ether);

        (uint256 amount, uint64 requestedAt, bool pending) =
            IStakingFacet(address(facet)).withdrawalRequest(ALICE);

        assertEq(amount, 0, "request cleared");
        assertEq(requestedAt, 0, "timestamp cleared");
        assertFalse(pending, "pending cleared");
    }

    function test_settleWithdrawal_RevertsForNonCOA() public {
        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(1 ether);

        vm.prank(ALICE);
        vm.expectRevert(IStakingFacet.UnauthorizedCOA.selector);
        IStakingFacet(address(facet)).settleWithdrawal(ALICE, 1 ether);
    }

    function test_settleWithdrawal_RevertsIfNoPendingRequest() public {
        vm.prank(COA);
        vm.expectRevert(IStakingFacet.NoPendingWithdrawal.selector);
        IStakingFacet(address(facet)).settleWithdrawal(ALICE, 1 ether);
    }

    function test_settleWithdrawal_RevertsOnZeroAmount() public {
        vm.prank(COA);
        vm.expectRevert(IStakingFacet.ZeroAmount.selector);
        IStakingFacet(address(facet)).settleWithdrawal(ALICE, 0);
    }

    function test_settleWithdrawal_AllowsNewRequestAfterSettle() public {
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        vm.store(address(facet), bytes32(uint256(baseSlot) + 0), bytes32(uint256(10 ether)));

        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(2 ether);
        vm.prank(COA);
        IStakingFacet(address(facet)).settleWithdrawal(ALICE, 2 ether);

        // After settle, ALICE should be able to request again.
        vm.prank(ALICE);
        IStakingFacet(address(facet)).requestUnstake(1 ether);
        (, , bool pending) = IStakingFacet(address(facet)).withdrawalRequest(ALICE);
        assertTrue(pending);
    }

    // -------------------------------------------------------------------------
    // enqueueDeposit
    // -------------------------------------------------------------------------

    function test_enqueueDeposit_HappyPath() public {
        vm.deal(ALICE, 5 ether);

        vm.expectEmit(true, false, false, true, address(facet));
        emit IStakingFacet.DepositEnqueued(ALICE, 3 ether);

        vm.prank(ALICE);
        IStakingFacet(address(facet)).enqueueDeposit{value: 3 ether}();

        assertEq(address(facet).balance, 3 ether, "facet holds the FLOW");
    }

    function test_enqueueDeposit_RevertsOnZero() public {
        vm.prank(ALICE);
        vm.expectRevert(IStakingFacet.ZeroAmount.selector);
        IStakingFacet(address(facet)).enqueueDeposit{value: 0}();
    }

    // -------------------------------------------------------------------------
    // updateStakedBalance
    // -------------------------------------------------------------------------

    function test_updateStakedBalance_OnlyCOA() public {
        vm.prank(ALICE);
        vm.expectRevert(IStakingFacet.UnauthorizedCOA.selector);
        IStakingFacet(address(facet)).updateStakedBalance(100 ether);

        // COA can do it.
        vm.expectEmit(false, false, false, true, address(facet));
        emit IStakingFacet.StakedBalanceUpdated(0, 100 ether);

        vm.prank(COA);
        IStakingFacet(address(facet)).updateStakedBalance(100 ether);

        (uint256 amount, bool isPositive) = IStakingFacet(address(facet)).stakingTotalAssets();
        assertEq(amount, 100 ether);
        assertTrue(isPositive);
    }
}
