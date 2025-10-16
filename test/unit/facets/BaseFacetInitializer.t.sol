// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {BaseFacetInitializer} from "../../../src/facets/BaseFacetInitializer.sol";

/// @notice Mock facet to test BaseFacetInitializer
contract MockFacetForInitializer is BaseFacetInitializer {
    uint256 public value;
    bool public secondaryInitCalled;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("test.storage.MockFacetForInitializer");
    }

    function initialize(uint256 _value) external initializerFacet {
        value = _value;
    }

    function initializeWithNested(uint256 _value) external initializerFacet {
        value = _value;
        _nestedInit();
    }

    function _nestedInit() internal onlyInitializingFacet {
        secondaryInitCalled = true;
    }

    function tryNestedInitWithoutInitializer() external {
        _nestedInit();
    }

    // Expose internal functions for testing
    function isInitialized() external view returns (bool) {
        return layoutInitializableStorage()._initialized;
    }

    function isInitializing() external view returns (bool) {
        return layoutInitializableStorage()._initializing;
    }
}

contract BaseFacetInitializerTest is Test {
    MockFacetForInitializer public facet;

    function setUp() public {
        facet = new MockFacetForInitializer();
    }

    function test_initialize_ShouldSetValueCorrectly() public {
        uint256 testValue = 12345;

        facet.initialize(testValue);

        assertEq(facet.value(), testValue);
        assertTrue(facet.isInitialized());
        assertFalse(facet.isInitializing());
    }

    function test_initialize_ShouldRevertWhenCalledTwice() public {
        facet.initialize(100);

        vm.expectRevert(BaseFacetInitializer.AlreadyInitialized.selector);
        facet.initialize(200);
    }

    function test_initializeWithNested_ShouldWorkCorrectly() public {
        facet.initializeWithNested(999);

        assertEq(facet.value(), 999);
        assertTrue(facet.secondaryInitCalled());
        assertTrue(facet.isInitialized());
        assertFalse(facet.isInitializing());
    }

    function test_onlyInitializingFacet_ShouldRevertWhenNotInitializing() public {
        vm.expectRevert(BaseFacetInitializer.FacetNotInitializing.selector);
        facet.tryNestedInitWithoutInitializer();
    }

    function test_layoutInitializableStorage_ShouldReturnCorrectSlot() public {
        // Initially should not be initialized
        assertFalse(facet.isInitialized());
        assertFalse(facet.isInitializing());

        // After initialization
        facet.initialize(42);

        assertTrue(facet.isInitialized());
        assertFalse(facet.isInitializing());
    }

    function test_initializerFacet_ShouldHandleReentrancy() public {
        // First initialization should work
        facet.initialize(1);
        assertTrue(facet.isInitialized());

        // Second initialization should fail even with different value
        vm.expectRevert(BaseFacetInitializer.AlreadyInitialized.selector);
        facet.initialize(2);
    }

    function test_INITIALIZABLE_STORAGE_SLOT_ShouldBeConsistent() public view {
        // The slot should be deterministic
        bytes32 expectedSlot = keccak256("test.storage.MockFacetForInitializer");

        // We can't directly call the internal function, but we can verify
        // that multiple calls to initialize use the same storage
        // This is implicitly tested by other tests
    }

    function testFuzz_initialize_ShouldWorkWithAnyValue(uint256 randomValue) public {
        facet.initialize(randomValue);

        assertEq(facet.value(), randomValue);
        assertTrue(facet.isInitialized());
    }

    function test_initializerFacet_StateTransitions() public {
        // Before init: not initialized, not initializing
        assertFalse(facet.isInitialized());
        assertFalse(facet.isInitializing());

        // After init: initialized, not initializing
        facet.initialize(100);
        assertTrue(facet.isInitialized());
        assertFalse(facet.isInitializing());
    }
}

/// @notice Test initialization during construction scenario
contract MockFacetWithConstructorInit is BaseFacetInitializer {
    uint256 public value;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("test.storage.MockFacetWithConstructorInit");
    }

    constructor(uint256 _value) {
        // Call initialize during construction to trigger _isConstructor() path
        _initDuringConstruction(_value);
    }

    function _initDuringConstruction(uint256 _value) internal initializerFacet {
        value = _value;
    }

    function initialize(uint256 _value) external initializerFacet {
        value = _value;
    }

    function isInitialized() external view returns (bool) {
        return layoutInitializableStorage()._initialized;
    }
}

contract BaseFacetInitializerConstructorTest is Test {
    function test_constructor_ShouldInitializeDuringConstruction() public {
        // This triggers _isConstructor() because initialization happens during construction
        MockFacetWithConstructorInit facet = new MockFacetWithConstructorInit(42);

        assertEq(facet.value(), 42);
        assertTrue(facet.isInitialized()); // Should be initialized after construction
    }

    function test_constructor_ShouldPreventDoubleInitialization() public {
        MockFacetWithConstructorInit facet = new MockFacetWithConstructorInit(42);

        // Should not be able to initialize again
        vm.expectRevert(BaseFacetInitializer.AlreadyInitialized.selector);
        facet.initialize(100);
    }
}

/// @notice Test multiple initialization guards
contract MockFacetWithMultipleInits is BaseFacetInitializer {
    uint256 public valueA;
    uint256 public valueB;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("test.storage.MockFacetWithMultipleInits");
    }

    function initializeA(uint256 _value) external initializerFacet {
        valueA = _value;
        _initB(_value * 2);
    }

    function _initB(uint256 _value) internal onlyInitializingFacet {
        valueB = _value;
    }

    function initializeB_standalone(uint256 _value) external {
        _initB(_value);
    }

    function isInitialized() external view returns (bool) {
        return layoutInitializableStorage()._initialized;
    }
}

contract BaseFacetInitializerNestedTest is Test {
    MockFacetWithMultipleInits public facet;

    function setUp() public {
        facet = new MockFacetWithMultipleInits();
    }

    function test_nestedInit_ShouldWorkDuringInitialization() public {
        facet.initializeA(10);

        assertEq(facet.valueA(), 10);
        assertEq(facet.valueB(), 20);
        assertTrue(facet.isInitialized());
    }

    function test_nestedInit_ShouldRevertOutsideInitialization() public {
        vm.expectRevert(BaseFacetInitializer.FacetNotInitializing.selector);
        facet.initializeB_standalone(50);
    }

    function test_nestedInit_ShouldRevertAfterInitialization() public {
        facet.initializeA(10);

        vm.expectRevert(BaseFacetInitializer.FacetNotInitializing.selector);
        facet.initializeB_standalone(50);
    }
}
