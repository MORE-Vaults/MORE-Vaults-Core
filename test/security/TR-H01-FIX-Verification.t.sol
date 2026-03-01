// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-H01 Fix Verification: idempotency guard in updateAccountingInfoForRequest
 *
 * @notice Verifies the fix for TR-H01 (LZ Retry Inflates totalAssets).
 *
 * Fix applied in BridgeFacet.sol:
 *
 *   if (ds.guidToCrossChainRequestInfo[guid].fulfilled) {
 *       return;
 *   }
 *
 * This guard makes updateAccountingInfoForRequest idempotent once fulfilled=true.
 * It simultaneously fixes two bugs:
 *
 *   BUG 1 (totalAssets inflation):
 *     Before: retry called += again, inflating requestInfo.totalAssets
 *     After:  retry hits the guard and returns early — totalAssets unchanged
 *
 *   BUG 2 (fulfilled flag DOS):
 *     Before: false retry overwrote fulfilled=true back to false, blocking executeRequest
 *     After:  false retry hits the guard and returns early — fulfilled stays true
 *
 * Edge case preserved (correct behavior):
 *   - First call with readSuccess=false: fulfilled=false, guard NOT triggered.
 *     Request stays unfulfilled. A subsequent retry with readSuccess=true will
 *     proceed normally, set totalAssets, and mark fulfilled=true.
 *     This is the correct retry-after-failure path and must still work.
 */

import {Test, console} from "forge-std/Test.sol";
import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";

