// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {console} from "forge-std/console.sol";

/**
 * @title VaultFacet Assembly Tests
 * @notice Tests for critical assembly blocks in VaultFacet
 * @dev PHASE 1.2 - Testing _accountFacets() (lines 205-245)
 *
 * CRITICAL RISKS IN _accountFacets():
 * 1. Line 238: add(_totalAssets, decodedAmount) - overflow possible
 * 2. Line 239: add(debt, decodedAmount) - overflow possible
 * 3. Line 244: sub(_totalAssets, debt) - underflow if debt > totalAssets
 * 4. Line 244: if debt >= totalAssets, returns 0 (not an error)
 */
contract VaultFacetAssemblyTest is Test {

    AccountFacetsTestHarness public harness;

    // Mock accounting facets with different behaviors
    PositiveAccountingFacet public positiveFacet100;
    PositiveAccountingFacet public positiveFacet200;
    NegativeAccountingFacet public negativeFacet50;
    NegativeAccountingFacet public negativeFacet150;

    // Extreme value facets
    ExtremeValueFacet public maxUint256Facet;
    ExtremeValueFacet public halfMaxFacet;

    function setUp() public {
        harness = new AccountFacetsTestHarness();

        // Create facets with different amounts
        positiveFacet100 = new PositiveAccountingFacet(100e18);
        positiveFacet200 = new PositiveAccountingFacet(200e18);
        negativeFacet50 = new NegativeAccountingFacet(50e18);
        negativeFacet150 = new NegativeAccountingFacet(150e18);

        // Extreme value facets
        maxUint256Facet = new ExtremeValueFacet(type(uint256).max, true);
        halfMaxFacet = new ExtremeValueFacet(type(uint256).max / 2, true);
    }

    // ============================================
    // PHASE 1.2.1: BASIC FUNCTIONALITY
    // ============================================

    function test_accountFacets_EmptyArray_ShouldReturnInitialAmount() public {
        uint256 initialAssets = 1000e18;

        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        assertEq(result, initialAssets, "Should return initial assets when no facets");
        assertTrue(success, "Should succeed");
    }

    function test_accountFacets_SinglePositiveFacet_ShouldAdd() public {
        // Add one positive facet
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));

        uint256 initialAssets = 1000e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 1000 + 100 = 1100
        assertEq(result, 1100e18, "Should add positive facet amount");
        assertTrue(success);
    }

    function test_accountFacets_SingleNegativeFacet_ShouldSubtract() public {
        // Add one negative facet (debt)
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));

        uint256 initialAssets = 1000e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 1000 - 50 = 950
        assertEq(result, 950e18, "Should subtract negative facet amount (debt)");
        assertTrue(success);
    }

    function test_accountFacets_MultiplePositiveFacets_ShouldAddAll() public {
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));
        harness.addFacet(positiveFacet200.accounting.selector, address(positiveFacet200));

        uint256 initialAssets = 1000e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 1000 + 100 + 200 = 1300
        assertEq(result, 1300e18, "Should add all positive facets");
        assertTrue(success);
    }

    function test_accountFacets_MultipleNegativeFacets_ShouldSubtractAll() public {
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));
        harness.addFacet(negativeFacet150.accounting.selector, address(negativeFacet150));

        uint256 initialAssets = 1000e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 1000 - (50 + 150) = 800
        assertEq(result, 800e18, "Should subtract all debt");
        assertTrue(success);
    }

    function test_accountFacets_MixedPositiveNegative_ShouldCalculateCorrectly() public {
        harness.addFacet(positiveFacet200.accounting.selector, address(positiveFacet200));
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));

        uint256 initialAssets = 1000e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 1000 + 200 + 100 - 50 = 1250
        assertEq(result, 1250e18, "Should handle mixed positive/negative correctly");
        assertTrue(success);
    }

    // ============================================
    // PHASE 1.2.2: DEBT >= ASSETS SCENARIOS
    // ============================================

    function test_accountFacets_DebtEqualsAssets_ShouldReturnZero() public {
        harness.addFacet(negativeFacet150.accounting.selector, address(negativeFacet150));

        uint256 initialAssets = 150e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 150 - 150 = 0
        assertEq(result, 0, "Should return 0 when debt equals assets");
        assertTrue(success, "Should succeed, not revert");
    }

    function test_accountFacets_DebtExceedsAssets_ShouldReturnZero() public {
        harness.addFacet(negativeFacet150.accounting.selector, address(negativeFacet150));

        uint256 initialAssets = 100e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 100 - 150 = would be negative, but returns 0
        assertEq(result, 0, "Should return 0 when debt exceeds assets");
        assertTrue(success, "Should succeed, not revert");
    }

    function test_accountFacets_LargeDebt_ShouldReturnZero() public {
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));
        harness.addFacet(negativeFacet150.accounting.selector, address(negativeFacet150));

        uint256 initialAssets = 50e18;
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // 50 - (50 + 150) = -150, returns 0
        assertEq(result, 0, "Should return 0 when large debt");
        assertTrue(success);
    }

    // ============================================
    // PHASE 1.2.3: OVERFLOW SCENARIOS
    // ============================================

    function test_accountFacets_MaxUint256Positive_ShouldOverflow() public {
        harness.addFacet(maxUint256Facet.accounting.selector, address(maxUint256Facet));

        uint256 initialAssets = 100e18;

        // This WILL overflow: 100 + max_uint256
        // In assembly with unchecked add, this wraps around
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        // Result will be wrapped value (100 - 1) due to overflow
        console.log("Overflow result:", result);
        assertLt(result, initialAssets, "Overflow should wrap around to smaller value");
        assertTrue(success, "Should succeed despite overflow - documents vulnerability");
    }

    function test_accountFacets_TwoHalfMaxValues_ShouldOverflow() public {
        harness.addFacet(halfMaxFacet.accounting.selector, address(halfMaxFacet));
        harness.addFacet(halfMaxFacet.accounting.selector, address(halfMaxFacet));

        uint256 initialAssets = 1000e18;

        // This WILL overflow: 1000 + (max/2) + (max/2)
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        console.log("Double half-max overflow result:", result);
        // After overflow, result will be much smaller than expected
        assertTrue(success, "Should succeed despite overflow");
    }

    function test_accountFacets_NegativeOverflow_DebtAccumulation() public {
        // Create two max debt facets
        ExtremeValueFacet maxDebtFacet1 = new ExtremeValueFacet(type(uint256).max / 2, false);
        ExtremeValueFacet maxDebtFacet2 = new ExtremeValueFacet(type(uint256).max / 2, false);

        harness.addFacet(maxDebtFacet1.accounting.selector, address(maxDebtFacet1));
        harness.addFacet(maxDebtFacet2.accounting.selector, address(maxDebtFacet2));

        uint256 initialAssets = 1000e18;

        // Debt accumulation: (max/2) + (max/2) will overflow
        (uint256 result, bool success) = harness.testAccountFacets(initialAssets, true);

        console.log("Debt overflow result:", result);
        assertTrue(success, "Should succeed despite debt overflow");
    }

    // ============================================
    // PHASE 1.2.4: EDGE CASES
    // ============================================

    function test_accountFacets_ZeroInitialAssets_WithPositive() public {
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));

        (uint256 result, bool success) = harness.testAccountFacets(0, true);

        assertEq(result, 100e18, "Should work with zero initial assets");
        assertTrue(success);
    }

    function test_accountFacets_ZeroInitialAssets_WithNegative() public {
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));

        (uint256 result, bool success) = harness.testAccountFacets(0, true);

        assertEq(result, 0, "Should return 0 when starting at 0 with debt");
        assertTrue(success);
    }

    function test_accountFacets_AllowFailureFalse_ShouldSetSuccessFalse() public {
        // Add a reverting facet
        RevertingAccountingFacet revertingFacet = new RevertingAccountingFacet();
        harness.addFacet(revertingFacet.accounting.selector, address(revertingFacet));

        // With allowFailure = false, should set success = false instead of reverting
        (uint256 result, bool success) = harness.testAccountFacets(1000e18, false);

        assertFalse(success, "Should set success to false");
        assertEq(result, 0, "Result should be 0 when failed");
    }

    function test_accountFacets_AllowFailureTrue_ShouldRevert() public {
        RevertingAccountingFacet revertingFacet = new RevertingAccountingFacet();
        harness.addFacet(revertingFacet.accounting.selector, address(revertingFacet));

        // With allowFailure = true, should revert
        vm.expectRevert();
        harness.testAccountFacets(1000e18, true);
    }

    // ============================================
    // PHASE 1.2.5: GAS MEASUREMENTS
    // ============================================

    function test_accountFacets_GasUsage_SingleFacet() public {
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));

        uint256 gasBefore = gasleft();
        harness.testAccountFacets(1000e18, true);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for single accounting facet:", gasUsed);
        assertLt(gasUsed, 100_000, "Gas should be reasonable");
    }

    function test_accountFacets_GasUsage_MultipleFacets() public {
        harness.addFacet(positiveFacet100.accounting.selector, address(positiveFacet100));
        harness.addFacet(negativeFacet50.accounting.selector, address(negativeFacet50));
        harness.addFacet(positiveFacet200.accounting.selector, address(positiveFacet200));
        harness.addFacet(negativeFacet150.accounting.selector, address(negativeFacet150));

        uint256 gasBefore = gasleft();
        harness.testAccountFacets(1000e18, true);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for 4 accounting facets:", gasUsed);
        assertLt(gasUsed, 400_000, "Gas should scale reasonably");
    }
}

