// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C08 -- setReadChannel(_active=false) Orphans In-Flight GUIDs
 *
 * @notice Proves that LzAdapter.setReadChannel() unconditionally updates READ_CHANNEL
 *         regardless of the _active flag (LzAdapter.sol line 186):
 *
 *           function setReadChannel(uint32 _channelId, bool _active) ... {
 *               _setPeer(_channelId, _active ? AddressCast.toBytes32(address(this)) : bytes32(0));
 *               READ_CHANNEL = _channelId;  // <- always executes
 *           }
 *
 * BUG: setReadChannel(_channelId, false) is intended to DEACTIVATE a channel.
 * The call sets peer[_channelId] = bytes32(0), which is correct.
 * But it ALSO sets READ_CHANNEL = _channelId unconditionally.
 *
 * Consequence: READ_CHANNEL can silently shift to a channel whose peer is bytes32(0).
 * Any future call to initiateCrossChainAccounting sends on that deactivated channel.
 * LayerZero will not deliver responses on a channel with peer = bytes32(0).
 * GUIDs registered in _guidToCallInfo for accounting cycles sent after the shift
 * will never receive their _lzReceive callback -- they are permanently orphaned.
 *
 * THREE ORPHAN SCENARIOS:
 *
 * Scenario A -- Accidental pointer shift:
 *   READ_CHANNEL = CHAN_A. Admin calls setReadChannel(CHAN_B, false)
 *   intending to deactivate CHAN_B (no effect on CHAN_B because peer was already 0).
 *   READ_CHANNEL silently moves to CHAN_B. Future accounting uses CHAN_B (peer=0),
 *   permanently orphaning all future GUIDs.
 *
 * Scenario B -- Channel migration then cleanup:
 *   Admin migrates from CHAN_A to CHAN_B via setReadChannel(CHAN_B, true).
 *   Then deactivates old CHAN_A via setReadChannel(CHAN_A, false).
 *   BUG: READ_CHANNEL reverts from CHAN_B back to CHAN_A, and peer[CHAN_A]=0.
 *   All subsequent accounting sends use CHAN_A (peer=0) -> orphaned.
 *   In-flight GUIDs that were sent on CHAN_A (pre-migration) are also orphaned
 *   because peer[CHAN_A]=0 prevents LZ from delivering.
 *
 * Scenario C -- Self-deactivation of active channel:
 *   Admin calls setReadChannel(CHAN_A, false) on the currently active channel.
 *   peer[CHAN_A] = 0. READ_CHANNEL stays CHAN_A (pointer unchanged).
 *   All future sends use CHAN_A (no peer) -- orphaned. All in-flight GUIDs
 *   on CHAN_A also orphaned (LZ peer check fails).
 *
 * FIX (1 line):
 *   if (_active) { READ_CHANNEL = _channelId; }
 *   Only advance the READ_CHANNEL pointer when activating, not when deactivating.
 *
 * Tests:
 *   C08-01: setReadChannel(CHAN_B, false) changes READ_CHANNEL (BUG raw state)    -- PASS
 *   C08-02: Channel migration then cleanup reverts READ_CHANNEL to old channel    -- PASS
 *   C08-03: Self-deactivation of active channel orphans in-flight GUIDs           -- PASS
 *   C08-FIX: setReadChannel(false) should NOT change READ_CHANNEL                 -- FAIL without fix
 *
 * Run: forge test --match-contract TR_C08_SetReadChannelOrphans -vvvvv
 */

import {Test, console} from "forge-std/Test.sol";
import {LzAdapter} from "../../../src/cross-chain/layerZero/LzAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {
    MessagingReceipt,
    MessagingParams,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

// ---------------------------------------------------------------------------
// Minimal mock endpoint
// ---------------------------------------------------------------------------
contract MockEndpointC08 {
    uint32 public eid = 1;

    function setDelegate(address) external {}

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(0.01 ether, 0);
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory receipt) {
        receipt.guid = bytes32(uint256(0xC08));
        receipt.fee = MessagingFee(msg.value, 0);
    }

    // test helper to exclude from coverage
    function test_skip() external {}
}

// ---------------------------------------------------------------------------
// Minimal mock factory
// ---------------------------------------------------------------------------
contract MockFactoryC08 {
    function isFactoryVault(address) external pure returns (bool) {
        return true;
    }

    function isSpokeOfHub(uint32, address, uint32, address) external pure returns (bool) {
        return true;
    }

    function vaultComposer(address) external pure returns (address) {
        return address(0);
    }

    function localEid() external pure returns (uint32) {
        return 1;
    }

    // test helper to exclude from coverage
    function test_skip() external {}
}

