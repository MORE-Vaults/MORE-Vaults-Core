// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DiamondCutFacet} from "../../../src/facets/DiamondCutFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {MockFacet} from "../../mocks/MockFacet.sol";

contract DiamondCutFacetTest is Test {
    // Test addresses
    address public owner = address(1);
    address public facet = address(100);
    address public curator = address(7);
    address public user = address(8);
    address constant REGISTRY = address(1000);

    // Test data
    bytes4 constant TEST_SELECTOR = 0x12345678;
    address public mockFacetAddress;
    address public newTestFacet;

    function setUp() public {
        // Deploy facet
        DiamondCutFacet facetContract = new DiamondCutFacet();
        facet = address(facetContract);

        // Deploy mock facets
        MockFacet mockFacet = new MockFacet();
        mockFacetAddress = address(mockFacet);
        MockFacet mockNewFacet = new MockFacet();
        newTestFacet = address(mockNewFacet);

        // Set initial values in storage
        MoreVaultsStorageHelper.setOwner(facet, owner);
        MoreVaultsStorageHelper.setCurator(facet, curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, REGISTRY);
    }

    function test_initialize_ShouldSetSupportedInterfaces() public {
        IDiamondCut(facet).initialize("");
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IDiamondCut).interfaceId
            ),
            true,
            "Supported interfaces should be set"
        );
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            IDiamondCut(facet).facetName(),
            "DiamondCutFacet",
            "Facet name should be correct"
        );
    }

    function test_diamondCut_ShouldAddNewFacet() public {
        // Mock registry functions
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                mockFacetAddress
            ),
            abi.encode(true)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(mockFacetAddress)
        );

        // Prepare facet cut data
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: mockFacetAddress,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        cuts[0].functionSelectors[0] = TEST_SELECTOR;

        // Set up as owner
        vm.prank(owner);

        vm.mockCall(
            address(0),
            abi.encodeWithSelector(
                IVaultsFactory.link.selector,
                mockFacetAddress
            ),
            ""
        );

        // Execute diamond cut
        IDiamondCut(facet).diamondCut(cuts);

        // Verify facet was added
        address[] memory facets = MoreVaultsStorageHelper.getFacetAddresses(
            facet
        );
        assertEq(facets.length, 1, "Should have one facet");
        assertEq(facets[0], mockFacetAddress, "Should have correct facet");

        // Verify function selectors
        bytes4[] memory selectors = MoreVaultsStorageHelper
            .getFacetFunctionSelectors(facet, mockFacetAddress);
        assertEq(selectors.length, 1, "Should have one selector");
        assertEq(selectors[0], TEST_SELECTOR, "Should have correct selector");
    }

    function test_diamondCut_ShouldReplaceExistingFacet() public {
        // Mock registry functions
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                mockFacetAddress
            ),
            abi.encode(true)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(mockFacetAddress)
        );

        vm.mockCall(
            address(0), // unassigned factory
            abi.encodeWithSelector(
                IVaultsFactory.link.selector,
                mockFacetAddress
            ),
            ""
        );

        // First add a facet
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = IDiamondCut.FacetCut({
            facetAddress: mockFacetAddress,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        addCuts[0].functionSelectors[0] = TEST_SELECTOR;

        vm.prank(owner);
        IDiamondCut(facet).diamondCut(addCuts);

        // Prepare replacement facet cut data
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                newTestFacet
            ),
            abi.encode(true)
        );
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(newTestFacet)
        );

        IDiamondCut.FacetCut[] memory replaceCuts = new IDiamondCut.FacetCut[](
            1
        );
        replaceCuts[0] = IDiamondCut.FacetCut({
            facetAddress: newTestFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        replaceCuts[0].functionSelectors[0] = TEST_SELECTOR;

        vm.mockCall(
            address(0), // unassigned factory
            abi.encodeWithSelector(
                IVaultsFactory.unlink.selector,
                mockFacetAddress
            ),
            ""
        );

        vm.mockCall(
            address(0), // unassigned factory
            abi.encodeWithSelector(
                IVaultsFactory.link.selector,
                newTestFacet
            ),
            ""
        );

        // Set up as owner
        vm.prank(owner);
        // Execute diamond cut
        IDiamondCut(facet).diamondCut(replaceCuts);

        // Verify facet was replaced
        address[] memory facets = MoreVaultsStorageHelper.getFacetAddresses(
            facet
        );
        assertEq(facets.length, 1, "Should have one facet");
        assertEq(facets[0], newTestFacet, "Should have new facet");

        // Verify function selectors
        bytes4[] memory selectors = MoreVaultsStorageHelper
            .getFacetFunctionSelectors(facet, newTestFacet);
        assertEq(selectors.length, 1, "Should have one selector");
        assertEq(selectors[0], TEST_SELECTOR, "Should have correct selector");
    }

    function test_diamondCut_ShouldRemoveFacet() public {
        // Mock registry functions
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                mockFacetAddress
            ),
            abi.encode(true)
        );
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(mockFacetAddress)
        );

        // First add a facet
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = IDiamondCut.FacetCut({
            facetAddress: mockFacetAddress,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        addCuts[0].functionSelectors[0] = TEST_SELECTOR;

        vm.mockCall(
            address(0), // unassigned factory
            abi.encodeWithSelector(
                IVaultsFactory.link.selector,
                mockFacetAddress
            ),
            ""
        );

        vm.prank(owner);
        IDiamondCut(facet).diamondCut(addCuts);

        // Prepare removal facet cut data
        IDiamondCut.FacetCut[] memory removeCuts = new IDiamondCut.FacetCut[](
            1
        );
        removeCuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        removeCuts[0].functionSelectors[0] = TEST_SELECTOR;

        // Set up as owner
        vm.prank(owner);

        vm.mockCall(
            address(0), // unassigned factory
            abi.encodeWithSelector(
                IVaultsFactory.unlink.selector,
                mockFacetAddress
            ),
            ""
        );

        // Execute diamond cut
        IDiamondCut(facet).diamondCut(removeCuts);

        // Verify facet was removed
        address[] memory facets = MoreVaultsStorageHelper.getFacetAddresses(
            facet
        );
        assertEq(facets.length, 0, "Should have no facets");

        // Verify function selectors were removed
        bytes4[] memory selectors = MoreVaultsStorageHelper
            .getFacetFunctionSelectors(facet, mockFacetAddress);
        assertEq(selectors.length, 0, "Should have no selectors");
    }

    function test_diamondCut_ShouldRevertWhenNotCurator() public {
        // Mock registry functions
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                mockFacetAddress
            ),
            abi.encode(true)
        );

        // Prepare facet cut data
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: mockFacetAddress,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        cuts[0].functionSelectors[0] = TEST_SELECTOR;

        // Try to execute as non-curator
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector)
        );
        IDiamondCut(facet).diamondCut(cuts);
    }

    function test_diamondCut_ShouldRevertWhenFacetNotAllowed() public {
        // Mock registry functions
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                mockFacetAddress
            ),
            abi.encode(false)
        );

        // Prepare facet cut data
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: mockFacetAddress,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: new bytes4[](1),
            initData: ""
        });
        cuts[0].functionSelectors[0] = TEST_SELECTOR;

        vm.prank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.FacetNotAllowed.selector,
                mockFacetAddress
            )
        );
        IDiamondCut(facet).diamondCut(cuts);
    }
}