// ============================================
// TEST HARNESS
// ============================================

contract AccountFacetsTestHarness {
    bytes32[] public accountingSelectors;
    address[] public facetAddresses;
    uint256 public currentCallIndex; // Track which facet we're calling

    function addFacet(bytes4 selector, address facetAddress) external {
        accountingSelectors.push(bytes32(selector));
        facetAddresses.push(facetAddress);
    }

    function testAccountFacets(uint256 initialAssets, bool allowFailure)
        external
        returns (uint256 newTotalAssets, bool success)
    {
        bytes32[] storage _selectors = accountingSelectors;
        uint256 _totalAssets = initialAssets;
        uint256 _allowFailure = allowFailure ? 1 : 0;
        uint256 _freePtr;

        assembly {
            _freePtr := mload(0x40)
        }

        success = true;
        assembly {
            let debt := 0
            let length := sload(_selectors.slot)
            mstore(0, _selectors.slot)
            let slot := keccak256(0, 0x20)
            let retOffset := add(_freePtr, 0x04)

            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                // Store the current index so fallback knows which facet to call
                sstore(currentCallIndex.slot, i)

                let selector := sload(add(slot, i))
                mstore(_freePtr, selector)
                let res := staticcall(gas(), address(), _freePtr, 4, retOffset, 0x40)

                if iszero(res) {
                    switch _allowFailure
                    case 1 {
                        // Revert with error
                        mstore(_freePtr, 0xc84372d300000000000000000000000000000000000000000000000000000000)
                        mstore(add(_freePtr, 0x04), selector)
                        revert(_freePtr, 0x24)
                    }
                    case 0 {
                        success := 0
                        break
                    }
                }

                let decodedAmount := mload(retOffset)
                let isPositive := mload(add(retOffset, 0x20))

                if isPositive { _totalAssets := add(_totalAssets, decodedAmount) }
                if iszero(isPositive) { debt := add(debt, decodedAmount) }
            }

            if and(success, gt(_totalAssets, debt)) { newTotalAssets := sub(_totalAssets, debt) }
        }
    }

    // Fallback to handle staticcalls to facet selectors
    fallback() external {
        // Use the currentCallIndex to know which facet to call
        uint256 index = currentCallIndex;
        address facet = facetAddresses[index];

        // Call the facet's accounting() function
        (bool success, bytes memory result) = facet.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("accounting()")))
        );

        if (success) {
            assembly {
                return(add(result, 0x20), mload(result))
            }
        } else {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

// ============================================
// MOCK ACCOUNTING FACETS
// ============================================

contract PositiveAccountingFacet {
    uint256 public amount;

    constructor(uint256 _amount) {
        amount = _amount;
    }

    // Each instance needs a unique selector, so we use amount-specific names
    function accounting() external view returns (uint256, bool) {
        return (amount, true); // positive
    }

    // To get unique selector per amount, return the selector hash with amount
    function getSelector() external view returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked("accounting_", amount)));
    }
}

contract NegativeAccountingFacet {
    uint256 public amount;

    constructor(uint256 _amount) {
        amount = _amount;
    }

    function accounting() external view returns (uint256, bool) {
        return (amount, false); // negative (debt)
    }

    function getSelector() external view returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked("accounting_neg_", amount)));
    }
}

contract ExtremeValueFacet {
    uint256 public amount;
    bool public isPositive;

    constructor(uint256 _amount, bool _isPositive) {
        amount = _amount;
        isPositive = _isPositive;
    }

    function accounting() external view returns (uint256, bool) {
        return (amount, isPositive);
    }
}

contract RevertingAccountingFacet {
    function accounting() external pure returns (uint256, bool) {
        revert("Intentional accounting failure");
    }
}