contract TR_H01_FIX_Verification is Test {

    address public lzManager = makeAddr("lzManager");
    address public registry  = makeAddr("registry");
    address public factory   = makeAddr("factory");
    address public oracleReg = makeAddr("oracleRegistry");

    BridgeFacet public bridgeFacet;
    MockERC20   public asset;

    uint256 constant HUB_ASSETS      = 1000e18;
    uint256 constant SPOKE_USD_VALUE = 200e18;
    bytes32 constant GUID = keccak256("fix-verify-guid");

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        asset = new MockERC20("Test USDC", "USDC");
        bridgeFacet = new BridgeFacet();

        MoreVaultsStorageHelper.setIsHub(address(bridgeFacet), true);
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(bridgeFacet), lzManager);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(bridgeFacet), registry);
        MoreVaultsStorageHelper.setFactory(address(bridgeFacet), factory);
        MoreVaultsStorageHelper.setUnderlyingAsset(address(bridgeFacet), address(asset));

        MoreVaultsStorageHelper.setCrossChainRequestInfo(
            address(bridgeFacet),
            GUID,
            makeAddr("initiator"),
            uint64(block.timestamp),
            uint8(MoreVaultsLib.ActionType.WITHDRAW),
            abi.encode(uint256(120e18), makeAddr("receiver"), makeAddr("owner")),
            HUB_ASSETS,
            0
        );

        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleReg));
        vm.mockCall(oracleReg, abi.encodeWithSignature("getAssetPrice(address)", address(asset)), abi.encode(uint256(1e18)));
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(747)));
    }

    function _getTotalAssets() internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35)));
        return uint256(vm.load(address(bridgeFacet), bytes32(uint256(slot) + 3)));
    }

    function _getFulfilled() internal view returns (bool) {
        bytes32 slot = keccak256(abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35)));
        bytes32 val = vm.load(address(bridgeFacet), bytes32(uint256(slot) + 2));
        return (uint256(val) & 0xff) != 0;
    }

    // =========================================================================
    // FIX-01: Retry after successful delivery does NOT inflate totalAssets
    // =========================================================================
    function test_FIX_retry_after_success_does_not_inflate_totalAssets() public {
        console.log("=================================================================");
        console.log("FIX-01: Retry after success does not inflate totalAssets");
        console.log("=================================================================");

        // Legitimate delivery
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAfterFirst = _getTotalAssets();
        bool fulfilledAfterFirst = _getFulfilled();

        console.log("After 1st delivery: totalAssets =", totalAfterFirst / 1e18, "USDC, fulfilled =", fulfilledAfterFirst);
        assertEq(totalAfterFirst, HUB_ASSETS + SPOKE_USD_VALUE, "totalAssets should be hub + spoke after 1st call");
        assertTrue(fulfilledAfterFirst, "fulfilled must be true after successful delivery");

        // LZ retry
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAfterRetry = _getTotalAssets();
        bool fulfilledAfterRetry = _getFulfilled();

        console.log("After retry:        totalAssets =", totalAfterRetry / 1e18, "USDC, fulfilled =", fulfilledAfterRetry);

        assertEq(totalAfterRetry, totalAfterFirst, "FIX CONFIRMED: retry must NOT change totalAssets");
        assertTrue(fulfilledAfterRetry, "fulfilled must remain true after retry");

        console.log("PASS: totalAssets unchanged after retry. No inflation.");
    }

    // =========================================================================
    // FIX-02: False retry does NOT overwrite fulfilled=true back to false (DOS fixed)
    // =========================================================================
    function test_FIX_false_retry_does_not_overwrite_fulfilled_flag() public {
        console.log("=================================================================");
        console.log("FIX-02: False retry does not overwrite fulfilled=true");
        console.log("=================================================================");

        // Legitimate delivery: fulfilled = true
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        assertTrue(_getFulfilled(), "fulfilled must be true after legitimate delivery");
        uint256 totalAfterSuccess = _getTotalAssets();

        // False retry (readSuccess=false) — previously overwrote fulfilled=true to false (DOS)
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, 0, false);

        bool fulfilledAfterFalseRetry = _getFulfilled();
        uint256 totalAfterFalseRetry = _getTotalAssets();

        console.log("fulfilled after false retry:", fulfilledAfterFalseRetry);
        console.log("totalAssets after false retry:", totalAfterFalseRetry / 1e18, "USDC");

        assertTrue(fulfilledAfterFalseRetry,
            "FIX CONFIRMED: fulfilled must remain true after false retry (no DOS)");
        assertEq(totalAfterFalseRetry, totalAfterSuccess,
            "FIX CONFIRMED: totalAssets must not change on false retry");

        console.log("PASS: fulfilled stays true. executeRequest can proceed. DOS fixed.");
    }

    // =========================================================================
    // FIX-03: N retries are all no-ops — profit does not scale with N
    // =========================================================================
    function test_FIX_n_retries_all_noop() public {
        console.log("=================================================================");
        console.log("FIX-03: N retries are all no-ops after first success");
        console.log("=================================================================");

        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAfterFirst = _getTotalAssets();

        for (uint256 n = 1; n <= 5; n++) {
            vm.prank(lzManager);
            bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

            uint256 current = _getTotalAssets();
            assertEq(current, totalAfterFirst,
                "FIX CONFIRMED: retry must be a no-op, totalAssets unchanged");
            console.log("After retry %d: totalAssets still = %d USDC (no-op confirmed)", n, current / 1e18);
        }

        console.log("PASS: 5 retries all no-ops. N-retry profit amplification eliminated.");
    }

    // =========================================================================
    // FIX-04: First failed read then successful retry still works correctly
    //
    // This is the critical edge case: a legitimate retry after a failed first
    // delivery must still be able to fulfill the request. The guard must NOT
    // block this path (fulfilled starts as false on first failed call).
    // =========================================================================
    function test_FIX_failed_first_then_success_retry_still_fulfills() public {
        console.log("=================================================================");
        console.log("FIX-04: Failed first read + successful retry still works");
        console.log("=================================================================");

        // First delivery fails (readSuccess=false)
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, 0, false);

        bool fulfilledAfterFail = _getFulfilled();
        uint256 totalAfterFail = _getTotalAssets();

        console.log("After failed 1st call: fulfilled =", fulfilledAfterFail, ", totalAssets =", totalAfterFail / 1e18);
        assertFalse(fulfilledAfterFail, "fulfilled must be false after failed delivery");
        assertEq(totalAfterFail, HUB_ASSETS, "totalAssets must not change on failed delivery");

        // Retry succeeds (readSuccess=true)
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        bool fulfilledAfterRetry = _getFulfilled();
        uint256 totalAfterRetry = _getTotalAssets();

        console.log("After successful retry: fulfilled =", fulfilledAfterRetry, ", totalAssets =", totalAfterRetry / 1e18);
        assertTrue(fulfilledAfterRetry, "fulfilled must be true after successful retry");
        assertEq(totalAfterRetry, HUB_ASSETS + SPOKE_USD_VALUE,
            "totalAssets must be hub + spoke after successful retry");

        console.log("PASS: Failed first + successful retry works correctly.");
        console.log("The fix does not block legitimate retry-after-failure paths.");
    }
}
