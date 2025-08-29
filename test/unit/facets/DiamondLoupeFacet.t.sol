// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DiamondLoupeFacet} from "../../../src/facets/DiamondLoupeFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IDiamondLoupe} from "../../../src/interfaces/facets/IDiamondLoupe.sol";
import {IERC165} from "../../../src/interfaces/IERC165.sol";
import {MockFacet} from "../../mocks/MockFacet.sol";

contract DiamondLoupeFacetTest is Test {
    // Test addresses
    address public facet;
    address public mockFacet1Address;
    address public mockFacet2Address;

    // Test data
    bytes4 constant TEST_SELECTOR_1 = MockFacet.mockFunciton1.selector;
    bytes4 constant TEST_SELECTOR_2 = MockFacet.mockFunciton2.selector;
    bytes4 constant INTERFACE_ID = type(IERC165).interfaceId;

    function setUp() public {
        // Deploy facets
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        facet = address(loupeFacet);

        // Deploy mock facets
        MockFacet mockFacet1 = new MockFacet();
        mockFacet1Address = address(mockFacet1);
        MockFacet mockFacet2 = new MockFacet();
        mockFacet2Address = address(mockFacet2);

        // Setup facet addresses
        address[] memory facetAddresses = new address[](2);
        facetAddresses[0] = mockFacet1Address;
        facetAddresses[1] = mockFacet2Address;
        MoreVaultsStorageHelper.setFacetAddresses(facet, facetAddresses);

        // Setup selectors for first facet
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = TEST_SELECTOR_1;
        MoreVaultsStorageHelper.setFacetFunctionSelectors(
            facet,
            mockFacet1Address,
            selectors1,
            0
        );
        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(
            facet,
            TEST_SELECTOR_1,
            mockFacet1Address,
            0
        );

        // Setup selectors for second facet
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = TEST_SELECTOR_2;
        MoreVaultsStorageHelper.setFacetFunctionSelectors(
            facet,
            mockFacet2Address,
            selectors2,
            0
        );
        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(
            facet,
            TEST_SELECTOR_2,
            mockFacet2Address,
            0
        );

        // Setup interface support
        MoreVaultsStorageHelper.setSupportedInterface(
            facet,
            INTERFACE_ID,
            true
        );
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            DiamondLoupeFacet(facet).facetName(),
            "DiamondLoupeFacet",
            "Facet name should be correct"
        );
    }

    function test_initialize_ShouldSetSupportedInterfaces() public {
        DiamondLoupeFacet(facet).initialize("");
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                INTERFACE_ID
            ),
            true,
            "Supported interfaces should be set"
        );
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IDiamondLoupe).interfaceId
            ),
            true,
            "Supported interfaces should be set"
        );
    }
    function test_facets_ShouldReturnAllFacetsAndSelectors() public view {
        IDiamondLoupe.Facet[] memory facets = DiamondLoupeFacet(facet).facets();

        assertEq(facets.length, 2, "Should return two facets");

        // Check first facet
        assertEq(
            facets[0].facetAddress,
            mockFacet1Address,
            "Should have correct first facet address"
        );
        assertEq(
            facets[0].functionSelectors.length,
            1,
            "Should have one selector for first facet"
        );
        assertEq(
            facets[0].functionSelectors[0],
            TEST_SELECTOR_1,
            "Should have correct selector for first facet"
        );

        // Check second facet
        assertEq(
            facets[1].facetAddress,
            mockFacet2Address,
            "Should have correct second facet address"
        );
        assertEq(
            facets[1].functionSelectors.length,
            1,
            "Should have one selector for second facet"
        );
        assertEq(
            facets[1].functionSelectors[0],
            TEST_SELECTOR_2,
            "Should have correct selector for second facet"
        );
    }

    function test_facetFunctionSelectors_ShouldReturnCorrectSelectors()
        public
        view
    {
        bytes4[] memory selectors = DiamondLoupeFacet(facet)
            .facetFunctionSelectors(mockFacet1Address);

        assertEq(selectors.length, 1, "Should return one selector");
        assertEq(
            selectors[0],
            TEST_SELECTOR_1,
            "Should return correct selector"
        );
    }

    function test_facetAddresses_ShouldReturnAllAddresses() public view {
        address[] memory addresses = DiamondLoupeFacet(facet).facetAddresses();

        assertEq(addresses.length, 2, "Should return two addresses");
        assertEq(
            addresses[0],
            mockFacet1Address,
            "Should have correct first address"
        );
        assertEq(
            addresses[1],
            mockFacet2Address,
            "Should have correct second address"
        );
    }

    function test_facetAddress_ShouldReturnCorrectFacet() public view {
        address facetAddress = DiamondLoupeFacet(facet).facetAddress(
            TEST_SELECTOR_1
        );
        assertEq(
            facetAddress,
            mockFacet1Address,
            "Should return correct facet address"
        );
    }

    function test_facetAddress_ShouldReturnZeroForUnknownSelector()
        public
        view
    {
        address facetAddress = DiamondLoupeFacet(facet).facetAddress(
            bytes4(0x12345678)
        );
        assertEq(
            facetAddress,
            address(0),
            "Should return zero address for unknown selector"
        );
    }

    function test_supportsInterface_ShouldReturnTrue() public view {
        bool supported = DiamondLoupeFacet(facet).supportsInterface(
            INTERFACE_ID
        );
        assertTrue(supported, "Should support ERC165 interface");
    }

    function test_supportsInterface_ShouldReturnFalseForUnknownInterface()
        public
        view
    {
        bool supported = DiamondLoupeFacet(facet).supportsInterface(
            bytes4(0x12345678)
        );
        assertFalse(supported, "Should not support unknown interface");
    }
}
