// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IAccessControlFacet, AccessControlFacet} from "../../../src/facets/AccessControlFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";

contract AccessControlFacetTest is Test {
    AccessControlFacet public facet;

    address public owner = address(111);
    address public newOwner = address(112);
    address public curator = address(1);
    address public guardian = address(2);
    address public newCurator = address(3);
    address public newGuardian = address(4);
    address public unauthorized = address(5);
    address public registry = address(6);
    address public newRegistry = address(7);
    address public facet1 = address(8);
    address public facet2 = address(9);

    // Storage slot for AccessControlStorage struct
    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION =
        AccessControlLib.ACCESS_CONTROL_STORAGE_POSITION;

    function setUp() public {
        // Deploy facet
        facet = new AccessControlFacet();

        // Set registry since it should be set outside of initialization of this facet
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);

        facet.initialize(abi.encode(owner, curator, guardian));

        // Setup MoreVaultsStorage using helper library
        address[] memory facets = new address[](2);
        facets[0] = facet1;
        facets[1] = facet2;
        MoreVaultsStorageHelper.setFacetAddresses(address(facet), facets);

        // Set facet selectors
        bytes4[] memory selectors1 = new bytes4[](1);
        selectors1[0] = bytes4(0x12345678);
        MoreVaultsStorageHelper.setFacetFunctionSelectors(
            address(facet),
            facet1,
            selectors1,
            0
        );

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = bytes4(0x87654321);
        MoreVaultsStorageHelper.setFacetFunctionSelectors(
            address(facet),
            facet2,
            selectors2,
            0
        );

        // Mock registry behavior
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector),
            abi.encode(true)
        );
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector
            ),
            abi.encode(facet1)
        );

        // Mock validateRegistryOwner to return true for registry address
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IAccessControl.hasRole.selector),
            abi.encode(true)
        );
    }

    function test_initialize_ShouldSetVariablesCorrectly() public view {
        assertEq(facet.owner(), owner, "Owner should be set");
        assertEq(facet.curator(), curator, "Curator should be set");
        assertEq(facet.guardian(), guardian, "Guardian should be set");

        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IAccessControlFacet).interfaceId
            ),
            true,
            "Supported interfaces should be set"
        );
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            facet.facetName(),
            "AccessControlFacet",
            "Facet name should be correct"
        );
    }

    function test_transferCuratorship_ShouldUpdateCurator() public {
        vm.startPrank(owner);

        // Transfer curatorship
        facet.transferCuratorship(newCurator);

        // Verify new curator in storage
        assertEq(
            MoreVaultsStorageHelper.getOwner(address(facet)),
            owner,
            "Owner should be set"
        );

        // Verify through getter
        assertEq(facet.curator(), newCurator, "Curator should be updated");

        vm.stopPrank();
    }

    function test_transferCuratorship_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to transfer curatorship
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.transferCuratorship(newCurator);

        vm.stopPrank();
    }

    function test_transferCuratorship_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(owner);

        // Attempt to transfer curatorship to zero address
        vm.expectRevert(AccessControlLib.ZeroAddress.selector);
        facet.transferCuratorship(address(0));

        vm.stopPrank();
    }

    function test_transferCuratorship_ShouldRevertWhenSameAddress() public {
        vm.startPrank(owner);

        // Attempt to transfer curatorship to same address
        vm.expectRevert(AccessControlLib.SameAddress.selector);
        facet.transferCuratorship(curator);

        vm.stopPrank();
    }

    function test_transferOwnership_ShouldUpdatePendingOwner() public {
        vm.startPrank(owner);

        // Transfer curatorship
        facet.transferOwnership(newOwner);

        // Verify new curator in storage
        assertEq(
            MoreVaultsStorageHelper.getPendingOwner(address(facet)),
            newOwner,
            "Pending owner should be set"
        );

        // Verify through getter
        assertEq(
            facet.pendingOwner(),
            newOwner,
            "Pending owner should be updated"
        );

        vm.stopPrank();
    }

    function test_transferOwnership_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to transfer ownership
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.transferOwnership(newOwner);

        vm.stopPrank();
    }

    function test_acceptOwnership_ShouldSetOwner() public {
        vm.startPrank(owner);

        // Set pending owner
        facet.transferOwnership(newOwner);

        vm.stopPrank();

        // Attempt to transfer ownership
        vm.startPrank(newOwner);
        facet.acceptOwnership();

        // Verify owner in storage
        assertEq(
            MoreVaultsStorageHelper.getOwner(address(facet)),
            newOwner,
            "Owner should be set"
        );

        vm.stopPrank();
    }

    function test_acceptOwnership_ShouldSetPendingOwnerToZero() public {
        vm.startPrank(owner);

        // Set pending owner
        facet.transferOwnership(newOwner);

        vm.stopPrank();

        // Attempt to transfer ownership
        vm.startPrank(newOwner);
        facet.acceptOwnership();

        // Verify owner in storage
        assertEq(
            MoreVaultsStorageHelper.getPendingOwner(address(facet)),
            address(0),
            "Pending owner should be 0"
        );

        vm.stopPrank();
    }

    function test_acceptOwnership_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to transfer ownership
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.acceptOwnership();

        vm.stopPrank();
    }

    function test_transferGuardian_ShouldUpdateGuardian() public {
        vm.startPrank(owner);

        // Transfer guardian role
        facet.transferGuardian(newGuardian);

        // Verify new guardian in storage
        assertEq(
            MoreVaultsStorageHelper.getGuardian(address(facet)),
            newGuardian,
            "Guardian should be updated in storage"
        );

        // Verify through getter
        assertEq(facet.guardian(), newGuardian, "Guardian should be updated");

        vm.stopPrank();
    }

    function test_transferGuardian_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to transfer guardian role
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.transferGuardian(newGuardian);

        // Verify guardian remains unchanged in storage
        assertEq(
            MoreVaultsStorageHelper.getGuardian(address(facet)),
            guardian,
            "Guardian should not be changed in storage"
        );

        // Verify through getter
        assertEq(facet.guardian(), guardian, "Guardian should not be changed");

        vm.stopPrank();
    }

    function test_transferGuardian_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(owner);

        // Attempt to transfer guardian role to zero address
        vm.expectRevert(AccessControlLib.ZeroAddress.selector);
        facet.transferGuardian(address(0));

        vm.stopPrank();
    }

    function test_transferGuardian_ShouldRevertWhenSameAddress() public {
        vm.startPrank(owner);

        // Attempt to transfer guardian role to same address
        vm.expectRevert(AccessControlLib.SameAddress.selector);
        facet.transferGuardian(guardian);

        vm.stopPrank();
    }

    function test_curator_ShouldReturnCorrectAddress() public view {
        // Verify curator in storage
        assertEq(
            MoreVaultsStorageHelper.getCurator(address(facet)),
            curator,
            "Curator should be correct in storage"
        );

        // Verify through getter
        assertEq(facet.curator(), curator, "Curator should be correct");
    }

    function test_guardian_ShouldReturnCorrectAddress() public view {
        assertEq(
            MoreVaultsStorageHelper.getGuardian(address(facet)),
            guardian,
            "Guardian should be correct in storage"
        );

        // Verify through getter
        assertEq(facet.guardian(), guardian, "Guardian should be correct");
    }

    function test_setMoreVaultsRegistry_ShouldUpdateRegistry() public {
        vm.startPrank(owner);

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(0)
            ),
            abi.encode(false)
        );
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(0)
            ),
            abi.encode(false)
        );

        // Mock selectorToFacet to return different facets for different selectors
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                bytes4(0x12345678)
            ),
            abi.encode(facet1)
        );
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                bytes4(0x87654321)
            ),
            abi.encode(facet2)
        );

        // Set new registry
        facet.setMoreVaultsRegistry(newRegistry);

        // Verify new registry in storage
        assertEq(
            MoreVaultsStorageHelper.getMoreVaultsRegistry(address(facet)),
            newRegistry,
            "Registry should be updated in storage"
        );

        vm.stopPrank();
    }

    function test_setMoreVaultsRegistry_ShouldRevertIfChangingFromPermissionedToPermissionless()
        public
    {
        vm.startPrank(owner);

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(0)
            ),
            abi.encode(false)
        );
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(0)
            ),
            abi.encode(true)
        );

        // Set new registry
        vm.expectRevert(
            IAccessControlFacet.UnaibleToChangeRegistryToPermissionless.selector
        );
        facet.setMoreVaultsRegistry(newRegistry);

        vm.stopPrank();
    }

    function test_setMoreVaultsRegistry_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Mock validateRegistryOwner to revert for unauthorized address
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IAccessControl.hasRole.selector),
            abi.encode(false)
        );

        // Attempt to set new registry
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.setMoreVaultsRegistry(newRegistry);

        // Verify registry remains unchanged in storage
        assertEq(
            MoreVaultsStorageHelper.getMoreVaultsRegistry(address(facet)),
            registry,
            "Registry should not be changed in storage"
        );

        vm.stopPrank();
    }

    function test_setMoreVaultsRegistry_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(owner);

        // Attempt to set zero address as registry
        vm.expectRevert(AccessControlLib.ZeroAddress.selector);
        facet.setMoreVaultsRegistry(address(0));

        vm.stopPrank();
    }

    function test_setMoreVaultsRegistry_ShouldRevertWhenSameAddress() public {
        vm.startPrank(owner);

        // Attempt to set same registry address
        vm.expectRevert(AccessControlLib.SameAddress.selector);
        facet.setMoreVaultsRegistry(registry);

        vm.stopPrank();
    }

    function test_setMoreVaultsRegistry_ShouldRevertWhenFacetNotAllowed()
        public
    {
        vm.startPrank(owner);

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector),
            abi.encode(false)
        );
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector),
            abi.encode(false)
        );

        // Mock registry to return false for isFacetAllowed
        vm.mockCall(
            newRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector),
            abi.encode(false)
        );

        // Attempt to set new registry
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.VaultHasNotAllowedFacet.selector,
                address(facet1)
            )
        );
        facet.setMoreVaultsRegistry(newRegistry);

        vm.stopPrank();
    }
}
