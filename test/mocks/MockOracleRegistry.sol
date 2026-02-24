// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IAggregatorV2V3Interface} from "../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";

contract MockOracleRegistry is IOracleRegistry {
    mapping(address => uint256) public prices;

    struct SpokeKey {
        address hub;
        uint32 eid;
    }

    mapping(bytes32 => uint256) public spokeValues;
    mapping(bytes32 => OracleInfo) public spokeInfos;
    mapping(bytes32 => bool) public spokeShouldRevert;

    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function setSpokeValue(address hub, uint32 eid, uint256 value) external {
        spokeValues[keccak256(abi.encode(hub, eid))] = value;
    }

    function setSpokeOracleInfo(address hub, uint32 eid, OracleInfo calldata info) external {
        spokeInfos[keccak256(abi.encode(hub, eid))] = info;
    }

    function setSpokeShouldRevert(address hub, uint32 eid, bool shouldRevert) external {
        spokeShouldRevert[keccak256(abi.encode(hub, eid))] = shouldRevert;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }

    function getAssetsPrices(address[] calldata assets) external view override returns (uint256[] memory out) {
        out = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            out[i] = prices[assets[i]];
        }
    }

    function getOracleInfo(address) external pure override returns (OracleInfo memory) {
        return OracleInfo(IAggregatorV2V3Interface(address(0)), 0);
    }

    function getSpokeValue(address hub, uint32 chainId) external view override returns (uint256) {
        bytes32 key = keccak256(abi.encode(hub, chainId));
        if (spokeShouldRevert[key]) {
            revert("Oracle failed");
        }
        return spokeValues[key];
    }

    function getSpokeOracleInfo(address hub, uint32 chainId) external view override returns (OracleInfo memory) {
        return spokeInfos[keccak256(abi.encode(hub, chainId))];
    }

    // Unused
    function BASE_CURRENCY() external pure returns (address) {
        return address(0);
    }

    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1e8;
    }

    function setOracleInfos(address[] calldata, OracleInfo[] calldata) external {}
    function setSpokeOracleInfos(address, uint32[] calldata, OracleInfo[] calldata) external {}
}