// ---------------------------------------------------------------------------
// Harness: exposes _guidToCallInfo read/write for unit testing
// ---------------------------------------------------------------------------
contract LzAdapterHarnessC08 is LzAdapter {
    constructor(
        address _endpoint,
        address _delegate,
        uint32 _readChannel,
        address _factory,
        address _registry
    ) LzAdapter(_endpoint, _delegate, _readChannel, _factory, _registry) {}

    // Allows tests to plant a GUID as if initiateCrossChainAccounting had run
    function setCallInfo(bytes32 guid, address vault_, address initiator_) external {
        _guidToCallInfo[guid] = CallInfo({vault: vault_, initiator: initiator_});
    }

    // Allows tests to inspect stored GUID entries
    function getCallInfo(bytes32 guid) external view returns (address vault_, address initiator_) {
        CallInfo memory info = _guidToCallInfo[guid];
        return (info.vault, info.initiator);
    }

    // test helper to exclude from coverage
    function test_skip() external {}
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------
contract TR_C08_SetReadChannelOrphans is Test {
    LzAdapterHarnessC08 public adapter;

    address public owner = address(0x1);
    address public mockVault = address(0x2);
    address public initiator = address(0x3);

    uint32 constant CHAN_A = 1;  // initial read channel (set in constructor)
    uint32 constant CHAN_B = 99; // secondary channel for testing

    function setUp() public {
        MockEndpointC08 endpoint = new MockEndpointC08();
        MockFactoryC08 factory = new MockFactoryC08();
        address registry = makeAddr("registry");

        vm.prank(owner);
        adapter = new LzAdapterHarnessC08(
            address(endpoint),
            owner,
            CHAN_A, // initial read channel
            address(factory),
            registry
        );
    }

    // =========================================================================
    // C08-01: setReadChannel(_active=false) unconditionally changes READ_CHANNEL (BUG)
    //
    // LzAdapter.sol line 186: READ_CHANNEL = _channelId; -- no guard for _active
    //
    // Admin calls setReadChannel(CHAN_B, false) intending to deactivate CHAN_B
    // (which was never active -- peer[CHAN_B] was already bytes32(0)).
    // The intended effect: peer[CHAN_B] stays bytes32(0). No channel change.
    // The actual effect: READ_CHANNEL moves from CHAN_A to CHAN_B.
    //
    // After this call:
    //   - READ_CHANNEL = CHAN_B (broken -- should remain CHAN_A)
    //   - peers(CHAN_B) = bytes32(0) -- deactivated
    //   - Future initiateCrossChainAccounting sends on CHAN_B (no peer) -> orphaned
    // =========================================================================
    function test_C08_01_setReadChannel_false_changes_READ_CHANNEL() public {
        console.log("=================================================================");
        console.log("C08-01: setReadChannel(false) unconditionally changes READ_CHANNEL");
        console.log("=================================================================");

        // Verify initial state
        assertEq(adapter.READ_CHANNEL(), CHAN_A, "initial: READ_CHANNEL = CHAN_A");
        console.log("Initial READ_CHANNEL: CHAN_A =", adapter.READ_CHANNEL());

        // Admin calls setReadChannel(CHAN_B, false) -- intending to deactivate CHAN_B
        // Expected: READ_CHANNEL remains CHAN_A (CHAN_B was already inactive)
        // Actual:   READ_CHANNEL becomes CHAN_B (BUG: pointer moved unconditionally)
        console.log("Calling setReadChannel(CHAN_B=99, false)...");
        vm.prank(owner);
        adapter.setReadChannel(CHAN_B, false);

        uint32 readChannelAfter = adapter.READ_CHANNEL();
        bytes32 peerChanB = adapter.peers(CHAN_B);

        console.log("READ_CHANNEL after call:", readChannelAfter, "(expected: 1 = CHAN_A)");
        console.log("peers(CHAN_B):", uint256(peerChanB), "(should be 0 = deactivated)");

        // BUG: READ_CHANNEL changed to CHAN_B even though _active=false
        assertEq(readChannelAfter, CHAN_B, "BUG: READ_CHANNEL moved to CHAN_B on deactivation call");
        assertEq(peerChanB, bytes32(0), "peer[CHAN_B] = 0 (deactivated)");

        console.log("CONFIRMED: READ_CHANNEL = 99 (CHAN_B) after setReadChannel(99, false).");
        console.log("IMPACT: future initiateCrossChainAccounting sends on CHAN_B (peer=0).");
        console.log("        LZ will not deliver responses -> all future GUIDs orphaned.");
    }

    // =========================================================================
    // C08-02: Channel migration then deactivation of old channel reverts READ_CHANNEL
    //
    // This is the most dangerous scenario in practice:
    //   1. Admin migrates from CHAN_A to CHAN_B via setReadChannel(CHAN_B, true).
    //      After: READ_CHANNEL = CHAN_B (correct). peer[CHAN_B] = address(this).
    //   2. Admin cleans up by deactivating CHAN_A via setReadChannel(CHAN_A, false).
    //      After: READ_CHANNEL = CHAN_A (BUG! reverted from CHAN_B back to CHAN_A).
    //             peer[CHAN_A] = bytes32(0).
    //   3. In-flight GUIDs that were sent on CHAN_A (before migration) are now
    //      permanently stranded: peer[CHAN_A]=0 blocks LZ delivery.
    //   4. Future sends use CHAN_A (peer=0) -> also orphaned.
    // =========================================================================
    function test_C08_02_channel_migration_then_deactivation_reverts_READ_CHANNEL() public {
        console.log("=================================================================");
        console.log("C08-02: Channel migration + deactivation reverts READ_CHANNEL");
        console.log("=================================================================");

        // Plant an in-flight GUID representing an accounting cycle sent on CHAN_A
        bytes32 inFlightGuid = bytes32(uint256(0xDEAD));
        adapter.setCallInfo(inFlightGuid, mockVault, initiator);
        (address storedVault,) = adapter.getCallInfo(inFlightGuid);
        assertEq(storedVault, mockVault, "GUID planted in _guidToCallInfo");
        console.log("In-flight GUID planted for CHAN_A (pre-migration)");

        // Step 1: Admin migrates to CHAN_B (correct operation)
        vm.prank(owner);
        adapter.setReadChannel(CHAN_B, true);
        assertEq(adapter.READ_CHANNEL(), CHAN_B, "after activation: READ_CHANNEL = CHAN_B");
        assertNotEq(adapter.peers(CHAN_B), bytes32(0), "peer[CHAN_B] = address(this)");
        console.log("Step 1: activated CHAN_B. READ_CHANNEL =", adapter.READ_CHANNEL(), "(correct: 99)");

        // Step 2: Admin deactivates old CHAN_A (cleanup)
        // Expected: READ_CHANNEL stays CHAN_B, peer[CHAN_A] = 0
        // Actual:   READ_CHANNEL reverts to CHAN_A (BUG!)
        vm.prank(owner);
        adapter.setReadChannel(CHAN_A, false);
        bytes32 peerChanA = adapter.peers(CHAN_A);

        console.log("Step 2: deactivated CHAN_A. READ_CHANNEL =", adapter.READ_CHANNEL(), "(expected: 99, got: 1)");
        console.log("peers(CHAN_A) =", uint256(peerChanA), "(0 = deactivated, LZ will not deliver)");

        // BUG: READ_CHANNEL reverted from CHAN_B back to CHAN_A
        assertEq(adapter.READ_CHANNEL(), CHAN_A, "BUG: READ_CHANNEL reverted to CHAN_A after deactivation");
        assertEq(peerChanA, bytes32(0), "peer[CHAN_A] = 0 (deactivated)");

        // In-flight GUID on CHAN_A is now permanently stranded:
        // _guidToCallInfo still holds the entry (never processed), but
        // peer[CHAN_A] = 0 means LZ will never deliver the response to _lzReceive.
        (address vaultAfter,) = adapter.getCallInfo(inFlightGuid);
        assertEq(vaultAfter, mockVault, "GUID entry still in _guidToCallInfo (never processed)");

        console.log("CONFIRMED: READ_CHANNEL = 1 (CHAN_A) instead of 99 (CHAN_B).");
        console.log("In-flight GUID vault still set (orphaned -- LZ peer[CHAN_A]=0).");
        console.log("IMPACT: in-flight GUIDs on CHAN_A permanently stranded.");
        console.log("        Future sends use CHAN_A (peer=0) -> all future GUIDs also orphaned.");
    }

    // =========================================================================
    // C08-03: Self-deactivation of active channel orphans in-flight GUIDs
    //
    // Simplest orphan scenario:
    //   1. CHAN_A is active (READ_CHANNEL = CHAN_A, peer[CHAN_A] = address(this)).
    //   2. Admin calls setReadChannel(CHAN_A, false) -- perhaps to pause the channel.
    //      After: peer[CHAN_A] = 0 (LZ will not deliver on CHAN_A).
    //             READ_CHANNEL = CHAN_A (pointer unchanged).
    //   3. All in-flight GUIDs that were sent on CHAN_A before this call are
    //      permanently stranded: LZ will not deliver because peer[CHAN_A]=0.
    //   4. All future sends also fail: READ_CHANNEL=CHAN_A, but peer[CHAN_A]=0.
    //
    // Note: peer[CHAN_A] was address(this) when the GUIDs were sent, so the
    // read requests were dispatched correctly by LZ. But by the time LZ tries
    // to deliver, the peer has been removed -- the OApp rejects the delivery.
    // =========================================================================
    function test_C08_03_self_deactivation_orphans_inflight_GUIDs() public {
        console.log("=================================================================");
        console.log("C08-03: Self-deactivation of active channel orphans in-flight GUIDs");
        console.log("=================================================================");

        // Verify CHAN_A is active
        bytes32 peerBefore = adapter.peers(CHAN_A);
        assertNotEq(peerBefore, bytes32(0), "CHAN_A peer is set (active)");
        console.log("Initial: CHAN_A is active. peers(CHAN_A) != 0.");

        // Plant two in-flight GUIDs (simulating accounting cycles sent on CHAN_A)
        bytes32 guid1 = bytes32(uint256(0xAAA1));
        bytes32 guid2 = bytes32(uint256(0xAAA2));
        adapter.setCallInfo(guid1, mockVault, initiator);
        adapter.setCallInfo(guid2, mockVault, initiator);
        console.log("Two in-flight GUIDs planted (sent on CHAN_A before deactivation).");

        // Admin self-deactivates CHAN_A
        console.log("Calling setReadChannel(CHAN_A=1, false)...");
        vm.prank(owner);
        adapter.setReadChannel(CHAN_A, false);

        bytes32 peerAfter = adapter.peers(CHAN_A);
        assertEq(peerAfter, bytes32(0), "peer[CHAN_A] = 0 after deactivation");
        assertEq(adapter.READ_CHANNEL(), CHAN_A, "READ_CHANNEL unchanged (still CHAN_A)");

        console.log("After: peer[CHAN_A] = 0. READ_CHANNEL still = 1 (CHAN_A).");
        console.log("LZ verifies peer before calling _lzReceive.");
        console.log("peer[CHAN_A]=0 -> LZ rejects delivery -> _lzReceive never fires.");

        // Both GUIDs are now stranded: _guidToCallInfo has entries but LZ can't deliver
        (address v1,) = adapter.getCallInfo(guid1);
        (address v2,) = adapter.getCallInfo(guid2);
        assertEq(v1, mockVault, "GUID1 still in _guidToCallInfo (never cleaned up)");
        assertEq(v2, mockVault, "GUID2 still in _guidToCallInfo (never cleaned up)");

        console.log("CONFIRMED: Both GUIDs still in _guidToCallInfo (vault != address(0)).");
        console.log("peer[CHAN_A] = 0 -> LZ will not deliver -> vaults permanently waiting.");
        console.log("IMPACT: vault.updateAccountingInfoForRequest never called -> accounting frozen.");
        console.log("        Locked tokens (native + ERC20) never refunded.");
    }

    // =========================================================================
    // C08-FIX: setReadChannel(_active=false) should NOT change READ_CHANNEL
    //
    // Fix: if (_active) { READ_CHANNEL = _channelId; }
    // Only update the READ_CHANNEL pointer when activating, not when deactivating.
    //
    // With fix: setReadChannel(CHAN_B, false) leaves READ_CHANNEL = CHAN_A.
    // Without fix: READ_CHANNEL = CHAN_B -> vm.expectRevert fails -> test FAILS.
    // =========================================================================
    function test_C08_FIX_setReadChannel_false_preserves_READ_CHANNEL() public {
        console.log("=================================================================");
        console.log("C08-FIX: setReadChannel(false) should NOT change READ_CHANNEL");
        console.log("(FAILS without fix -- READ_CHANNEL will be CHAN_B instead of CHAN_A)");
        console.log("=================================================================");

        assertEq(adapter.READ_CHANNEL(), CHAN_A, "initial: READ_CHANNEL = CHAN_A");
        console.log("Initial READ_CHANNEL: CHAN_A =", adapter.READ_CHANNEL());

        vm.prank(owner);
        adapter.setReadChannel(CHAN_B, false);

        uint32 readChannelAfter = adapter.READ_CHANNEL();
        console.log("READ_CHANNEL after setReadChannel(CHAN_B, false):", readChannelAfter);
        console.log("Expected: 1 (CHAN_A, unchanged)");
        console.log("Without fix: 99 (CHAN_B) -> assertion fails -> test FAILS");

        // With fix: READ_CHANNEL must remain CHAN_A
        assertEq(readChannelAfter, CHAN_A, "FIX: READ_CHANNEL must remain CHAN_A after deactivation call"); // FAILS without fix
        assertEq(adapter.peers(CHAN_B), bytes32(0), "peers(CHAN_B) = 0 (correctly deactivated)");

        console.log("PASS: READ_CHANNEL correctly preserved after setReadChannel(false).");
    }
}
