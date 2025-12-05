// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {BaseFacetInitializer, IMulticallFacet, MulticallFacet} from "../../../src/facets/MulticallFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IAccessControlFacet} from "../../../src/interfaces/facets/IAccessControlFacet.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {console} from "forge-std/console.sol";

contract MulticallFacetTest is Test {
    MulticallFacet public facet;

    address public curator = address(1);
    address public guardian = address(2);
    address public unauthorized = address(3);
    address public zeroAddress = address(0);

    // Mock data
    bytes[] public actionsData;
    bytes public callData;
    uint256 public timeLockPeriod = 1 days;
    uint256 public currentNonce = 0;

    function setUp() public {
        // Deploy facet
        facet = new MulticallFacet();

        // Set roles
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setGuardian(address(facet), guardian);

        // Set time lock period
        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), timeLockPeriod);

        // Set action nonce
        MoreVaultsStorageHelper.setActionNonce(address(facet), currentNonce);

        // Setup mock actions data
        actionsData = new bytes[](2);
        callData = abi.encodeWithSignature("mockFunction1()");
        actionsData[0] = callData;
        callData = abi.encodeWithSignature("mockFunction2()");
        actionsData[1] = callData;
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "MulticallFacet", "Facet name should be correct");
    }

    function test_version_ShouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.1", "Version should be correct");
    }

    function test_onFacetRemoval_ShouldDisableInterface() public {
        facet.onFacetRemoval(false);
        assertFalse(MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMulticallFacet).interfaceId));
    }

    function test_initialize_ShouldSetParametersCorrectly() public {
        MulticallFacet(facet).initialize(abi.encode(timeLockPeriod, 10_000));
        assertEq(
            MoreVaultsStorageHelper.getTimeLockPeriod(address(facet)), timeLockPeriod, "Time lock period should be set"
        );
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IMulticallFacet).interfaceId),
            true,
            "Supported interfaces should be set"
        );
    }

    function test_submitActions_ShouldSubmitActions() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Verify nonce
        assertEq(nonce, currentNonce, "Nonce should match current nonce");

        // Verify pending actions
        (bytes[] memory storedActions, uint256 pendingUntil) = facet.getPendingActions(nonce);
        assertEq(storedActions.length, actionsData.length, "Actions length should match");
        assertEq(pendingUntil, block.timestamp + timeLockPeriod, "Pending until should be correct");

        vm.stopPrank();
    }

    function test_submitActions_ShouldExecuteActionsIfTimeLockPeriodIsZero() public {
        vm.startPrank(curator);

        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), 0);

        // Mock function calls
        vm.mockCall(address(facet), abi.encodeWithSignature("mockFunction1()"), abi.encode());
        vm.mockCall(address(facet), abi.encodeWithSignature("mockFunction2()"), abi.encode());
        vm.mockCall(address(facet), abi.encodeWithSignature("totalAssets()"), abi.encode(1e18));

        vm.expectEmit();
        emit IMulticallFacet.ActionsSubmitted(curator, currentNonce, block.timestamp, actionsData);
        vm.expectEmit();
        emit IMulticallFacet.ActionsExecuted(curator, currentNonce);
        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Verify pending actions
        (bytes[] memory storedActions, uint256 pendingUntil) = facet.getPendingActions(nonce);
        assertEq(storedActions.length, 0, "Actions length should be deleted");
        assertEq(pendingUntil, 0, "Pending until should be deleted");

        vm.stopPrank();
    }

    function test_submitActions_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to submit actions
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.submitActions(actionsData);

        vm.stopPrank();
    }

    function test_submitActions_ShouldRevertWhenEmptyActions() public {
        vm.startPrank(curator);

        // Attempt to submit empty actions
        bytes[] memory emptyActions = new bytes[](0);
        vm.expectRevert(IMulticallFacet.EmptyActions.selector);
        facet.submitActions(emptyActions);

        vm.stopPrank();
    }

    function test_executeActions_ShouldExecuteActions() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Mock function calls
        vm.mockCall(address(facet), abi.encodeWithSignature("mockFunction1()"), abi.encode());
        vm.mockCall(address(facet), abi.encodeWithSignature("mockFunction2()"), abi.encode());
        vm.mockCall(address(facet), abi.encodeWithSignature("totalAssets()"), abi.encode(1e18));

        // Fast forward time
        vm.warp(block.timestamp + timeLockPeriod + 1);

        // Execute actions
        facet.executeActions(nonce);

        // Verify actions were deleted
        (bytes[] memory storedActions, uint256 pendingUntil) = facet.getPendingActions(nonce);
        assertEq(storedActions.length, 0, "Actions should be deleted");
        assertEq(pendingUntil, 0, "Pending until should be zero");

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenActionsStillPending() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Attempt to execute actions before time lock period
        vm.expectRevert(abi.encodeWithSelector(IMulticallFacet.ActionsStillPending.selector, nonce));
        facet.executeActions(nonce);

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenNoSuchActions() public {
        vm.startPrank(curator);

        // Attempt to execute non-existent actions
        vm.expectRevert(abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, 999));
        facet.executeActions(999);

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenMulticallFailed() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Fast forward time
        vm.warp(block.timestamp + timeLockPeriod + 1);

        vm.mockCall(address(facet), abi.encodeWithSignature("totalAssets()"), abi.encode(1e18));

        // Attempt to execute actions
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("MulticallFailed(uint256,bytes)")), 0, ""));
        facet.executeActions(nonce);
        vm.stopPrank();
    }

    function test_vetoActions_ShouldVetoActions() public {
        vm.startPrank(curator);

        // Submit actions
        uint256[] memory nonce = new uint256[](1);
        nonce[0] = facet.submitActions(actionsData);

        vm.stopPrank();
        vm.startPrank(guardian);

        // Veto actions
        facet.vetoActions(nonce);

        // Verify actions were deleted
        (bytes[] memory storedActions, uint256 pendingUntil) = facet.getPendingActions(nonce[0]);
        assertEq(storedActions.length, 0, "Actions should be deleted");
        assertEq(pendingUntil, 0, "Pending until should be zero");

        vm.stopPrank();
    }

    function test_vetoActions_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(curator);

        // Submit actions
        uint256[] memory nonce = new uint256[](1);
        nonce[0] = facet.submitActions(actionsData);

        vm.stopPrank();
        vm.startPrank(unauthorized);

        // Attempt to veto actions
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.vetoActions(nonce);

        vm.stopPrank();
    }

    function test_vetoActions_ShouldRevertWhenNoSuchActions() public {
        vm.startPrank(guardian);

        uint256[] memory nonce = new uint256[](1);
        nonce[0] = 999;

        // Attempt to veto non-existent actions
        vm.expectRevert(abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, 999));
        facet.vetoActions(nonce);

        vm.stopPrank();
    }

    function test_getPendingActions_ShouldReturnCorrectData() public {
        vm.startPrank(curator);

        // Submit actions
        uint256[] memory nonce = new uint256[](1);
        nonce[0] = facet.submitActions(actionsData);

        // Get pending actions
        (bytes[] memory storedActions, uint256 pendingUntil) = facet.getPendingActions(nonce[0]);

        // Verify data
        assertEq(storedActions.length, actionsData.length, "Actions length should match");
        assertEq(pendingUntil, block.timestamp + timeLockPeriod, "Pending until should be correct");

        vm.stopPrank();
    }

    function test_getCurrentNonce_ShouldReturnCorrectNonce() public view {
        assertEq(facet.getCurrentNonce(), currentNonce, "Current nonce should match");
    }

    function test_shouldRevertWhenSlippageExceeded() public {
        TotalAssetsMock mock = new TotalAssetsMock();

        // Set roles
        MoreVaultsStorageHelper.setCurator(address(mock), curator);
        MoreVaultsStorageHelper.setGuardian(address(mock), guardian);
        MoreVaultsStorageHelper.setTimeLockPeriod(address(mock), 0);

        bytes[] memory newActionsData = new bytes[](1);
        newActionsData[0] = abi.encodeWithSignature("increaseCounter()");
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(MulticallFacet.SlippageExceeded.selector, 9999, 1));
        MoreVaultsStorageHelper.setSlippagePercent(address(mock), 1);
        mock.submitActions(newActionsData);
    }

    // ===== Issue #19 Tests: Selector Validation Bypass =====

    function test_Issue19_submitActions_ShouldValidateAllSelectors_CuratorActions() public {
        // Setup: Create actions with different curator-allowed selectors
        bytes[] memory multiActions = new bytes[](3);
        multiActions[0] = abi.encodeWithSignature("mockFunction1()");
        multiActions[1] = abi.encodeWithSignature("mockFunction2()");
        multiActions[2] = abi.encodeWithSignature("mockFunction3()");

        vm.startPrank(curator);

        // All selectors should be validated - this should succeed for curator
        uint256 nonce = facet.submitActions(multiActions);

        // Verify actions were stored
        (bytes[] memory storedActions,) = facet.getPendingActions(nonce);
        assertEq(storedActions.length, 3, "All actions should be stored");

        vm.stopPrank();
    }

    function test_Issue19_submitActions_ShouldRevertIfSecondSelectorRequiresOwner() public {
        // Test that even if first selector is curator-allowed,
        // second selector requiring owner should fail for curator

        SelectorValidationMock mock = new SelectorValidationMock();
        MoreVaultsStorageHelper.setTimeLockPeriod(address(mock), timeLockPeriod);
        MoreVaultsStorageHelper.setCurator(address(mock), curator);
        MoreVaultsStorageHelper.setOwner(address(mock), address(this));

        // Create actions: first is curator-allowed, second requires owner
        bytes[] memory mixedActions = new bytes[](2);
        mixedActions[0] = abi.encodeWithSignature("mockFunction1()"); // Curator allowed
        mixedActions[1] = abi.encodeWithSelector(IAccessControlFacet.transferOwnership.selector, address(999)); // Owner only

        vm.startPrank(curator);

        // Should revert because second selector requires owner permission
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        mock.submitActions(mixedActions);

        vm.stopPrank();
    }

    function test_Issue19_submitActions_ShouldRevertIfThirdSelectorRequiresOwner() public {
        SelectorValidationMock mock = new SelectorValidationMock();
        MoreVaultsStorageHelper.setTimeLockPeriod(address(mock), timeLockPeriod);
        MoreVaultsStorageHelper.setCurator(address(mock), curator);
        MoreVaultsStorageHelper.setOwner(address(mock), address(this));

        // Create actions: first two curator-allowed, third requires owner
        bytes[] memory mixedActions = new bytes[](3);
        mixedActions[0] = abi.encodeWithSignature("mockFunction1()");
        mixedActions[1] = abi.encodeWithSignature("mockFunction2()");
        mixedActions[2] = abi.encodeWithSelector(IConfigurationFacet.setTimeLockPeriod.selector, 123); // Owner only

        vm.startPrank(curator);

        // Should revert because third selector requires owner permission
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        mock.submitActions(mixedActions);

        vm.stopPrank();
    }

    function test_Issue19_submitActions_ShouldRevertOnInvalidSelectorLength() public {
        vm.startPrank(curator);

        // Create actions with invalid selector (less than 4 bytes)
        bytes[] memory invalidActions = new bytes[](2);
        invalidActions[0] = abi.encodeWithSignature("mockFunction1()");
        invalidActions[1] = new bytes(3); // Only 3 bytes - invalid

        // Should revert due to invalid selector length
        vm.expectRevert(IMulticallFacet.EmptyActions.selector);
        facet.submitActions(invalidActions);

        vm.stopPrank();
    }

    function test_Issue19_submitActions_OwnerCanSubmitOwnerOnlyActions() public {
        SelectorValidationMock mock = new SelectorValidationMock();
        MoreVaultsStorageHelper.setTimeLockPeriod(address(mock), timeLockPeriod);
        address owner = address(this);
        MoreVaultsStorageHelper.setOwner(address(mock), owner);
        MoreVaultsStorageHelper.setCurator(address(mock), curator);

        // Create actions with owner-only selectors
        bytes[] memory ownerActions = new bytes[](3);
        ownerActions[0] = abi.encodeWithSelector(IAccessControlFacet.transferOwnership.selector, address(999));
        ownerActions[1] = abi.encodeWithSelector(IConfigurationFacet.setTimeLockPeriod.selector, 456);
        ownerActions[2] = abi.encodeWithSelector(IVaultFacet.setFee.selector, 100);

        // Owner should be able to submit all owner-only actions
        uint256 nonce = mock.submitActions(ownerActions);

        // Verify all actions were stored
        (bytes[] memory storedActions,) = mock.getPendingActions(nonce);
        assertEq(storedActions.length, 3, "All actions should be stored");
    }

    function test_Issue19_submitActions_ShouldRevertIfAnyActionInvalidForUnauthorized() public {
        SelectorValidationMock mock = new SelectorValidationMock();
        MoreVaultsStorageHelper.setTimeLockPeriod(address(mock), timeLockPeriod);
        MoreVaultsStorageHelper.setCurator(address(mock), curator);
        MoreVaultsStorageHelper.setOwner(address(mock), address(this));

        // Create actions where unauthorized user tries to submit
        bytes[] memory actions = new bytes[](2);
        actions[0] = abi.encodeWithSignature("mockFunction1()");
        actions[1] = abi.encodeWithSignature("mockFunction2()");

        vm.startPrank(unauthorized);

        // Should revert because unauthorized is neither curator nor owner
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        mock.submitActions(actions);

        vm.stopPrank();
    }
}

contract TotalAssetsMock is MulticallFacet {
    function totalAssets() external view returns (uint256) {
        uint256 counter = MoreVaultsStorageHelper.getScratchSpace(address(this));
        return counter == 0 ? 1e18 : 1e1;
    }

    function increaseCounter() external {
        MoreVaultsStorageHelper.setScratchSpace(address(this), 1);
    }
}

contract SelectorValidationMock is MulticallFacet {
    function totalAssets() external pure returns (uint256) {
        return 1e18;
    }

    function mockFunction1() external pure returns (bool) {
        return true;
    }

    function mockFunction2() external pure returns (bool) {
        return true;
    }

    function mockFunction3() external pure returns (bool) {
        return true;
    }
}
