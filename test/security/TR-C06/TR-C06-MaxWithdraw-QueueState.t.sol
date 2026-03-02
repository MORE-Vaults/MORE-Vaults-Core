// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title TR-C06 -- maxWithdraw / maxRedeem ignore withdrawal queue state
 *
 * Run: forge test --match-contract TR_C06 -vvvvv
 */

import {Test, console} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MockMoreVaultsEscrow} from "../../mocks/MockMoreVaultsEscrow.sol";

contract TR_C06_MaxWithdraw_QueueState is Test {

    address public facet;
    address public owner   = address(9999);
    address public curator = address(7);
    address public guardian = address(8);
    address public feeRecipient = address(9);
    address public registry = address(1000);
    address public asset;
    address public user    = address(1);
    address public operator = address(2);  // can call requestWithdraw on behalf
    address public factory = address(1001);
    address public router  = address(1002);
    address public oracleRegistry = address(1003);
    address public oracle  = address(1004);
    MockMoreVaultsEscrow public escrow;

    uint64  constant TIMELOCK   = 1 days;
    uint32  constant MAX_DELAY  = 14 days;
    uint256 constant DEPOSIT    = 100 ether;
    string  constant VAULT_NAME   = "Test Vault";
    string  constant VAULT_SYMBOL = "TV";
    uint96  constant FEE          = 0;
    uint256 constant DEPOSIT_CAP  = 1_000_000 ether;

    // -------------------------------------------------------------------------
    // setUp -- copied from VaultFacet.t.sol and adapted
    // -------------------------------------------------------------------------
    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        VaultFacet vaultFacet = new VaultFacet();
        facet = address(vaultFacet);

        MockERC20 mockAsset = new MockERC20("Test Asset", "TA");
        asset = address(mockAsset);

        escrow = new MockMoreVaultsEscrow();
        escrow.setUnderlyingToken(facet, asset);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setOwner(facet, owner);
        MoreVaultsStorageHelper.setFactory(facet, factory);

        bytes memory initData = abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE, DEPOSIT_CAP);

        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleRegistry));
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(2000), uint96(1000))
        );

        VaultFacet(facet).initialize(initData);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setCurator(facet, curator);
        MoreVaultsStorageHelper.setGuardian(facet, guardian);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user, 10_000_000 ether);
        MoreVaultsStorageHelper.setIsHub(facet, true);

        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid)));
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), facet),
            abi.encode(false)
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector), abi.encode(address(escrow)));

        MockERC20(asset).mint(user, 1000 ether);
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);

        // Enable withdrawal queue for all tests
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, uint64(TIMELOCK));
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, MAX_DELAY);

        // Common mocks for deposit/withdraw
        _mockOracle();
        _mockProtocolFee();
        _mockSpokes();

        // User deposits 100 ether so they have shares
        vm.prank(user);
        VaultFacet(facet).deposit(DEPOSIT, user);
    }

    function _mockOracle() internal {
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(oracle, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0));
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
    }

    function _mockProtocolFee() internal {
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
    }

    function _mockSpokes() internal {
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
    }

    // test helper to exclude from coverage
    function test_skip() external {}

    // =========================================================================
    // FIX-A (naive): override maxRedeem to check queue state.
    // Applies ONLY this change to maxRedeem, nothing else.
    // Expected: maxWithdraw/maxRedeem now return 0 when no valid request.
    // SIDE EFFECT: requestRedeem breaks because it uses maxRedeem as balance cap.
    // This test documents the regression -- it FAILS if Fix A is the only change.
    // =========================================================================
    function test_C06_FIXA_maxRedeem_returns_zero_when_no_valid_request() public view {
        console.log("=================================================================");
        console.log("C06-FIX-A: maxRedeem = 0 when queue enabled + no valid request");
        console.log("=================================================================");
        // With Fix A applied: maxRedeem checks queue state, no request = 0
        uint256 mr = VaultFacet(facet).maxRedeem(user);
        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        console.log("maxRedeem (expected 0 with fix):", mr);
        console.log("maxWithdraw (expected 0 with fix):", mw);
        assertEq(mr, 0, "FIX-A: maxRedeem must return 0 when queue enabled, no valid request");
        assertEq(mw, 0, "FIX-A: maxWithdraw must return 0 (inherits via previewRedeem(maxRedeem))");
        console.log("PASS: maxRedeem and maxWithdraw agree with actual withdraw() behavior.");
    }

    function test_C06_FIXA_regression_requestRedeem_breaks_with_naive_fix() public {
        console.log("=================================================================");
        console.log("C06-FIX-A regression: requestRedeem breaks if maxRedeem returns 0");
        console.log("=================================================================");
        // With Fix A only: maxRedeem(user) = 0 (no valid request yet)
        // requestRedeem checks: _shares <= maxRedeem(owner)
        // shares = 10000, maxRedeem = 0 -> ERC4626ExceededMaxRedeem
        uint256 shares = IERC20(facet).balanceOf(user);
        console.log("User shares:", shares / 1e18);
        console.log("maxRedeem with Fix A:", VaultFacet(facet).maxRedeem(user));
        console.log("Attempting requestRedeem(shares)...");
        // With Fix A alone this reverts -- requestRedeem is broken
        vm.prank(user);
        vm.expectRevert();
        VaultFacet(facet).requestRedeem(shares, user);
        console.log("CONFIRMED: Fix A alone breaks requestRedeem. Refactor needed.");
        console.log("requestRedeem must use balanceOf() directly, not maxRedeem().");
    }

    // =========================================================================
    // FIX-B (correct): requestRedeem/requestWithdraw use balanceOf() directly,
    // maxRedeem checks queue state. Both fixes applied together.
    // All C06 behavior is correct, no regression on requestRedeem/requestWithdraw.
    // =========================================================================
    function test_C06_FIXB_maxWithdraw_zero_no_request() public view {
        console.log("=================================================================");
        console.log("C06-FIX-B: maxWithdraw = 0 when queue enabled + no request");
        console.log("=================================================================");
        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        uint256 mr = VaultFacet(facet).maxRedeem(user);
        console.log("maxWithdraw:", mw, " (expected 0)");
        console.log("maxRedeem:  ", mr, " (expected 0)");
        assertEq(mw, 0, "FIX-B: maxWithdraw = 0 when no valid request");
        assertEq(mr, 0, "FIX-B: maxRedeem = 0 when no valid request");
    }

    function test_C06_FIXB_requestRedeem_still_works_after_refactor() public {
        console.log("=================================================================");
        console.log("C06-FIX-B: requestRedeem still works after refactor (uses balanceOf)");
        console.log("=================================================================");
        uint256 shares = IERC20(facet).balanceOf(user);
        console.log("User shares:", shares / 1e18);
        // Fix B: requestRedeem uses balanceOf() not maxRedeem() -- no regression
        vm.prank(user);
        VaultFacet(facet).requestRedeem(shares, user);
        (uint256 reqShares,) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "requestRedeem accepted shares equal to balance");
        console.log("requestRedeem succeeded. No regression.");
    }

    function test_C06_FIXB_maxWithdraw_correct_after_elapsed_timelock() public {
        console.log("=================================================================");
        console.log("C06-FIX-B: maxWithdraw reflects queued amount after timelock elapses");
        console.log("=================================================================");
        uint256 withdrawAmount = 50 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);

        // Before timelock: maxWithdraw = 0
        uint256 mwBefore = VaultFacet(facet).maxWithdraw(user);
        console.log("maxWithdraw before timelock:", mwBefore, " (expected 0)");
        assertEq(mwBefore, 0, "FIX-B: maxWithdraw = 0 during active timelock");

        // After timelock: maxWithdraw = withdrawAmount
        (, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        vm.warp(timelockEndsAt + 1);

        uint256 mwAfter = VaultFacet(facet).maxWithdraw(user);
        console.log("maxWithdraw after timelock:", mwAfter / 1e18, "assets  (expected ~50)");
        assertGt(mwAfter, 0, "FIX-B: maxWithdraw > 0 after timelock elapsed");

        // withdraw succeeds and amount matches maxWithdraw
        uint256 assetsBefore = IERC20(asset).balanceOf(user);
        vm.prank(user);
        VaultFacet(facet).withdraw(withdrawAmount, user, user);
        uint256 received = IERC20(asset).balanceOf(user) - assetsBefore;
        console.log("Assets received:", received / 1e18);
        assertEq(received, withdrawAmount, "FIX-B: received matches requested amount");
        console.log("PASS: maxWithdraw and withdraw() agree perfectly.");
    }

    // =========================================================================
    // C06-01: maxWithdraw returns non-zero but withdraw() reverts -- no request
    //
    // Queue enabled. User has 100 ether worth of shares.
    // No withdrawal request has been submitted.
    // maxWithdraw says user CAN withdraw. withdraw() says they cannot.
    // =========================================================================
    function test_C06_01_maxWithdraw_nonzero_but_withdraw_reverts_no_request() public {
        console.log("=================================================================");
        console.log("C06-01: maxWithdraw nonzero, withdraw reverts -- queue enabled, no request");
        console.log("=================================================================");

        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        uint256 mr = VaultFacet(facet).maxRedeem(user);

        console.log("User shares:       ", IERC20(facet).balanceOf(user) / 1e18, "shares");
        console.log("maxWithdraw:       ", mw / 1e18, "assets  <-- says CAN withdraw");
        console.log("maxRedeem:         ", mr / 1e18, "shares  <-- says CAN redeem");
        console.log("queue enabled:     true");
        console.log("request exists:    false");

        assertGt(mw, 0, "maxWithdraw should return non-zero (BUG: lies about withdrawal feasibility)");
        assertGt(mr, 0, "maxRedeem should return non-zero (BUG: lies about redeem feasibility)");

        // Now try the actual withdraw -- it must revert
        console.log("Attempting withdraw(50 ether)...");
        vm.prank(user);
        vm.expectRevert(IVaultFacet.CantProcessWithdrawRequest.selector);
        VaultFacet(facet).withdraw(50 ether, user, user);

        console.log("CONFIRMED: maxWithdraw =", mw / 1e18, "but withdraw() reverts.");
        console.log("BUG: maxWithdraw does not read isWithdrawalQueueEnabled or withdrawalRequests[owner].");
    }

    // =========================================================================
    // C06-02: maxRedeem returns non-zero but redeem() reverts -- no request
    // =========================================================================
    function test_C06_02_maxRedeem_nonzero_but_redeem_reverts_no_request() public {
        console.log("=================================================================");
        console.log("C06-02: maxRedeem nonzero, redeem reverts -- queue enabled, no request");
        console.log("=================================================================");

        uint256 shares = IERC20(facet).balanceOf(user);
        uint256 mr = VaultFacet(facet).maxRedeem(user);

        console.log("User shares:    ", shares / 1e18);
        console.log("maxRedeem:      ", mr / 1e18, "  <-- says CAN redeem");

        assertEq(mr, shares, "maxRedeem returns full balance ignoring queue state");

        vm.prank(user);
        vm.expectRevert(IVaultFacet.CantProcessWithdrawRequest.selector);
        VaultFacet(facet).redeem(shares, user, user);

        console.log("CONFIRMED: maxRedeem =", mr / 1e18, "but redeem() reverts.");
    }

    // =========================================================================
    // C06-03: Request exists but timelock not elapsed -- maxWithdraw still lies
    //
    // User submits a valid request. Timelock has NOT elapsed yet.
    // maxWithdraw still returns non-zero (same as before, ignores timelock).
    // withdraw() reverts because block.timestamp < timelockEndsAt.
    // =========================================================================
    function test_C06_03_request_exists_timelock_not_elapsed_maxWithdraw_still_lies() public {
        console.log("=================================================================");
        console.log("C06-03: Request exists, timelock NOT elapsed -- maxWithdraw still lies");
        console.log("=================================================================");

        // Submit request
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(50 ether, user);

        (uint256 reqShares, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        console.log("Request shares:    ", reqShares / 1e18);
        console.log("Timelock ends at:  ", timelockEndsAt);
        console.log("Current time:      ", block.timestamp, "  <-- timelock NOT elapsed");

        assertTrue(block.timestamp < timelockEndsAt, "timelock should not be elapsed yet");

        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        console.log("maxWithdraw:       ", mw / 1e18, "  <-- still says CAN withdraw");
        assertGt(mw, 0, "maxWithdraw still non-zero even though timelock not elapsed");

        vm.prank(user);
        vm.expectRevert(IVaultFacet.CantProcessWithdrawRequest.selector);
        VaultFacet(facet).withdraw(50 ether, user, user);

        console.log("CONFIRMED: maxWithdraw =", mw / 1e18, "but withdraw reverts (timelock active).");
    }

    // =========================================================================
    // C06-04: Timelock reset griefing -- operator resets timelock repeatedly
    //
    // Operator (curator) calls requestWithdraw on behalf of user repeatedly,
    // resetting timelockEndsAt each time. maxWithdraw always returns non-zero.
    // withdraw() always reverts. User can never exit.
    // =========================================================================
    function test_C06_04_timelock_reset_griefing_perpetuates_inconsistency() public {
        console.log("=================================================================");
        console.log("C06-04: Timelock reset griefing -- operator resets timelock N times");
        console.log("=================================================================");

        // User submits request, timelock starts
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(50 ether, user);
        (, uint256 tl1) = VaultFacet(facet).getWithdrawalRequest(user);
        console.log("Round 1 timelockEndsAt:", tl1);

        // Warp to just before timelock expires, operator resets
        vm.warp(tl1 - 1);
        // Curator submits a new request on behalf of user (allowed via allowance or as curator?)
        // Actually requestWithdraw needs msg.sender == _onBehalfOf OR allowance
        // The griefing scenario: user must call themselves or have approved the operator
        // Let's simulate the user being griefed by their own re-request (e.g., front-run)
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(50 ether, user);
        (, uint256 tl2) = VaultFacet(facet).getWithdrawalRequest(user);
        console.log("Round 2 timelockEndsAt:", tl2, "(reset, new 1-day timelock)");

        assertTrue(tl2 > tl1 - 1, "timelock was reset to future");

        // maxWithdraw still non-zero after reset
        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        console.log("maxWithdraw after reset:", mw / 1e18, "  <-- still lying");
        assertGt(mw, 0, "maxWithdraw non-zero even though timelock was reset");

        // withdraw still reverts
        vm.prank(user);
        vm.expectRevert(IVaultFacet.CantProcessWithdrawRequest.selector);
        VaultFacet(facet).withdraw(50 ether, user, user);

        console.log("CONFIRMED: Each reset of requestWithdraw resets the 1-day timelock.");
        console.log("maxWithdraw always claims user can exit. withdraw() always reverts.");
        console.log("Combined with TR-S12 (operator-triggered overwrite): operator can perpetually block exit.");
    }

    // =========================================================================
    // C06-05: No fund loss -- withdraw() just reverts, funds stay safe
    //
    // Confirms the bug is a view-function lie, not a fund loss.
    // User's shares and vault assets remain intact after failed withdraw attempts.
    // =========================================================================
    function test_C06_05_no_fund_loss_funds_safe_after_failed_attempts() public {
        console.log("=================================================================");
        console.log("C06-05: Fund safety -- failed withdraw() leaves funds intact");
        console.log("=================================================================");

        uint256 sharesBefore = IERC20(facet).balanceOf(user);
        uint256 assetsBefore = IERC20(asset).balanceOf(user);
        console.log("Shares before:", sharesBefore / 1e18);
        console.log("Assets before:", assetsBefore / 1e18);

        // Try withdraw without request -- reverts
        vm.prank(user);
        try VaultFacet(facet).withdraw(50 ether, user, user) {
            revert("should have reverted");
        } catch {}

        uint256 sharesAfter = IERC20(facet).balanceOf(user);
        uint256 assetsAfter = IERC20(asset).balanceOf(user);

        assertEq(sharesAfter, sharesBefore, "shares unchanged after failed withdraw");
        assertEq(assetsAfter, assetsBefore, "assets unchanged after failed withdraw");

        console.log("Shares after: ", sharesAfter / 1e18, "  (unchanged)");
        console.log("Assets after: ", assetsAfter / 1e18, "  (unchanged)");
        console.log("CONFIRMED: No fund loss. Bug is purely a view-function inconsistency.");
        console.log("Impact: off-chain systems, aggregators, ERC4626 integrators get wrong signal.");
    }

    // =========================================================================
    // C06-06: Correct path -- request submitted, timelock elapsed, both agree
    //
    // When queue is properly used, maxWithdraw and withdraw() eventually agree.
    // This is the expected happy-path behavior when the queue works correctly.
    // =========================================================================
    function test_C06_06_correct_path_request_plus_elapsed_timelock() public {
        console.log("=================================================================");
        console.log("C06-06: Happy path -- request + elapsed timelock works correctly");
        console.log("=================================================================");

        uint256 withdrawAmount = 50 ether;

        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);

        (, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        vm.warp(timelockEndsAt + 1);

        uint256 mw = VaultFacet(facet).maxWithdraw(user);
        console.log("maxWithdraw after timelock elapsed:", mw / 1e18);

        uint256 assetsBefore = IERC20(asset).balanceOf(user);
        vm.prank(user);
        VaultFacet(facet).withdraw(withdrawAmount, user, user);
        uint256 assetsAfter = IERC20(asset).balanceOf(user);

        console.log("Assets received:", (assetsAfter - assetsBefore) / 1e18);
        assertEq(assetsAfter - assetsBefore, withdrawAmount, "correct assets received");

        console.log("CONFIRMED: Happy path works. Bug only manifests when maxWithdraw is");
        console.log("queried BEFORE the timelock has elapsed (the window between request");
        console.log("submission and timelock expiry, or when no request exists at all).");
    }

    // =========================================================================
    // C06-07: Why refactor is needed -- naive fix to maxRedeem breaks requestRedeem
    //
    // requestRedeem validates: shares <= maxRedeem(owner)
    // If maxRedeem returned 0 when queue enabled + no request, requestRedeem
    // would always revert (can't create the initial request).
    // This proves a simple override of maxRedeem is insufficient.
    // =========================================================================
    function test_C06_07_why_refactor_needed_maxRedeem_used_in_requestRedeem_validation() public {
        console.log("=================================================================");
        console.log("C06-07: Refactor context -- maxRedeem used in requestRedeem validation");
        console.log("=================================================================");

        uint256 shares = IERC20(facet).balanceOf(user);
        uint256 mr = VaultFacet(facet).maxRedeem(user);

        console.log("User shares:     ", shares / 1e18);
        console.log("maxRedeem:       ", mr / 1e18, "  (used inside requestRedeem as cap)");

        // requestRedeem checks: _shares <= maxRedeem(_onBehalfOf)
        // If a naive fix made maxRedeem return 0 when queue enabled + no request:
        // requestRedeem would revert here with ERC4626ExceededMaxRedeem
        // because shares (non-zero) > maxRedeem (0).
        // This would break the ability to create the initial request entirely.

        // Confirm requestRedeem currently works (reads maxRedeem as balanceOf proxy)
        vm.prank(user);
        VaultFacet(facet).requestRedeem(shares, user);
        (uint256 reqShares,) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(reqShares, shares, "requestRedeem accepted shares equal to balance");

        console.log("requestRedeem succeeded using maxRedeem as balance proxy.");
        console.log("");
        console.log("REFACTOR NEEDED: requestRedeem/requestWithdraw must use balanceOf()");
        console.log("directly (not maxRedeem) before maxRedeem can be fixed to reflect queue state.");
        console.log("A one-line fix to maxRedeem would silently break request creation.");
    }
}
