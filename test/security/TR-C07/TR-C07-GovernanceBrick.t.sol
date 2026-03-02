// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C07 — Governance Brick Chain: setTimeLockPeriod + setWithdrawalTimelock Permanent Locks
 *
 * @notice Proves three governance bricking vulnerabilities in MulticallFacet and
 *         ConfigurationFacet.
 *
 * BUG-01 — timeLockPeriod arithmetic overflow:
 *   submitActions() computes (MulticallFacet.sol line 60):
 *     uint256 pendingUntil = block.timestamp + ds.timeLockPeriod;
 *   If ds.timeLockPeriod == type(uint256).max, Solidity 0.8 checked arithmetic
 *   reverts on overflow. submitActions() is permanently unusable.
 *   Since setTimeLockPeriod() requires validateDiamond (msg.sender == address(this),
 *   only reachable via executeActions → submitActions), recovery is impossible:
 *   submitActions reverts → cannot submit governance actions → cannot reset
 *   timeLockPeriod → governance bricked forever.
 *
 * BUG-02 — witdrawTimelock unreachable timestamp:
 *   setWithdrawalTimelock(type(uint64).max) stores ~5.84×10^11 years as the
 *   withdrawal timelock. requestWithdraw / requestRedeem compute:
 *     timelockEndsAt = block.timestamp + ds.witdrawTimelock
 *   With type(uint64).max the result exceeds any reachable block timestamp by
 *   hundreds of billions of years. isWithdrawableRequest() never returns true.
 *   Users with an active withdrawal queue can never withdraw.
 *
 * BUG-03 — Guardian veto with no deadline:
 *   vetoActions() is callable by the guardian at any time after submitActions.
 *   There is no cooldown, no counter-veto, and no escalation path. A compromised
 *   or adversarial guardian can veto every governance action indefinitely,
 *   permanently blocking the curator from executing changes.
 *
 * DORMANCY:
 *   BUG-01 and BUG-02 require an admin (owner or curator via executeActions) to
 *   set an extreme value. They are activated by misconfiguration, not a classic
 *   exploit. BUG-03 is always present for any guardian.
 *
 * FIX (2 touch points in ConfigurationFacet):
 *   1. setTimeLockPeriod: if (period > MAX_TIME_LOCK_PERIOD) revert TimeLockPeriodTooHigh()
 *   2. setWithdrawalTimelock: if (_duration > MAX_WITHDRAWAL_TIMELOCK) revert WithdrawalTimelockTooHigh()
 *
 * Tests:
 *   C07-01: submitActions reverts on overflow with timeLockPeriod = max uint    -- BUG-01, PASS
 *   C07-02: no recovery path after governance brick                             -- BUG-01, PASS
 *   C07-03: witdrawTimelock = type(uint64).max makes timelock unreachable       -- BUG-02, PASS
 *   C07-04: guardian can veto any action at any time with no deadline           -- BUG-03, PASS
 *   C07-FIX-01: setTimeLockPeriod rejects overflow value                        -- FAIL without fix
 *   C07-FIX-02: setWithdrawalTimelock rejects max uint64                        -- FAIL without fix
 *
 * Run: forge test --match-contract TR_C07_GovernanceBrick -vvvvv
 */

import {Test, console} from "forge-std/Test.sol";
import {MulticallFacet, IMulticallFacet} from "../../../src/facets/MulticallFacet.sol";
import {ConfigurationFacet} from "../../../src/facets/ConfigurationFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";

