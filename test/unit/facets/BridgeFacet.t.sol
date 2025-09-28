// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {BridgeFacetHarness} from "../../mocks/BridgeFacetHarness.sol";
import {MockVaultsFactory} from "../../mocks/MockVaultsFactory.sol";
import {MockMoreVaultsRegistry} from "../../mocks/MockMoreVaultsRegistry.sol";
import {MockOracleRegistry} from "../../mocks/MockOracleRegistry.sol";
import {MockBridgeAdapter} from "../../mocks/MockBridgeAdapter.sol";
import {MockOFT} from "../../mocks/MockOFT.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IBridgeFacet} from "../../../src/interfaces/facets/IBridgeFacet.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IAggregatorV2V3Interface} from "../../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";

contract BridgeFacetTest is Test {
    BridgeFacetHarness public facet;
    MockVaultsFactory public factory;
    MockMoreVaultsRegistry public registry;
    MockOracleRegistry public oracle;
    MockBridgeAdapter public adapter;
    MockOFT public oft;
    MockERC20 public underlying;

    address public owner = address(1);
    address public curator = address(2);
    address public manager = address(3);

    function setUp() public {
        facet = new BridgeFacetHarness();
        factory = new MockVaultsFactory();
        registry = new MockMoreVaultsRegistry();
        oracle = new MockOracleRegistry();
        adapter = new MockBridgeAdapter();
        oft = new MockOFT("OFT", "OFT");
        underlying = new MockERC20("Underlying", "UND");

        // Wire roles and addresses
        MoreVaultsStorageHelper.setOwner(address(facet), owner);
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(registry));
        registry.setOracle(address(oracle));
        MoreVaultsStorageHelper.setFactory(address(facet), address(factory));
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(facet), address(adapter));

        // ERC4626 underlying price used in convertUsdToUnderlying
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(underlying));
        oracle.setAssetPrice(address(underlying), 1e8); // 1 USD
    }

    function _mockHubWithSpokes(uint32 localEid, uint32[] memory eids, address[] memory spokes) internal {
        factory.setLocalEid(localEid);
        factory.setHubToSpokes(localEid, address(facet), eids, spokes);
    }

    // initialize/onFacetRemoval
    function test_initialize_and_onFacetRemoval_flags() public {
        facet.initialize("");
        assertTrue(MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IBridgeFacet).interfaceId));

        facet.onFacetRemoval(false);
        assertFalse(MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IBridgeFacet).interfaceId));
    }

    // setOraclesCrossChainAccounting success path and AlreadySet/NoOracleForSpoke
    function test_setOraclesCrossChainAccounting_enable_success() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);

        // provide oracle info for spoke
        IOracleRegistry.OracleInfo memory info = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0x1111)),
            stalenessThreshold: uint96(1)
        });
        // use helper function in mock to set spoke oracle info
        oracle.setSpokeOracleInfo(address(facet), eids[0], info);

        vm.startPrank(owner);
        facet.setOraclesCrossChainAccounting(true);
        vm.stopPrank();

        assertTrue(MoreVaultsStorageHelper.getOraclesCrossChainAccounting(address(facet)));
    }

    function test_setOraclesCrossChainAccounting_revert_NoOracleForSpoke() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IBridgeFacet.NoOracleForSpoke.selector, eids[0]));
        facet.setOraclesCrossChainAccounting(true);
        vm.stopPrank();
    }

    function test_setOraclesCrossChainAccounting_revert_AlreadySet() public {
        uint32[] memory eids = new uint32[](0);
        address[] memory spokes = new address[](0);
        _mockHubWithSpokes(100, eids, spokes);
        vm.startPrank(owner);
        facet.setOraclesCrossChainAccounting(true);
        vm.expectRevert(IBridgeFacet.AlreadySet.selector);
        facet.setOraclesCrossChainAccounting(true);
        vm.stopPrank();
    }

    // accountingBridgeFacet
    function test_accountingBridgeFacet_sums_spoke_values() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = 101;
        eids[1] = 102;
        address[] memory spokes = new address[](2);
        spokes[0] = address(0xAAA1);
        spokes[1] = address(0xAAA2);
        _mockHubWithSpokes(100, eids, spokes);
        oracle.setSpokeValue(address(facet), 101, 5);
        oracle.setSpokeValue(address(facet), 102, 7);

        (uint256 sum, bool isPositive) = facet.accountingBridgeFacet();
        assertEq(sum, 12);
        assertTrue(isPositive);
    }

    // executeBridging allow/deny
    function test_executeBridging_allows_only_allowed_bridge() public {
        registry.setBridge(address(adapter), true);
        vm.startPrank(curator);
        facet.executeBridging(address(adapter), address(oft), 1 ether, bytes(""));
        vm.stopPrank();
    }

    function test_executeBridging_revert_not_allowed_bridge() public {
        registry.setBridge(address(adapter), false);
        vm.startPrank(curator);
        vm.expectRevert(abi.encodeWithSelector(IBridgeFacet.AdapterNotAllowed.selector, address(adapter)));
        facet.executeBridging(address(adapter), address(oft), 1 ether, bytes(""));
        vm.stopPrank();
    }

    // initVaultActionRequest
    function test_initVaultActionRequest_ok_and_getRequestInfo() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        // manager is adapter in storage
        bytes32 guidVal = keccak256("guid-1");
        adapter.setReceiptGuid(guidVal);
        facet.h_setTotalAssets(100);

        // when oraclesCrossChainAccounting=true must revert, so ensure false
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(10), address(0xCAFE01));
        bytes memory opts = bytes("");
        bytes32 guid = facet.initVaultActionRequest{value: 0}(MoreVaultsLib.ActionType.DEPOSIT, callData, opts);
        assertEq(guid, guidVal);

        // getRequestInfo
        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertEq(info.initiator, address(this));
        assertEq(uint256(info.actionType), uint256(MoreVaultsLib.ActionType.DEPOSIT));
        assertFalse(info.fulfilled);
        assertEq(info.totalAssets, 100);
    }

    function test_initVaultActionRequest_revert_AccountingViaOracles() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), true);
        vm.expectRevert(IBridgeFacet.AccountingViaOracles.selector);
        facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, bytes(""), bytes(""));
    }

    // updateAccountingInfoForRequest
    function test_updateAccountingInfoForRequest_ok_and_unauthorized() public {
        // prepare existing request
        bytes32 guidVal = keccak256("guid-2");
        adapter.setReceiptGuid(guidVal);
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        uint8 decimals = underlying.decimals();
        uint256 initTotalAssets = 200 * 10 ** decimals;
        facet.h_setTotalAssets(initTotalAssets);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);
        bytes32 guid = facet.initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT, abi.encode(uint256(1), address(0xCAFE01)), bytes("")
        );
        assertEq(guid, guidVal);

        uint256 depositedTotalAssetsInUsd = 5 * 10 ** 8;
        // unauthorized caller
        vm.expectRevert(IBridgeFacet.OnlyCrossChainAccountingManager.selector);
        facet.updateAccountingInfoForRequest(guid, depositedTotalAssetsInUsd, true);

        // as manager
        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, depositedTotalAssetsInUsd, true); // 5 USD -> 5 tokens at price 1 USD
        vm.stopPrank();

        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertTrue(info.fulfilled);
        assertEq(info.totalAssets, initTotalAssets + depositedTotalAssetsInUsd * 10 ** 10); // 200 + 5
    }

    function test_updateAccountingInfoForRequest_readFailure_keeps_unfulfilled() public {
        bytes32 guidVal = keccak256("guid-2b");
        adapter.setReceiptGuid(guidVal);
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        facet.h_setTotalAssets(200);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);
        bytes32 guid = facet.initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT, abi.encode(uint256(1), address(0xCAFE01)), bytes("")
        );
        assertEq(guid, guidVal);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 5e8, false);
        vm.stopPrank();

        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertFalse(info.fulfilled);
        assertEq(info.totalAssets, 200);
    }

    // finalizeRequest
    function test_finalizeRequest_success_and_timeout_and_failed_call() public {
        // setup
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        bytes32 guidVal = keccak256("guid-3");
        adapter.setReceiptGuid(guidVal);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);
        bytes memory callData = abi.encode(uint256(10), address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, callData, bytes(""));

        // not fulfilled -> revert
        vm.expectRevert(IBridgeFacet.RequestWasntFulfilled.selector);
        facet.finalizeRequest(guid);

        // mark fulfilled and within timeout
        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);
        vm.stopPrank();

        // success (deposit selector routed to harness stub)
        facet.finalizeRequest(guid);

        // set timestamp to past to trigger timeout
        // move time forward and re-set request to fulfilled to check RequestTimedOut
        // recreate request
        guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, callData, bytes(""));
        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);
        vm.stopPrank();
        // warp 2 hours
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(IBridgeFacet.RequestTimedOut.selector);
        facet.finalizeRequest(guid);
    }
}
