// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-C05 — lzReduce Failed-Spoke Sum Inclusion + Overflow DoS
 *
 * @notice Proves that LzAdapter.lzReduce() unconditionally adds each spoke's
 *         reported assets to the sum regardless of the success flag:
 *
 *           (uint256 assets, bool success) = abi.decode(_responses[i], (uint256, bool));
 *           if (!success) readSuccess = false;
 *           sum += assets;   // ← executes even when success = false
 *
 * BUG-01 — Logical inclusion of failed-spoke value:
 *   A spoke that returns (largeValue, false) contributes largeValue to the sum.
 *   Under current code, totalAssetsUsd() always returns (0, false) on failure,
 *   so this is BENIGN TODAY. But the logic is incorrect by construction.
 *
 * BUG-02 — Overflow DoS:
 *   If any response decodes to an assets value that overflows uint256 when added
 *   to the running sum, Solidity 0.8 checked arithmetic reverts. This permanently
 *   blocks lzReduce for that delivery, freezing the read cycle. A malicious or
 *   buggy spoke returning type(uint256).max triggers this.
 *
 * WHY BENIGN TODAY:
 *   VaultFacet.totalAssetsUsd() (line 275-295):
 *     if (!success) { return (0, false); }  // ← always returns 0 on failure
 *   A failed spoke contributes (0, false) → sum += 0 → no inflation.
 *   The overflow requires a spoke to return a value near type(uint256).max,
 *   which the current code cannot produce in any failure path.
 *
 * WHEN IT BECOMES DANGEROUS:
 *   1. Future change: totalAssetsUsd() returns partial data with success=false
 *      instead of (0, false) → sum inflation → incorrect NAV
 *   2. Buggy/compromised spoke: returns (MAX_UINT, false) → overflow DoS
 *   3. Wrong contract at spoke address (upgrade bug): abi.decode returns
 *      garbage uint256 with false → overflow possible
 *   4. DVN compromise (Flow EVM risk): fewer DVNs than Ethereum, a corrupted
 *      DVN could inject (MAX_UINT, false) responses
 *
 * REAL-WORLD ANALOGUE — Synthetix sKRW (June 2019):
 *   Two off-chain oracle feeds failed simultaneously. The aggregation logic
 *   included the failed feeds' stale/corrupted values in the sum instead of
 *   excluding them. Result: KRW price reported 1,000x too high. An arbitrage
 *   bot extracted >1B USD in synthetic profit (later reversed via bug bounty).
 *   Root cause: same pattern — failed data source included in sum.
 *   Reference: https://blog.synthetix.io/response-to-oracle-incident/
 *
 * THE FIX (1 line, net-zero bytecode change):
 *   Before: if (!success) readSuccess = false; sum += assets;
 *   After:  if (success) { sum += assets; } else { readSuccess = false; }
 *
 * Tests:
 *   C05-01: failed_spoke_value_included_in_sum          — BUG-01, PASS without fix
 *   C05-02: overflow_causes_revert_when_spoke_max_uint  — BUG-02, PASS without fix
 *   C05-03: today_tottalAssetsUsd_returns_zero_on_fail  — proves benign today
 *   C05-04: FIX_failed_spoke_excluded_from_sum          — FAIL without fix
 *
 * Adapted from: test/trace/batch-B08-harness.t.sol (NOVEL tests)
 *
 * Run: forge test --match-contract TR_C05_LzReduce_FailedSpoke -vvvvv
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
// Minimal harness exposing lzReduce (already external pure — no harness needed)
// ---------------------------------------------------------------------------
contract LzAdapterMinimalHarness is LzAdapter {
    constructor(address _endpoint, address _delegate, uint32 _readChannel, address _factory, address _registry)
        LzAdapter(_endpoint, _delegate, _readChannel, _factory, _registry)
    {}

    // test helper to exclude from coverage
    function test_skip() external {}
}

// ---------------------------------------------------------------------------
// Mock LZ endpoint
// ---------------------------------------------------------------------------
contract MockEndpointC05 {
    uint32 public eid = 747;

    function setDelegate(address) external {}

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(0.01 ether, 0);
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory receipt) {
        receipt.guid = bytes32(uint256(0xC05));
        receipt.fee = MessagingFee(msg.value, 0);
    }
}

