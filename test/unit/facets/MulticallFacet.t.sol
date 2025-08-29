// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {BaseFacetInitializer, IMulticallFacet, MulticallFacet} from "../../../src/facets/MulticallFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";

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
        MoreVaultsStorageHelper.setTimeLockPeriod(
            address(facet),
            timeLockPeriod
        );

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
        assertEq(
            facet.facetName(),
            "MulticallFacet",
            "Facet name should be correct"
        );
    }

    function test_initialize_ShouldSetParametersCorrectly() public {
        MulticallFacet(facet).initialize(abi.encode(timeLockPeriod, 10_000));
        assertEq(
            MoreVaultsStorageHelper.getTimeLockPeriod(address(facet)),
            timeLockPeriod,
            "Time lock period should be set"
        );
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IMulticallFacet).interfaceId
            ),
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
        (bytes[] memory storedActions, uint256 pendingUntil) = facet
            .getPendingActions(nonce);
        assertEq(
            storedActions.length,
            actionsData.length,
            "Actions length should match"
        );
        assertEq(
            pendingUntil,
            block.timestamp + timeLockPeriod,
            "Pending until should be correct"
        );

        vm.stopPrank();
    }

    function test_submitActions_ShouldExecuteActionsIfTimeLockPeriodIsZero()
        public
    {
        vm.startPrank(curator);

        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), 0);

        // Mock function calls
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("mockFunction1()"),
            abi.encode()
        );
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("mockFunction2()"),
            abi.encode()
        );
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(1e18)
        );

        vm.expectEmit();
        emit IMulticallFacet.ActionsSubmitted(
            curator,
            currentNonce,
            block.timestamp,
            actionsData
        );
        vm.expectEmit();
        emit IMulticallFacet.ActionsExecuted(curator, currentNonce);
        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Verify pending actions
        (bytes[] memory storedActions, uint256 pendingUntil) = facet
            .getPendingActions(nonce);
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
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("mockFunction1()"),
            abi.encode()
        );
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("mockFunction2()"),
            abi.encode()
        );
        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(1e18)
        );

        // Fast forward time
        vm.warp(block.timestamp + timeLockPeriod + 1);

        // Execute actions
        facet.executeActions(nonce);

        // Verify actions were deleted
        (bytes[] memory storedActions, uint256 pendingUntil) = facet
            .getPendingActions(nonce);
        assertEq(storedActions.length, 0, "Actions should be deleted");
        assertEq(pendingUntil, 0, "Pending until should be zero");

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenActionsStillPending() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Attempt to execute actions before time lock period
        vm.expectRevert(
            abi.encodeWithSelector(
                IMulticallFacet.ActionsStillPending.selector,
                nonce
            )
        );
        facet.executeActions(nonce);

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenNoSuchActions() public {
        vm.startPrank(curator);

        // Attempt to execute non-existent actions
        vm.expectRevert(
            abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, 999)
        );
        facet.executeActions(999);

        vm.stopPrank();
    }

    function test_executeActions_ShouldRevertWhenMulticallFailed() public {
        vm.startPrank(curator);

        // Submit actions
        uint256 nonce = facet.submitActions(actionsData);

        // Fast forward time
        vm.warp(block.timestamp + timeLockPeriod + 1);

        vm.mockCall(
            address(facet),
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(1e18)
        );

        // Attempt to execute actions
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("MulticallFailed(uint256,bytes)")),
                0,
                ""
            )
        );
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
        (bytes[] memory storedActions, uint256 pendingUntil) = facet
            .getPendingActions(nonce[0]);
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
        vm.expectRevert(
            abi.encodeWithSelector(IMulticallFacet.NoSuchActions.selector, 999)
        );
        facet.vetoActions(nonce);

        vm.stopPrank();
    }

    function test_getPendingActions_ShouldReturnCorrectData() public {
        vm.startPrank(curator);

        // Submit actions
        uint256[] memory nonce = new uint256[](1);
        nonce[0] = facet.submitActions(actionsData);

        // Get pending actions
        (bytes[] memory storedActions, uint256 pendingUntil) = facet
            .getPendingActions(nonce[0]);

        // Verify data
        assertEq(
            storedActions.length,
            actionsData.length,
            "Actions length should match"
        );
        assertEq(
            pendingUntil,
            block.timestamp + timeLockPeriod,
            "Pending until should be correct"
        );

        vm.stopPrank();
    }

    function test_getCurrentNonce_ShouldReturnCorrectNonce() public view {
        assertEq(
            facet.getCurrentNonce(),
            currentNonce,
            "Current nonce should match"
        );
    }
}