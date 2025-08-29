// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MoreVaultsDiamond} from "../../../src/MoreVaultsDiamond.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {DiamondCutFacet} from "../../../src/facets/DiamondCutFacet.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {AccessControlFacet} from "../../../src/facets/AccessControlFacet.sol";

contract MoreVaultsDiamondTest is Test {
    MoreVaultsDiamond public diamond;
    DiamondCutFacet public diamondCutFacet;
    AccessControlFacet public accessControlFacet;
    address public registry;
    address public wrappedNative;
    IDiamondCut.FacetCut[] public cuts;
    address owner = address(1111);
    address curator = address(2222);
    address guardian = address(3333);

    function setUp() public {
        // Deploy real DiamondCutFacet
        diamondCutFacet = new DiamondCutFacet();
        accessControlFacet = new AccessControlFacet();
        registry = address(2);
        wrappedNative = address(3);
        cuts = new IDiamondCut.FacetCut[](0);

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );
        // Mock registry calls for diamondCut
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(diamondCutFacet)
            ),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IDiamondCut.diamondCut.selector
            ),
            abi.encode(address(diamondCutFacet))
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(accessControlFacet)
            ),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                AccessControlFacet.setMoreVaultsRegistry.selector
            ),
            abi.encode(address(accessControlFacet))
        );

        bytes memory accessControlFacetInitData = abi.encode(
            owner,
            curator,
            guardian
        );

        diamond = new MoreVaultsDiamond(
            address(diamondCutFacet),
            address(accessControlFacet),
            registry,
            wrappedNative,
            cuts,
            accessControlFacetInitData
        );
    }

    function test_Constructor_ShouldSetRegistry() public view {
        assertEq(
            MoreVaultsStorageHelper.getMoreVaultsRegistry(address(diamond)),
            registry,
            "Registry should be set correctly"
        );
    }

    function test_Constructor_ShouldSetAccessControlParams() public view {
        assertEq(
            MoreVaultsStorageHelper.getOwner(address(diamond)),
            owner,
            "Owner should be set correctly"
        );
        assertEq(
            MoreVaultsStorageHelper.getCurator(address(diamond)),
            curator,
            "Curator should be set correctly"
        );
        assertEq(
            MoreVaultsStorageHelper.getGuardian(address(diamond)),
            guardian,
            "guardian should be set correctly"
        );
    }

    function test_Constructor_ShouldSetDiamondCutFacet() public view {
        bytes4 selector = IDiamondCut.diamondCut.selector;
        address facet = MoreVaultsStorageHelper.getFacetBySelector(
            address(diamond),
            selector
        );
        assertEq(
            facet,
            address(diamondCutFacet),
            "DiamondCut facet should be set correctly"
        );
    }

    function test_Fallback_ShouldRevertForNonExistentFunction() public {
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");
        (bool success, ) = address(diamond).call(data);
        assertFalse(success, "Should revert for non-existent function");
    }

    function test_Receive_ShouldAcceptEtherIfWrappedNativeIsAvailable() public {
        address[] memory assets = new address[](1);
        assets[0] = wrappedNative;
        MoreVaultsStorageHelper.setAvailableAssets(address(diamond), assets);
        uint256 balanceBefore = address(diamond).balance;
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(diamond).call{value: 1 ether}("");
        assertTrue(success, "Should accept ether");
        assertEq(
            address(diamond).balance,
            balanceBefore + 1 ether,
            "Balance should increase"
        );
    }

    function test_Receive_ShouldRevertIfWrappedNativeIsNotAvailable() public {
        vm.deal(address(this), 1 ether);
        uint256 balanceBefore = address(diamond).balance;
        vm.expectRevert(MoreVaultsDiamond.NativeTokenNotAvailable.selector);
        (bool success, ) = address(diamond).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(
            address(diamond).balance,
            balanceBefore,
            "Balance should not increase"
        );
    }

    function test_DiamondCutFacet_ShouldInitializeCorrectly() public view {
        // Verify that DiamondCutFacet is initialized
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(diamond),
                type(IDiamondCut).interfaceId
            ),
            "DiamondCutFacet should be initialized"
        );
    }
}