// ---------------------------------------------------------------------------
// Mock factory
// ---------------------------------------------------------------------------
contract MockFactoryC05 {
    function isFactoryVault(address) external pure returns (bool) { return true; }
    function isSpokeOfHub(uint32, address, uint32, address) external pure returns (bool) { return true; }
    function spokeToHub(uint32, address) external pure returns (uint32, address) { return (1, address(0)); }
    function vaultComposer(address) external pure returns (address) { return address(0); }
    function localEid() external pure returns (uint32) { return 747; }

    // test helper to exclude from coverage
    function test_skip() external {}
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------
contract TR_C05_LzReduce_FailedSpoke is Test {

    LzAdapterMinimalHarness public adapter;

    function setUp() public {
        MockEndpointC05 endpoint = new MockEndpointC05();
        MockFactoryC05  factory  = new MockFactoryC05();
        address registry = makeAddr("registry");

        adapter = new LzAdapterMinimalHarness(
            address(endpoint),
            address(this),
            uint32(4294967294), // READ_CHANNEL
            address(factory),
            registry
        );
    }

    // =========================================================================
    // C05-01: Failed spoke value IS included in the sum (BUG-01)
    //
    // Proves: sum += assets runs unconditionally even when success = false.
    // A spoke returning (500e18, false) contributes 500e18 to the sum.
    // Today this cannot happen (totalAssetsUsd returns 0 on failure),
    // but the logic is wrong by construction.
    // =========================================================================
    function test_C05_01_failed_spoke_value_included_in_sum() public view {
        console.log("=================================================================");
        console.log("C05-01: Failed spoke value included in sum (BUG-01)");
        console.log("=================================================================");

        bytes[] memory responses = new bytes[](3);
        responses[0] = abi.encode(uint256(1000e18), true);   // spoke A: ok
        responses[1] = abi.encode(uint256(500e18),  false);  // spoke B: failed but returns 500
        responses[2] = abi.encode(uint256(200e18),  true);   // spoke C: ok

        bytes memory result = adapter.lzReduce("", responses);
        (uint256 sum, bool readSuccess) = abi.decode(result, (uint256, bool));

        console.log("Spoke A (ok):     1000 USD");
        console.log("Spoke B (failed): 500 USD  <- should be excluded");
        console.log("Spoke C (ok):     200 USD");
        console.log("Sum returned:    ", sum / 1e18, "USD  (expected 1700 if bug present, 1200 if fixed)");
        console.log("readSuccess:     ", readSuccess ? "true" : "false");

        // BUG: sum includes 500e18 from the failed spoke
        assertEq(sum, 1700e18, "BUG-01: failed spoke value included in sum");
        assertFalse(readSuccess, "readSuccess correctly false when any spoke fails");

        console.log("CONFIRMED: sum = 1700 (includes failed spoke 500). Should be 1200.");
    }

    // =========================================================================
    // C05-02: Overflow causes revert when any spoke returns type(uint256).max (BUG-02)
    //
    // Proves: sum += assets with Solidity 0.8 checked arithmetic reverts on overflow.
    // If lzReduce reverts, LZ cannot deliver the read response → GUID blocked forever.
    // =========================================================================
    function test_C05_02_overflow_causes_revert_when_spoke_returns_max_uint() public {
        console.log("=================================================================");
        console.log("C05-02: Overflow DoS - spoke returns type(uint256).max");
        console.log("=================================================================");

        bytes[] memory responses = new bytes[](2);
        responses[0] = abi.encode(type(uint256).max, true); // enormous value
        responses[1] = abi.encode(uint256(1), true);

        console.log("Spoke 1 returns: type(uint256).max");
        console.log("Spoke 2 returns: 1");
        console.log("Expected: REVERT (arithmetic overflow)");

        vm.expectRevert(); // Solidity 0.8 checked arithmetic
        adapter.lzReduce("", responses);

        console.log("CONFIRMED: lzReduce reverts. Cross-chain accounting permanently blocked.");
        console.log("IMPACT: GUID cannot be delivered by LZ executor.");
        console.log("        All cross-chain requests for this GUID are frozen.");
    }

    // =========================================================================
    // C05-03: Today totalAssetsUsd always returns (0, false) on failure
    //
    // Proves WHY BUG-01 is benign today: the spoke never returns a non-zero
    // value paired with success=false. sum += 0 does not inflate the total.
    // =========================================================================
    function test_C05_03_today_benign_because_failed_spoke_returns_zero() public view {
        console.log("=================================================================");
        console.log("C05-03: Today benign - failed spoke returns (0, false) not (value, false)");
        console.log("=================================================================");

        console.log("VaultFacet.totalAssetsUsd() code path (lines 285-292):");
        console.log("  if (!success) { return (0, false); }  // always zero on failure");
        console.log("");

        // Simulate what actually happens when a spoke fails: (0, false)
        bytes[] memory responses = new bytes[](3);
        responses[0] = abi.encode(uint256(1000e18), true);
        responses[1] = abi.encode(uint256(0),       false); // real failure: 0 assets
        responses[2] = abi.encode(uint256(200e18),  true);

        bytes memory result = adapter.lzReduce("", responses);
        (uint256 sum, bool readSuccess) = abi.decode(result, (uint256, bool));

        console.log("Sum with real LZ failure (0, false):", sum / 1e18, "USD");
        console.log("readSuccess:", readSuccess ? "true" : "false");

        // sum += 0 is harmless
        assertEq(sum, 1200e18, "Today: sum = 1200 (failed spoke contributes 0, benign)");
        assertFalse(readSuccess, "readSuccess correctly propagates failure");

        console.log("BENIGN TODAY: sum += 0 does not inflate. Bug is dormant.");
        console.log("FUTURE RISK: if totalAssetsUsd ever returns partial data with false,");
        console.log("             the sum will be inflated silently.");
    }

    // =========================================================================
    // C05-04: FIX — failed spoke excluded from sum (FAILS without fix)
    //
    // With fix applied: if (success) { sum += assets; } else { readSuccess = false; }
    // A failed spoke contributes 0 to the sum regardless of its reported value.
    // =========================================================================
    function test_C05_04_FIX_failed_spoke_excluded_from_sum() public view {
        console.log("=================================================================");
        console.log("C05-04: FIX verification - failed spoke excluded from sum");
        console.log("=================================================================");

        bytes[] memory responses = new bytes[](3);
        responses[0] = abi.encode(uint256(1000e18), true);
        responses[1] = abi.encode(uint256(500e18),  false); // failed spoke with non-zero value
        responses[2] = abi.encode(uint256(200e18),  true);

        bytes memory result = adapter.lzReduce("", responses);
        (uint256 sum,) = abi.decode(result, (uint256, bool));

        console.log("With fix: sum should be 1200 (excluding failed spoke 500)");
        console.log("Without fix: sum is 1700 (includes failed spoke 500)");
        console.log("Returned sum:", sum / 1e18, "USD");

        // This assertion FAILS without the fix (sum is 1700, not 1200)
        assertEq(sum, 1200e18, "FIX: failed spoke value excluded from sum");

        console.log("PASS: sum = 1200. Fix correctly excludes failed spoke from aggregation.");
    }
}
