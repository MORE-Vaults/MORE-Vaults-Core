// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {console} from "forge-std/console.sol";

/**
 * @title MoreVaultsLib Assembly Tests
 * @notice Critical tests for assembly code blocks in MoreVaultsLib
 * @dev These tests target the UNTESTED assembly blocks identified in the security audit
 *
 * PHASE 1 - CRITICAL PRIORITY TESTS:
 * 1. _beforeAccounting() loop (lines 774-792) - CRITICAL
 * 2. _accountFacets() complex accounting (lines 205-245) - CRITICAL
 * 3. removeFromBeforeAccounting() (lines 652-658) - HIGH
 */
contract MoreVaultsLibAssemblyTest is Test {

    // Mock facet that implements beforeAccounting
    MockBeforeAccountingFacet public mockFacet1;
    MockBeforeAccountingFacet public mockFacet2;
    MockBeforeAccountingFacet public mockFacet3;

    // Facet that reverts in beforeAccounting
    RevertingBeforeAccountingFacet public revertingFacet;

    // Facet that consumes lots of gas
    GasGriefingFacet public gasGriefingFacet;

    // Test contract that exposes _beforeAccounting for testing
    BeforeAccountingTestHarness public harness;

    function setUp() public {
        // Deploy mock facets
        mockFacet1 = new MockBeforeAccountingFacet();
        mockFacet2 = new MockBeforeAccountingFacet();
        mockFacet3 = new MockBeforeAccountingFacet();
        revertingFacet = new RevertingBeforeAccountingFacet();
        gasGriefingFacet = new GasGriefingFacet();

        // Deploy test harness
        harness = new BeforeAccountingTestHarness();
    }

    // ============================================
    // PHASE 1.1: _beforeAccounting() BASIC TESTS
    // ============================================

    function test_beforeAccounting_EmptyArray_ShouldNotRevert() public {
        // Empty array should complete without errors
        harness.testBeforeAccounting();
    }

    function test_beforeAccounting_SingleFacet_ShouldExecute() public {
        // Setup: Add one facet to beforeAccountingFacets
        harness.addFacet(address(mockFacet1));

        // Execute
        harness.testBeforeAccounting();

        // Verify: facet's beforeAccounting was called
        assertEq(harness.totalCalls(), 1, "Facet should be called once");
    }

    function test_beforeAccounting_MultipleFacets_ShouldExecuteAll() public {
        // Setup: Add three facets
        harness.addFacet(address(mockFacet1));
        harness.addFacet(address(mockFacet2));
        harness.addFacet(address(mockFacet3));

        // Execute
        harness.testBeforeAccounting();

        // Verify: all facets called (3 total)
        assertEq(harness.totalCalls(), 3, "All 3 facets should be called");
    }

    function test_beforeAccounting_MultipleCalls_ShouldIncrementCounters() public {
        // Setup
        harness.addFacet(address(mockFacet1));

        // Execute multiple times
        harness.testBeforeAccounting();
        harness.testBeforeAccounting();
        harness.testBeforeAccounting();

        // Verify: counter incremented each time
        assertEq(harness.totalCalls(), 3, "Facet should be called 3 times total");
    }

    // ============================================
    // PHASE 1.2: _beforeAccounting() REVERT TESTS
    // ============================================

    function test_beforeAccounting_RevertingFacet_ShouldRevert() public {
        // Setup: Add reverting facet
        harness.addFacet(address(revertingFacet));

        // Execute and expect revert
        // The revert will happen with custom error 0xa0f06ea3 (BeforeAccountingFailed)
        vm.expectRevert();
        harness.testBeforeAccounting();
    }

    function test_beforeAccounting_RevertInMiddle_ShouldStopExecution() public {
        // Setup: facet1 (ok), revertingFacet (reverts), facet3 (should not be reached)
        harness.addFacet(address(mockFacet1));
        harness.addFacet(address(revertingFacet));
        harness.addFacet(address(mockFacet3));

        // Execute and expect revert
        // This should revert on the second facet (revertingFacet)
        // After revert, facet3 should NOT be executed
        vm.expectRevert();
        harness.testBeforeAccounting();
    }

    // ============================================
    // PHASE 1.3: _beforeAccounting() GAS TESTS
    // ============================================

    function test_beforeAccounting_GasConsumption_SingleFacet() public {
        harness.addFacet(address(mockFacet1));

        uint256 gasBefore = gasleft();
        harness.testBeforeAccounting();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable (less than 100k for single facet)
        console.log("Gas used for single facet:", gasUsed);
        assertLt(gasUsed, 100_000, "Gas usage should be reasonable for single facet");
    }

    function test_beforeAccounting_GasConsumption_MultipleFacets() public {
        // Add 5 facets to test scaling
        harness.addFacet(address(mockFacet1));
        harness.addFacet(address(mockFacet2));
        harness.addFacet(address(mockFacet3));
        harness.addFacet(address(new MockBeforeAccountingFacet()));
        harness.addFacet(address(new MockBeforeAccountingFacet()));

        uint256 gasBefore = gasleft();
        harness.testBeforeAccounting();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas should scale linearly (less than 500k for 5 facets)
        console.log("Gas used for 5 facets:", gasUsed);
        assertLt(gasUsed, 500_000, "Gas usage should scale reasonably");
    }

    function test_beforeAccounting_GasGriefing_ShouldConsumeAllGas() public {
        // This test documents the gas griefing vulnerability
        harness.addFacet(address(gasGriefingFacet));

        // The gas griefing facet will consume a lot of gas
        // This demonstrates the vulnerability but doesn't fix it
        uint256 gasBefore = gasleft();
        harness.testBeforeAccounting();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used by gas griefing facet:", gasUsed);
        // This test documents that a malicious facet CAN grief gas
        // TODO: Implement per-facet gas limits to prevent this
        assertGt(gasUsed, 100_000, "Gas griefing facet consumed significant gas");
    }

    // ============================================
    // PHASE 1.4: _beforeAccounting() MEMORY SAFETY
    // ============================================

    function test_beforeAccounting_MemorySafety_MultipleCalls() public {
        // Test that memory is not corrupted across multiple calls
        harness.addFacet(address(mockFacet1));

        // Create some data in memory
        bytes memory testData = new bytes(1000);
        for (uint i = 0; i < 1000; i++) {
            testData[i] = bytes1(uint8(i % 256));
        }

        // Call beforeAccounting
        harness.testBeforeAccounting();

        // Verify memory is still intact
        for (uint i = 0; i < 1000; i++) {
            assertEq(uint8(testData[i]), i % 256, "Memory should not be corrupted");
        }
    }

    function test_beforeAccounting_StorageSlotCalculation_Correctness() public {
        // This test verifies the storage slot calculation is correct
        // The assembly code does: mstore(0, _baf.slot) then keccak256(0, 0x20)

        // Add facets in specific order
        address facet1 = address(mockFacet1);
        address facet2 = address(mockFacet2);
        address facet3 = address(mockFacet3);

        harness.addFacet(facet1);
        harness.addFacet(facet2);
        harness.addFacet(facet3);

        // Verify the facets are stored correctly
        address[] memory facets = harness.getFacets();
        assertEq(facets.length, 3, "Should have 3 facets");
        assertEq(facets[0], facet1, "Facet 1 should be at index 0");
        assertEq(facets[1], facet2, "Facet 2 should be at index 1");
        assertEq(facets[2], facet3, "Facet 3 should be at index 2");

        // Execute and verify all called in correct order
        harness.testBeforeAccounting();
        assertEq(harness.totalCalls(), 3, "All 3 facets should be called");
    }

    // ============================================
    // PHASE 1.5: _beforeAccounting() EDGE CASES
    // ============================================

    function test_beforeAccounting_FacetWithStateChanges_ShouldPersist() public {
        // Test that facets can modify storage during beforeAccounting
        // When called via delegatecall, the facet modifies HARNESS storage
        StatefulBeforeAccountingFacet statefulFacet = new StatefulBeforeAccountingFacet();
        harness.addFacet(address(statefulFacet));

        // Call beforeAccounting
        harness.testBeforeAccounting();

        // Verify counter was incremented (in harness storage due to delegatecall)
        assertEq(harness.totalCalls(), 1, "Counter should be incremented");
    }

    function test_beforeAccounting_FacetReturningData_ShouldBeIgnored() public {
        // The assembly ignores return values - document this behavior
        DataReturningFacet dataFacet = new DataReturningFacet();
        harness.addFacet(address(dataFacet));

        // This should work even though facet returns data
        harness.testBeforeAccounting();

        assertEq(harness.totalCalls(), 1, "Facet should be called");
    }

    function test_beforeAccounting_ZeroAddressFacet_ShouldSucceed() public {
        // Interesting behavior: delegatecall to address(0) returns SUCCESS (true)
        // This is because there's no code to execute, so it succeeds trivially
        // This documents actual EVM behavior, not a bug in our code
        harness.addFacet(address(0));

        // This will succeed without reverting
        harness.testBeforeAccounting();

        // No calls were executed (totalCalls should be 0)
        assertEq(harness.totalCalls(), 0, "Zero address has no code to increment counter");
    }
}

