// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseE2ETest} from "./BaseE2ETest.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockCCManager as MockCCManagerRedeem} from "../mocks/MockCCManager.sol";

contract RedeemFlowsTest is BaseE2ETest {
    MockCCManagerRedeem internal ccManager;

    function setUp() public override {
        super.setUp();
        ccManager = new MockCCManagerRedeem();
        // ERC20 selectors (approve, transfer, transferFrom, allowance) are already
        // registered in BaseE2ETest._getVaultFacetSelectors() — no diamondCut needed.
    }

    // ================================================================
    //  R1 -- Hub simple redeem (no queue, redeem by shares)
    // ================================================================
    function test_R1_simpleRedeem() public {
        uint256 shares = _giveShares(user1, 1000e18);

        // The asset must be in availableAssets so the vault knows its price.
        // underlying is already added during VaultFacet.initialize, so this
        // would revert with AssetAlreadyAvailable.  Skip the call.

        vm.prank(user1);
        uint256 assets = IVaultFacet(hubVault).redeem(shares, user1, user1);

        assertGt(assets, 0, "R1: redeemed assets must be > 0");
        assertEq(IERC20(address(underlying)).balanceOf(user1), assets, "R1: user1 underlying balance mismatch");
        assertEq(IERC20(hubVault).balanceOf(user1), 0, "R1: user1 should have 0 shares after full redeem");
    }

    // ================================================================
    //  R2 -- Hub simple withdraw (no queue, withdraw by assets)
    // ================================================================
    function test_R2_simpleWithdraw() public {
        _giveShares(user1, 1000e18);

        vm.prank(user1);
        uint256 sharesBurned = IVaultFacet(hubVault).withdraw(900e18, user1, user1);

        assertGt(sharesBurned, 0, "R2: shares burned must be > 0");
        assertEq(
            IERC20(address(underlying)).balanceOf(user1),
            900e18,
            "R2: user1 should have received 900e18 underlying"
        );
    }

    // ================================================================
    //  R3 -- Hub with queue ON, no timelock (request + immediate redeem)
    // ================================================================
    function test_R3_queueRedeem_noTimelock() public {
        _enableWithdrawalQueue(0); // queue ON, zero timelock
        uint256 shares = _giveShares(user1, 1000e18);

        // TX 1: user creates withdrawal request
        vm.prank(user1);
        IVaultFacet(hubVault).requestRedeem(shares, user1);

        // Verify request was created
        (uint256 reqShares, uint256 timelockEndsAt) = IVaultFacet(hubVault).getWithdrawalRequest(user1);
        assertEq(reqShares, shares, "R3: request shares mismatch");
        // timelockEndsAt == block.timestamp (zero duration timelock)
        assertEq(timelockEndsAt, block.timestamp, "R3: timelock should end at current timestamp");

        // TX 2: redeem immediately (no timelock wait needed)
        vm.prank(user1);
        uint256 assets = IVaultFacet(hubVault).redeem(shares, user1, user1);

        assertGt(assets, 0, "R3: redeemed assets must be > 0");
        assertEq(IERC20(address(underlying)).balanceOf(user1), assets, "R3: user1 underlying balance mismatch");
    }

    // ================================================================
    //  R4 -- Hub with queue ON, timelock = 1 day
    // ================================================================
    function test_R4_queueRedeem_withTimelock() public {
        _enableWithdrawalQueue(1 days);
        uint256 shares = _giveShares(user1, 1000e18);

        // TX 1: user creates withdrawal request
        vm.prank(user1);
        IVaultFacet(hubVault).requestRedeem(shares, user1);

        // Verify timelock
        (, uint256 timelockEndsAt) = IVaultFacet(hubVault).getWithdrawalRequest(user1);
        assertEq(timelockEndsAt, block.timestamp + 1 days, "R4: timelock end mismatch");

        // Attempt to redeem before timelock expires -- must revert
        vm.prank(user1);
        vm.expectRevert();
        IVaultFacet(hubVault).redeem(shares, user1, user1);

        // Advance time past the timelock
        vm.warp(block.timestamp + 1 days + 1);

        // TX 2: redeem succeeds after timelock
        vm.prank(user1);
        uint256 assets = IVaultFacet(hubVault).redeem(shares, user1, user1);

        assertGt(assets, 0, "R4: redeemed assets must be > 0");
        assertEq(IERC20(address(underlying)).balanceOf(user1), assets, "R4: user1 underlying balance mismatch");
    }

    // ================================================================
    //  R5 -- Hub cross-chain, oracle OFF, async redeem via LZ Read
    // ================================================================
    function test_R5_crossChainOracleOff_redeem_async() public {
        // Give shares BEFORE registering spoke (sync deposit only works without cross-chain)
        uint256 shares = _giveShares(user1, 1000e18);

        _registerSpoke(); // register spoke on hub -- makes isCrossChainVault = true

        // Set cross-chain accounting manager (requires validateDiamond + registry check)
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isCrossChainAccountingManager.selector, address(ccManager)),
            abi.encode(true)
        );
        vm.prank(hubVault);
        IConfigurationFacet(hubVault).setCrossChainAccountingManager(address(ccManager));

        // User approves escrow to pull vault shares
        vm.prank(user1);
        IERC20(hubVault).approve(address(escrow), shares);

        // TX 1: initVaultActionRequest(REDEEM)
        // actionCallData = abi.encode(shares, receiver, owner)
        bytes memory callData = abi.encode(shares, user1, user1);
        vm.prank(user1);
        bytes32 guid = IBridgeFacet(hubVault).initVaultActionRequest(
            MoreVaultsLib.ActionType.REDEEM,
            callData,
            0, // amountLimit = minAssetsOut for REDEEM (0 = no slippage check)
            ""
        );

        // Verify request created
        MoreVaultsLib.CrossChainRequestInfo memory info = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertEq(info.initiator, user1, "R5: initiator mismatch");
        assertFalse(info.fulfilled, "R5: request should not be fulfilled yet");
        assertFalse(info.finalized, "R5: request should not be finalized yet");
        assertEq(uint8(info.actionType), uint8(MoreVaultsLib.ActionType.REDEEM), "R5: action type mismatch");

        // Shares should now be locked in escrow
        assertEq(escrow.getLockedShares(hubVault, user1), shares, "R5: escrow locked shares mismatch");

        // Simulate LZ Read response (spoke has 0 assets)
        _simulateLzReadResponse(guid, 0, true);

        // Verify user received underlying assets
        uint256 userUnderlying = IERC20(address(underlying)).balanceOf(user1);
        assertGt(userUnderlying, 0, "R5: user1 should have received underlying assets");

        // Verify finalization
        MoreVaultsLib.CrossChainRequestInfo memory finalInfo = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertTrue(finalInfo.finalized, "R5: request should be finalized");
    }

    // ================================================================
    //  R6 -- Spoke-to-hub redeem (DOCUMENTED ONLY)
    // ================================================================
    //
    // R6: User on a spoke chain wants to redeem shares for underlying assets on the hub.
    //
    // FLOW (NOT DIRECTLY SUPPORTED AS A SINGLE TX):
    //
    // Step 1 (spoke): User approves shareOFT for bridging their shares to the hub chain.
    // Step 2 (spoke): User calls OFTAdapter.send() to transfer shares to the hub via LayerZero.
    // Step 3 (hub, automatic): LayerZero delivers shares to the user's address on the hub chain.
    // Step 4 (hub): User calls redeem() on the hub vault with the received shares.
    //
    // UX Cost: 2 user TXs on spoke + LZ bridging wait + 1 user TX on hub = 3 TXs total.
    // The user needs gas on BOTH chains (spoke for bridging, hub for redeeming).
    //
    // This flow is not tested because it involves real cross-chain OFT bridging
    // and multi-chain user interactions that cannot be simulated in a single-chain
    // Foundry test without significant mock infrastructure beyond our scope.
}