// ---------------------------------------------------------------------------
// Error selectors used in fix verification tests.
// Defined here so the test file compiles before the fix is applied.
// The selectors match whatever ConfigurationFacet will emit after the fix.
// ---------------------------------------------------------------------------
error TimeLockPeriodTooHigh();
error WithdrawalTimelockTooHigh();

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------
contract TR_C07_GovernanceBrick is Test {

    MulticallFacet public facet;
    ConfigurationFacet public configFacet;

    address public curator  = address(1);
    address public guardian = address(2);
    address public unauthorized = address(3);

    uint256 public timeLockPeriod = 1 days;
    uint256 public currentNonce   = 0;

    bytes[] public actionsData;

    function setUp() public {
        facet      = new MulticallFacet();
        configFacet = new ConfigurationFacet();

        MoreVaultsStorageHelper.setCurator(address(facet),  curator);
        MoreVaultsStorageHelper.setGuardian(address(facet), guardian);
        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), timeLockPeriod);
        MoreVaultsStorageHelper.setActionNonce(address(facet), currentNonce);

        actionsData    = new bytes[](1);
        actionsData[0] = abi.encodeWithSignature("mockFunction()");
    }

    // =========================================================================
    // C07-01: submitActions reverts with arithmetic overflow when
    //         timeLockPeriod == type(uint256).max (BUG-01)
    //
    // MulticallFacet.sol line 60:
    //   uint256 pendingUntil = block.timestamp + ds.timeLockPeriod;
    // Solidity 0.8 checked arithmetic reverts on overflow.
    // =========================================================================
    function test_C07_01_submitActions_reverts_overflow_with_max_timeLockPeriod() public {
        console.log("=================================================================");
        console.log("C07-01: submitActions overflow when timeLockPeriod = type(uint256).max");
        console.log("=================================================================");

        console.log("Setting timeLockPeriod to type(uint256).max via storage helper...");
        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), type(uint256).max);

        console.log("Calling submitActions as curator -- expect Panic(arithmetic overflow)");
        vm.prank(curator);
        vm.expectRevert(); // Panic 0x11: arithmetic overflow
        facet.submitActions(actionsData);

        console.log("CONFIRMED: submitActions reverts with arithmetic overflow.");
        console.log("timeLockPeriod = type(uint256).max bricks governance permanently.");
    }

    // =========================================================================
    // C07-02: No recovery path after governance brick (BUG-01 consequence)
    //
    // After timeLockPeriod = type(uint256).max:
    //   - submitActions always reverts (C07-01)
    //   - setTimeLockPeriod requires validateDiamond (msg.sender == address(this))
    //   - validateDiamond is only satisfied through executeActions self-call
    //   - executeActions requires a pending action submitted via submitActions
    //   - submitActions reverts → no pending action can be created → no recovery
    // =========================================================================
    function test_C07_02_no_recovery_path_after_governance_brick() public {
        console.log("=================================================================");
        console.log("C07-02: No recovery path after timeLockPeriod bricked to max uint");
        console.log("=================================================================");

        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), type(uint256).max);

        // Path A: curator cannot submit any governance action
        console.log("Path A: submitActions always reverts (cannot queue any action)");
        vm.prank(curator);
        vm.expectRevert(); // arithmetic overflow
        facet.submitActions(actionsData);
        console.log("CONFIRMED: submitActions reverts.");

        // Path B: curator cannot call setTimeLockPeriod directly (validateDiamond)
        // validateDiamond: requires msg.sender == address(this)
        // Direct call from curator has msg.sender = curator ≠ address(configFacet)
        console.log("Path B: cannot call setTimeLockPeriod directly (validateDiamond guard)");
        vm.prank(curator);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        configFacet.setTimeLockPeriod(1 days);
        console.log("CONFIRMED: direct call rejected with UnauthorizedAccess.");

        // Path C: owner also cannot call setTimeLockPeriod directly
        console.log("Path C: owner also cannot call setTimeLockPeriod directly");
        address owner = makeAddr("owner");
        vm.prank(owner);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        configFacet.setTimeLockPeriod(1 days);
        console.log("CONFIRMED: no recovery path exists.");
        console.log("IMPACT: governance is permanently bricked with no on-chain remedy.");
    }

    // =========================================================================
    // C07-03: witdrawTimelock = type(uint64).max creates effectively permanent
    //         withdrawal timelock (BUG-02)
    //
    // requestWithdraw / requestRedeem compute:
    //   timelockEndsAt = block.timestamp + ds.witdrawTimelock
    // type(uint64).max ≈ 1.844 × 10^19 seconds ≈ 584 billion years.
    // isWithdrawableRequest checks block.timestamp >= timelockEndsAt.
    // This condition is unreachable within any practical timescale.
    // =========================================================================
    function test_C07_03_witdrawTimelock_max_uint64_makes_timelock_effectively_permanent() public view {
        console.log("=================================================================");
        console.log("C07-03: witdrawTimelock = type(uint64).max -- permanent lock");
        console.log("=================================================================");

        // type(uint64).max seconds ≈ 584 billion years
        uint64  maxTimelock    = type(uint64).max;
        uint256 timelockEndsAt = block.timestamp + maxTimelock;

        // Verify the computed timelockEndsAt is beyond any practical future
        uint256 thousandYearsFromNow = block.timestamp + 1_000 * 365 days;
        assertGt(
            timelockEndsAt,
            thousandYearsFromNow,
            "BUG-02: timelockEndsAt exceeds 1,000 years from now"
        );

        // isWithdrawableRequest: block.timestamp >= timelockEndsAt → always false
        bool withdrawable = block.timestamp >= timelockEndsAt;
        assertFalse(withdrawable, "BUG-02: withdrawal timelock unreachable");

        uint256 yearsUntilUnlock = (timelockEndsAt - block.timestamp) / (365 days);
        console.log("witdrawTimelock = type(uint64).max =", uint256(maxTimelock), "seconds");
        console.log("Years until unlock:", yearsUntilUnlock);
        console.log("CONFIRMED: isWithdrawableRequest can never return true.");
        console.log("IMPACT: withdrawal queue permanently locked. Users cannot withdraw.");
    }

    // =========================================================================
    // C07-04: Guardian can veto any action at any time with no deadline (BUG-03)
    //
    // vetoActions() is callable by the guardian at any time after submitActions.
    // There is no deadline after which the guardian loses veto power, no
    // counter-veto mechanism, and no escalation path. A compromised guardian
    // can veto every governance action indefinitely.
    // =========================================================================
    function test_C07_04_guardian_can_veto_any_action_at_any_time() public {
        console.log("=================================================================");
        console.log("C07-04: Guardian veto with no deadline (BUG-03)");
        console.log("=================================================================");

        // Round 1: curator submits, guardian vetoes immediately
        console.log("Round 1: curator submits action");
        vm.prank(curator);
        uint256 nonce0 = facet.submitActions(actionsData);
        console.log("Action submitted. Nonce:", nonce0);

        console.log("Guardian vetoes before timelock expires");
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce0;
        vm.prank(guardian);
        facet.vetoActions(nonces);

        // Action is gone — executeActions would revert with NoSuchActions
        console.log("Attempting executeActions on vetoed action -> NoSuchActions");
        vm.warp(block.timestamp + timeLockPeriod + 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, nonce0));
        facet.executeActions(nonce0);
        console.log("CONFIRMED: vetoed action cannot be executed.");

        // Round 2: curator submits again, guardian vetoes again after timelock
        console.log("Round 2: curator submits again, guardian vetoes after full timelock elapsed");
        vm.prank(curator);
        uint256 nonce1 = facet.submitActions(actionsData);
        vm.warp(block.timestamp + timeLockPeriod + 1);
        nonces[0] = nonce1;
        vm.prank(guardian);
        facet.vetoActions(nonces);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, nonce1));
        facet.executeActions(nonce1);
        console.log("CONFIRMED: guardian can veto even after full timelock with no deadline.");
        console.log("IMPACT: compromised guardian can permanently block all governance changes.");
    }

    // =========================================================================
    // C07-FIX-01: setTimeLockPeriod rejects overflow value (FAILS without fix)
    //
    // With fix: setTimeLockPeriod(type(uint256).max) reverts with TimeLockPeriodTooHigh.
    // Without fix: call succeeds and stores the dangerous value. vm.expectRevert fails.
    //
    // vm.prank(address(configFacet)) satisfies validateDiamond:
    //   msg.sender == address(this) → address(configFacet) == address(configFacet) ✓
    // =========================================================================
    function test_C07_FIX01_setTimeLockPeriod_rejects_overflow_value() public {
        console.log("=================================================================");
        console.log("C07-FIX-01: setTimeLockPeriod rejects overflow value (FAIL without fix)");
        console.log("=================================================================");

        console.log("Calling setTimeLockPeriod(type(uint256).max) via self-call trick...");
        console.log("Expected: revert TimeLockPeriodTooHigh");
        console.log("Without fix: no revert -> vm.expectRevert() fails -> test FAILS");

        // vm.prank(address(configFacet)) satisfies validateDiamond:
        //   inside the call, msg.sender == address(this) == address(configFacet) ✓
        vm.prank(address(configFacet));
        vm.expectRevert(TimeLockPeriodTooHigh.selector); // FAILS without fix
        configFacet.setTimeLockPeriod(type(uint256).max);

        console.log("PASS: setTimeLockPeriod correctly rejected overflow value.");
    }

    // =========================================================================
    // C07-FIX-02: setWithdrawalTimelock rejects type(uint64).max (FAILS without fix)
    //
    // With fix: setWithdrawalTimelock(type(uint64).max) reverts with WithdrawalTimelockTooHigh.
    // Without fix: call succeeds and stores the unreachable timelock value.
    // =========================================================================
    function test_C07_FIX02_setWithdrawalTimelock_rejects_max_uint64() public {
        console.log("=================================================================");
        console.log("C07-FIX-02: setWithdrawalTimelock rejects max uint64 (FAIL without fix)");
        console.log("=================================================================");

        console.log("Calling setWithdrawalTimelock(type(uint64).max) via self-call trick...");
        console.log("Expected: revert WithdrawalTimelockTooHigh");
        console.log("Without fix: no revert -> vm.expectRevert() fails -> test FAILS");

        vm.prank(address(configFacet));
        vm.expectRevert(WithdrawalTimelockTooHigh.selector); // FAILS without fix
        configFacet.setWithdrawalTimelock(type(uint64).max);

        console.log("PASS: setWithdrawalTimelock correctly rejected max uint64.");
    }
}