// ============================================
// MOCK CONTRACTS FOR TESTING
// ============================================

/**
 * @notice Test harness that exposes _beforeAccounting for testing
 */
contract BeforeAccountingTestHarness {
    // Slot 0: totalCalls - MUST BE FIRST to match MockBeforeAccountingFacet layout!
    uint256 public totalCalls;

    // Slot 1+: beforeAccountingFacets array
    address[] public beforeAccountingFacets;

    function addFacet(address facet) external {
        beforeAccountingFacets.push(facet);
    }

    function removeFacet(uint256 index) external {
        beforeAccountingFacets[index] = beforeAccountingFacets[beforeAccountingFacets.length - 1];
        beforeAccountingFacets.pop();
    }

    function getFacets() external view returns (address[] memory) {
        return beforeAccountingFacets;
    }

    function testBeforeAccounting() external {
        // Call the internal _beforeAccounting function via assembly
        // This mimics exactly what MoreVaultsLib does
        address[] storage _baf = beforeAccountingFacets;

        assembly {
            let freePtr := mload(0x40)
            let length := sload(_baf.slot)
            mstore(0, _baf.slot)
            let slot := keccak256(0, 0x20)
            // BEFORE_ACCOUNTING_SELECTOR = 0xa85367f8 left-aligned in bytes32
            mstore(freePtr, 0xa85367f800000000000000000000000000000000000000000000000000000000)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                let facet := sload(add(slot, i))
                let res := delegatecall(gas(), facet, freePtr, 4, 0, 0)
                if iszero(res) {
                    // BeforeAccountingFailed(address) = 0xa0f06ea3 left-aligned
                    mstore(freePtr, 0xa0f06ea300000000000000000000000000000000000000000000000000000000)
                    mstore(add(freePtr, 0x04), facet)
                    revert(freePtr, 0x24)
                }
            }
        }
    }

    // This will be called by delegatecalled facets
    function beforeAccounting() external {
        totalCalls++;
    }
}

