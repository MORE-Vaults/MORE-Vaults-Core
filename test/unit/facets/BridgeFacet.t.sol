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
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";

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
            aggregator: IAggregatorV2V3Interface(address(0x1111)), stalenessThreshold: uint96(1)
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
        oracle.setSpokeValue(address(facet), 101, 5e8);
        oracle.setSpokeValue(address(facet), 102, 7e8);

        // underlying price is 1 USD (1e8), so 12e8 USD = 12e18 underlying
        (uint256 sum, bool isPositive) = facet.accountingBridgeFacet();
        assertEq(sum, 12e18);
        assertTrue(isPositive);
    }

    /**
     * @notice Issue #41 - accountingBridgeFacet should convert USD to underlying asset
     * @dev When underlying asset price != 1 USD, the conversion must be applied
     */
    function test_accountingBridgeFacet_converts_usd_to_underlying() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xAAA1);
        _mockHubWithSpokes(100, eids, spokes);

        // Spoke value is 1000 USD (with 8 decimals like chainlink)
        uint256 spokeUsdValue = 1000e8;
        oracle.setSpokeValue(address(facet), 101, spokeUsdValue);

        // Underlying asset price is 2 USD (so 1000 USD = 500 underlying tokens)
        oracle.setAssetPrice(address(underlying), 2e8);

        (uint256 sum, bool isPositive) = facet.accountingBridgeFacet();

        // Expected: 1000 USD / 2 USD per token = 500 tokens (with 18 decimals)
        uint256 expectedUnderlying = 500e18;
        assertEq(sum, expectedUnderlying, "Should convert USD value to underlying asset amount");
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
        facet.h_setTotalAssets(100 * 1e18);

        // when oraclesCrossChainAccounting=true must revert, so ensure false
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(10 * 1e18), address(0xCAFE01));
        bytes memory opts = bytes("");
        bytes32 guid = facet.initVaultActionRequest{value: 0}(MoreVaultsLib.ActionType.DEPOSIT, callData, 0, opts);
        assertEq(guid, guidVal);

        // getRequestInfo
        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertEq(info.initiator, address(this));
        assertEq(uint256(info.actionType), uint256(MoreVaultsLib.ActionType.DEPOSIT));
        assertFalse(info.fulfilled);
        assertEq(info.totalAssets, 100 * 1e18);
    }

    function test_initVaultActionRequest_revert_NotEnoughMsgValueProvided() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        // manager is adapter in storage
        bytes32 guidVal = keccak256("guid-1");
        adapter.setReceiptGuid(guidVal);
        facet.h_setTotalAssets(100 * 1e18);

        // when oraclesCrossChainAccounting=true must revert, so ensure false
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes memory callData = abi.encode(tokens, amounts, address(0xCAFE01), 1 ether);
        bytes memory opts = bytes("");
        vm.expectRevert(IBridgeFacet.NotEnoughMsgValueProvided.selector);
        facet.initVaultActionRequest{value: 0.99 ether}(
            MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, callData, 0, opts
        );

        adapter.setFee(0.05 ether, 0);
        vm.expectRevert(IBridgeFacet.NotEnoughMsgValueProvided.selector);
        facet.initVaultActionRequest{value: 1.04 ether}(
            MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, callData, 0, opts
        );

        bytes32 guid = facet.initVaultActionRequest{value: 1.05 ether}(
            MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, callData, 0, opts
        );
        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertEq(info.initiator, address(this));
        assertEq(uint256(info.actionType), uint256(MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT));
        assertFalse(info.fulfilled);
        assertFalse(info.finalized);
        assertEq(info.totalAssets, 100 * 1e18);
    }

    function test_initVaultActionRequest_revert_AccountingViaOracles() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), true);
        vm.expectRevert(IBridgeFacet.AccountingViaOracles.selector);
        facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, bytes(""), 0, bytes(""));
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
            MoreVaultsLib.ActionType.DEPOSIT, abi.encode(uint256(5 * 10 ** decimals), address(0xCAFE01)), 0, bytes("")
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
        facet.h_setTotalAssets(200 * 1e18);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);
        bytes32 guid = facet.initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT, abi.encode(uint256(1), address(0xCAFE01)), 0, bytes("")
        );
        assertEq(guid, guidVal);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 5e8, false);
        vm.stopPrank();

        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertFalse(info.fulfilled);
        assertEq(info.totalAssets, 200 * 1e18);
    }

    function test_setOraclesCrossChainAccounting_disable_removes_facet() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);

        IOracleRegistry.OracleInfo memory info = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0x1111)), stalenessThreshold: uint96(1)
        });
        oracle.setSpokeOracleInfo(address(facet), eids[0], info);

        vm.startPrank(owner);
        facet.setOraclesCrossChainAccounting(true);
        facet.setOraclesCrossChainAccounting(false);
        vm.stopPrank();

        assertFalse(MoreVaultsStorageHelper.getOraclesCrossChainAccounting(address(facet)));
    }

    // Issue #43: Disabling oracle accounting should work even when spokes have balance > 10e4
    function test_setOraclesCrossChainAccounting_disable_works_when_spokes_have_balance() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);

        IOracleRegistry.OracleInfo memory info = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0x1111)), stalenessThreshold: uint96(1)
        });
        oracle.setSpokeOracleInfo(address(facet), eids[0], info);
        // Set spoke value to more than 10e4 threshold (in USD, will be converted to underlying)
        oracle.setSpokeValue(address(facet), eids[0], 1e8); // 1 USD in 8 decimals

        vm.startPrank(owner);
        facet.setOraclesCrossChainAccounting(true);
        assertTrue(facet.oraclesCrossChainAccounting());

        // Should NOT revert - the spoke funds are remote, not local
        facet.setOraclesCrossChainAccounting(false);
        assertFalse(facet.oraclesCrossChainAccounting());
        vm.stopPrank();
    }

    // Issue #43: Disabling oracle accounting should work even when oracle fails
    function test_setOraclesCrossChainAccounting_disable_works_when_oracle_fails() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);

        IOracleRegistry.OracleInfo memory info = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0x1111)), stalenessThreshold: uint96(1)
        });
        oracle.setSpokeOracleInfo(address(facet), eids[0], info);

        vm.startPrank(owner);
        facet.setOraclesCrossChainAccounting(true);
        assertTrue(facet.oraclesCrossChainAccounting());
        vm.stopPrank();

        // Simulate oracle failure
        oracle.setSpokeShouldRevert(address(facet), eids[0], true);

        vm.startPrank(owner);
        // Should NOT revert - admin needs to disable oracle accounting when oracle fails
        facet.setOraclesCrossChainAccounting(false);
        assertFalse(facet.oraclesCrossChainAccounting());
        vm.stopPrank();
    }

    function test_quoteAccountingFee_returns_native_fee() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, vaults);

        adapter.setFee(0.05 ether, 0);
        uint256 fee = facet.quoteAccountingFee(bytes(""));
        assertEq(fee, 0.05 ether);
    }

    function test_executeRequest_MINT() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-mint"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(100), address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.MINT, callData, 0, bytes(""));

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        facet.executeRequest(guid);
        vm.stopPrank();
    }

    function test_executeRequest_should_revert_if_already_finalized() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-mint"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(100), address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.MINT, callData, 0, bytes(""));

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        facet.executeRequest(guid);

        vm.expectRevert(IBridgeFacet.RequestAlreadyFinalized.selector);
        facet.executeRequest(guid);
        vm.stopPrank();
    }

    function test_executeRequest_WITHDRAW() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-withdraw"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(50), address(this), address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.WITHDRAW, callData, 0, bytes(""));

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        facet.executeRequest(guid);
        vm.stopPrank();
    }

    function test_executeRequest_REDEEM() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-redeem"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        bytes memory callData = abi.encode(uint256(75), address(this), address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.REDEEM, callData, 0, bytes(""));

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        facet.executeRequest(guid);
        vm.stopPrank();
    }

    function test_executeRequest_MULTI_ASSETS_DEPOSIT() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-multiasset"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        bytes memory callData = abi.encode(tokens, amounts, address(this), uint256(0));
        bytes32 guid =
            facet.initVaultActionRequest(MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, callData, 0, bytes(""));

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        facet.executeRequest(guid);
        vm.stopPrank();
    }

    // ============ Slippage tests ============

    /**
     * @notice Test that executeRequest reverts when slippage exceeds minAmountOut for DEPOSIT
     * @dev Slippage check happens in executeRequest, not in sendDepositShares
     */
    function test_executeRequest_DEPOSIT_reverts_on_slippage() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-deposit-slippage"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        uint256 assets = 100e18;
        uint256 minAmountOut = 150e18; // Expect at least 150 shares
        bytes memory callData = abi.encode(assets, address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, callData, minAmountOut, bytes(""));

        // Set deposit result to be less than minAmountOut (simulating unfavorable price movement)
        uint256 actualShares = 100e18; // Less than minAmountOut (150e18)
        facet.h_setDepositResult(guid, actualShares);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        // Expect revert with SlippageExceeded error
        vm.expectRevert(abi.encodeWithSelector(IBridgeFacet.SlippageExceeded.selector, actualShares, minAmountOut));
        facet.executeRequest(guid);
        vm.stopPrank();
    }

    /**
     * @notice Test that executeRequest succeeds when result meets minAmountOut for DEPOSIT
     */
    function test_executeRequest_DEPOSIT_succeeds_when_slippage_ok() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-deposit-ok"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        uint256 assets = 100e18;
        uint256 minAmountOut = 150e18; // Expect at least 150 shares
        bytes memory callData = abi.encode(assets, address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, callData, minAmountOut, bytes(""));

        // Set deposit result to meet minAmountOut
        uint256 actualShares = 160e18; // More than minAmountOut (150e18)
        facet.h_setDepositResult(guid, actualShares);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        // Should succeed
        facet.executeRequest(guid);
        vm.stopPrank();
    }

    /**
     * @notice Test that executeRequest succeeds when result meets minAmountOut for DEPOSIT
     */
    function test_executeRequest_DEPOSIT_reverts_if_in_multicall() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-deposit-ok"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        uint256 assets = 100e18;
        uint256 minAmountOut = 150e18; // Expect at least 150 shares
        bytes memory callData = abi.encode(assets, address(this));
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.DEPOSIT, callData, minAmountOut, bytes(""));
    }

    /**
     * @notice Test that executeRequest reverts when slippage exceeds minAmountOut for MINT
     */
    function test_executeRequest_MINT_reverts_on_slippage() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-mint-slippage"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        uint256 shares = 100e18;
        uint256 minAmountOut = 150e18; // Expect at least 150 assets
        bytes memory callData = abi.encode(shares, address(this));
        bytes32 guid = facet.initVaultActionRequest(MoreVaultsLib.ActionType.MINT, callData, minAmountOut, bytes(""));

        // Set mint result to be less than minAmountOut
        uint256 actualAssets = 100e18; // Less than minAmountOut (150e18)
        facet.h_setMintResult(guid, actualAssets);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        // Expect revert with SlippageExceeded error
        vm.expectRevert(abi.encodeWithSelector(IBridgeFacet.SlippageExceeded.selector, actualAssets, minAmountOut));
        facet.executeRequest(guid);
        vm.stopPrank();
    }

    /**
     * @notice Test that executeRequest reverts when slippage exceeds minAmountOut for MULTI_ASSETS_DEPOSIT
     */
    function test_executeRequest_MULTI_ASSETS_DEPOSIT_reverts_on_slippage() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        _mockHubWithSpokes(100, eids, spokes);
        adapter.setReceiptGuid(keccak256("guid-multiasset-slippage"));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        uint256 minAmountOut = 150e18; // Expect at least 150 shares
        bytes memory callData = abi.encode(tokens, amounts, address(this), uint256(0));
        bytes32 guid = facet.initVaultActionRequest(
            MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT, callData, minAmountOut, bytes("")
        );

        // Set deposit result to be less than minAmountOut
        uint256 actualShares = 100e18; // Less than minAmountOut (150e18)
        facet.h_setDepositResult(guid, actualShares);

        vm.startPrank(address(adapter));
        facet.updateAccountingInfoForRequest(guid, 0, true);

        // Expect revert with SlippageExceeded error
        vm.expectRevert(abi.encodeWithSelector(IBridgeFacet.SlippageExceeded.selector, actualShares, minAmountOut));
        facet.executeRequest(guid);
        vm.stopPrank();
    }
}
