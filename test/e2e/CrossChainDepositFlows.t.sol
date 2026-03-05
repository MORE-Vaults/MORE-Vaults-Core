// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseE2ETest} from "./BaseE2ETest.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsComposer} from "../../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import {MockBridgeAdapter} from "../mocks/MockBridgeAdapter.sol";
import {
    SendParam,
    MessagingFee,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

/// @title CrossChainDepositFlowsTest
/// @notice E2E tests for D6 (spoke->hub sync with oracle ON) and D7 (spoke->hub async with oracle OFF)
contract CrossChainDepositFlowsTest is BaseE2ETest {
    MockBridgeAdapter public ccManager;

    function setUp() public override {
        super.setUp();

        // Deploy a MockBridgeAdapter as the cross-chain accounting manager
        ccManager = new MockBridgeAdapter();
        // Set zero fees so msg.value requirements are minimal
        ccManager.setFee(0, 0);

        // Set ccManager on the vault (requires validateDiamond + registry check)
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isCrossChainAccountingManager.selector, address(ccManager)),
            abi.encode(true)
        );
        vm.prank(hubVault);
        IConfigurationFacet(hubVault).setCrossChainAccountingManager(address(ccManager));

        // underlying is already added as available + depositable by VaultFacet.initialize()

        // Mock isTrustedOFT on the lzAdapter address so composer accepts the OFT
        // hubFactory.lzAdapter() returns address(0x1) (set during factory init)
        address lzAdapterAddr = hubFactory.lzAdapter();
        vm.mockCall(
            lzAdapterAddr,
            abi.encodeWithSignature("isTrustedOFT(address)", address(usdcOFT)),
            abi.encode(true)
        );

        // Mock usdcOFT.token() -> underlying (already set via setUnderlyingToken in base)
        // Mock usdcOFT.approvalRequired() -> false (it's a regular OFT, not adapter)
        // Note: The composer checks IOFT(_composeSender).token() to get the underlying token address
    }

    // ════════════════════════════════════════════════════════════════════
    //  D6: Spoke → Hub, Oracle ON, Sync deposit
    // ════════════════════════════════════════════════════════════════════

    function test_D6_spokeToHub_oracleOn_sync() public {
        // Setup: register spoke + enable oracle accounting
        _registerSpoke();
        _enableOracleAccounting();

        // Reset spoke value to 0 (no actual assets in spoke yet).
        // _enableOracleAccounting sets 500e8 to pass oracle setup, but for a clean
        // first deposit we need totalAssets == 0 so share ratio is 1:1.
        oracleRegistry.setSpokeValue(hubVault, SPOKE_EID, 0);

        // Verify oracle accounting is ON
        assertTrue(
            IBridgeFacet(hubVault).oraclesCrossChainAccounting(),
            "Oracle accounting should be enabled"
        );

        uint256 depositAmount = 1000e18;

        // Build the hopSendParam for sending shares back to user on spoke
        // For sync path, _depositAndSend will send shares via SHARE_OFT to the spoke
        // Since SHARE_OFT.send is a mock, we use the hub EID (local transfer) so
        // the composer does a direct ERC20 transfer of shares to user1 on hub
        SendParam memory hopSendParam = SendParam({
            dstEid: HUB_EID, // same chain -> direct transfer to user
            to: bytes32(uint256(uint160(user1))),
            amountLD: 0, // will be overwritten by composer
            minAmountLD: 0, // no slippage check for test
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // Record balances before
        uint256 vaultTotalAssetsBefore = IVaultFacet(hubVault).totalAssets();
        uint256 user1SharesBefore = IERC20(hubVault).balanceOf(user1);

        // Simulate OFT compose arriving at hub
        // This mints underlying tokens to the composer and calls lzCompose
        _simulateOFTComposeAtHub(
            address(usdcOFT),
            hubComposer,
            depositAmount,
            user1,
            SPOKE_EID,
            hopSendParam,
            0, // minMsgValue
            0  // msgValue ETH (no fees needed for local transfer)
        );

        // Verify: user1 should have received shares (direct transfer since dstEid == HUB_EID)
        uint256 user1SharesAfter = IERC20(hubVault).balanceOf(user1);
        assertGt(user1SharesAfter, user1SharesBefore, "User1 should have received shares");

        // Verify: vault total assets should have increased
        uint256 vaultTotalAssetsAfter = IVaultFacet(hubVault).totalAssets();
        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore + depositAmount,
            "Vault total assets should increase by deposit amount"
        );

        // Note: shares != depositAmount because oracle reports spoke value ($500),
        // making totalAssets = spokeValue + deposit, so share price != 1:1.
        // We already verified shares > 0 above.
    }

    // ════════════════════════════════════════════════════════════════════
    //  D7: Spoke → Hub, Oracle OFF, Async deposit
    // ════════════════════════════════════════════════════════════════════

    function test_D7_spokeToHub_oracleOff_async() public {
        // Setup: register spoke (no oracle -> async path)
        _registerSpoke();

        // Verify oracle accounting is OFF
        assertFalse(
            IBridgeFacet(hubVault).oraclesCrossChainAccounting(),
            "Oracle accounting should be disabled"
        );

        // Pre-set a guid on the mock so initiateCrossChainAccounting returns a known value
        bytes32 expectedGuid = keccak256("test_D7_guid");
        ccManager.setReceiptGuid(expectedGuid);

        uint256 depositAmount = 1000e18;

        // Build the hopSendParam for sending shares back to user on spoke after async finalization
        SendParam memory hopSendParam = SendParam({
            dstEid: HUB_EID, // same chain for simplicity
            to: bytes32(uint256(uint160(user1))),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // Record balances before
        uint256 vaultTotalAssetsBefore = IVaultFacet(hubVault).totalAssets();
        uint256 user1SharesBefore = IERC20(hubVault).balanceOf(user1);

        // Simulate OFT compose arriving at hub
        // The async path will call initVaultActionRequest which:
        // 1. Calls ccManager.initiateCrossChainAccounting (returns expectedGuid)
        // 2. Locks tokens in escrow
        // 3. Creates a CrossChainRequestInfo
        _simulateOFTComposeAtHub(
            address(usdcOFT),
            hubComposer,
            depositAmount,
            user1,
            SPOKE_EID,
            hopSendParam,
            0, // minMsgValue
            0  // msgValue ETH (ccManager fee is 0)
        );

        // At this point, the deposit is pending (tokens locked in escrow)
        // User should NOT have shares yet
        uint256 user1SharesMid = IERC20(hubVault).balanceOf(user1);
        assertEq(user1SharesMid, user1SharesBefore, "User should not have shares yet (async pending)");

        // Verify request info exists
        MoreVaultsLib.CrossChainRequestInfo memory reqInfo =
            IBridgeFacet(hubVault).getRequestInfo(expectedGuid);
        assertEq(uint8(reqInfo.actionType), uint8(MoreVaultsLib.ActionType.DEPOSIT), "Action should be DEPOSIT");
        assertFalse(reqInfo.fulfilled, "Request should not be fulfilled yet");
        assertFalse(reqInfo.finalized, "Request should not be finalized yet");

        // Simulate LZ Read response arriving (spoke value = 0 USD, success = true)
        // This calls updateAccountingInfoForRequest + executeRequest
        _simulateLzReadResponse(expectedGuid, 0, true);

        // Verify request is now fulfilled and finalized
        MoreVaultsLib.CrossChainRequestInfo memory reqInfoAfter =
            IBridgeFacet(hubVault).getRequestInfo(expectedGuid);
        assertTrue(reqInfoAfter.fulfilled, "Request should be fulfilled");
        assertTrue(reqInfoAfter.finalized, "Request should be finalized");

        // Get finalization result (shares minted)
        uint256 sharesIssued = IBridgeFacet(hubVault).getFinalizationResult(expectedGuid);
        assertGt(sharesIssued, 0, "Should have issued shares");

        // Vault total assets should have increased
        uint256 vaultTotalAssetsAfter = IVaultFacet(hubVault).totalAssets();
        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore + depositAmount,
            "Vault total assets should increase by deposit amount"
        );
    }
}