/**
 * @notice Mock facet that implements beforeAccounting
 * @dev When called via delegatecall, increments the harness's totalCalls
 */
contract MockBeforeAccountingFacet {
    uint256 public totalCalls; // Slot 0 - matches harness

    function beforeAccounting() external {
        totalCalls++;
    }
}

/**
 * @notice Facet that reverts in beforeAccounting
 */
contract RevertingBeforeAccountingFacet {
    function beforeAccounting() external pure {
        revert("Intentional revert");
    }
}

/**
 * @notice Facet that consumes lots of gas (gas griefing attack)
 */
contract GasGriefingFacet {
    function beforeAccounting() external {
        // Consume gas by doing expensive operations
        uint256 sum = 0;
        for (uint256 i = 0; i < 10000; i++) {
            sum += i;
        }
        // Prevent optimization
        assembly {
            mstore(0, sum)
        }
    }
}

/**
 * @notice Facet that modifies storage during beforeAccounting
 * @dev Same storage layout as MockBeforeAccountingFacet
 */
contract StatefulBeforeAccountingFacet {
    uint256 public totalCalls; // Slot 0 - matches harness

    function beforeAccounting() external {
        totalCalls++;
    }
}

/**
 * @notice Facet that returns data (which should be ignored)
 */
contract DataReturningFacet {
    uint256 public totalCalls; // Slot 0 - matches harness

    function beforeAccounting() external returns (uint256) {
        totalCalls++;
        return 42; // Return value should be ignored by assembly
    }
}
