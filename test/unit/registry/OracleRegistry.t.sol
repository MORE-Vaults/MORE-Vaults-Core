// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {OracleRegistry, IOracleRegistry} from "../../../src/registry/OracleRegistry.sol";
import {IAggregatorV2V3Interface} from "../../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";

contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals = 8;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

contract OracleRegistryTest is Test {
    OracleRegistry public registry;
    address public admin = address(1);
    address public asset = address(2);
    address public baseCurrency = address(3);
    uint256 public baseCurrencyUnit = 1e8;
    uint96 public staleness = 1 hours;

    function setUp() public {
        vm.prank(admin);
        registry = new OracleRegistry();

        skip(1 hours);
    }

    function test_initialize_setsValuesAndRoles() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        assertEq(registry.BASE_CURRENCY(), baseCurrency);
        assertEq(registry.BASE_CURRENCY_UNIT(), baseCurrencyUnit);
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.ORACLE_MANAGER_ROLE(), admin));

        assertEq(address(registry.getOracleInfo(asset).aggregator), address(infos[0].aggregator));
        assertEq(registry.getOracleInfo(asset).stalenessThreshold, staleness);
    }

    function test_setOracleInfos_setsInfoCorrectly() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(200, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.startPrank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        registry.setOracleInfos(assets, infos);
        IOracleRegistry.OracleInfo memory info = registry.getOracleInfo(asset);
        assertEq(address(info.aggregator), address(infos[0].aggregator));
        assertEq(info.stalenessThreshold, staleness);
        vm.stopPrank();
    }

    function test_setOracleInfos_revertsOnLengthMismatch() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](0);
        vm.prank(admin);
        registry.initialize(assets, new IOracleRegistry.OracleInfo[](1), admin, baseCurrency, baseCurrencyUnit);
        vm.prank(admin);
        vm.expectRevert(IOracleRegistry.InconsistentParamsLength.selector);
        registry.setOracleInfos(assets, infos);
    }

    function test_setOracleInfos_revert_ifAggregatorNotSet() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(123, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        vm.prank(admin);
        IOracleRegistry.OracleInfo[] memory incorrectInfos = new IOracleRegistry.OracleInfo[](1);
        incorrectInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0)), stalenessThreshold: staleness
        });
        vm.expectRevert(IOracleRegistry.AggregatorNotSet.selector);
        registry.setOracleInfos(assets, incorrectInfos);
    }

    function test_getAssetPrice_returnsCorrectPrice() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(123, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        uint256 price = registry.getAssetPrice(asset);
        assertEq(price, 123);
    }

    function test_getAssetsPrices_returnsCorrectPrices() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(123, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        uint256[] memory prices = registry.getAssetsPrices(assets);
        assertEq(prices.length, 1);
        assertEq(prices[0], 123);
    }

    function test_getAssetPrice_returnsBaseCurrencyUnitForBaseCurrency() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(123, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        uint256 price = registry.getAssetPrice(baseCurrency);
        assertEq(price, baseCurrencyUnit);
    }

    function test_getAssetPrice_revertsIfPriceIsOld() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(123, block.timestamp - staleness - 1))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        vm.expectRevert(IOracleRegistry.OraclePriceIsOld.selector);
        registry.getAssetPrice(asset);
    }

    function test_getAssetPrice_revertsIfPriceIsNegativeOrZero() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(0, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);
        vm.expectRevert(IOracleRegistry.PriceIsNotAvailable.selector);
        registry.getAssetPrice(asset);
    }

    function test_mockAggregator_latestAnswer() public {
        MockAggregator mockAgg = new MockAggregator(42e8, block.timestamp);

        int256 latestAnswer = mockAgg.latestAnswer();
        assertEq(latestAnswer, 42e8);
    }

    function test_setSpokeOracleInfos_success() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x123);
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = 101;
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(500, block.timestamp))),
            stalenessThreshold: staleness
        });

        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        IOracleRegistry.OracleInfo memory retrieved = registry.getSpokeOracleInfo(hub, chainIds[0]);
        assertEq(address(retrieved.aggregator), address(spokeInfos[0].aggregator));
        assertEq(retrieved.stalenessThreshold, staleness);
    }

    function test_setSpokeOracleInfos_revertsOnLengthMismatch() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x123);
        uint32[] memory chainIds = new uint32[](2);
        chainIds[0] = 101;
        chainIds[1] = 102;
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);

        vm.prank(admin);
        vm.expectRevert(IOracleRegistry.InconsistentParamsLength.selector);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);
    }

    function test_getSpokeValue_returnsCorrectValue() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x123);
        uint32 chainId = 101;
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = chainId;
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(777, block.timestamp))),
            stalenessThreshold: staleness
        });

        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        uint256 value = registry.getSpokeValue(hub, chainId);
        assertEq(value, 777);
    }

    function test_getSpokeValue_withStorkOracle() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x123);
        uint32 chainId = 101;
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = chainId;

        uint256 storkTimestamp = block.timestamp * 1e9;
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(888, storkTimestamp))),
            stalenessThreshold: staleness
        });

        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        uint256 value = registry.getSpokeValue(hub, chainId);
        assertEq(value, 888);
    }

    function test_getSpokeValue_revertsIfStale() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x123);
        uint32 chainId = 101;
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = chainId;

        uint256 staleTimestamp = block.timestamp - staleness - 1;
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(999, staleTimestamp))),
            stalenessThreshold: staleness
        });

        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        vm.expectRevert(IOracleRegistry.OraclePriceIsOld.selector);
        registry.getSpokeValue(hub, chainId);
    }

    function test_getSpokeOracleInfo_returnsCorrectInfo() public {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(new MockAggregator(100, block.timestamp))),
            stalenessThreshold: staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, baseCurrencyUnit);

        address hub = address(0x456);
        uint32 chainId = 202;
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = chainId;
        MockAggregator mockAgg = new MockAggregator(1234, block.timestamp);
        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(mockAgg)), stalenessThreshold: 2 hours
        });

        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        IOracleRegistry.OracleInfo memory retrieved = registry.getSpokeOracleInfo(hub, chainId);
        assertEq(address(retrieved.aggregator), address(mockAgg));
        assertEq(retrieved.stalenessThreshold, 2 hours);
    }
}
