// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";

contract MockMoreVaultsRegistry is IMoreVaultsRegistry {
    address public oracleAddress;
    mapping(address => bool) public allowedBridges;

    function setOracle(address _oracle) external {
        oracleAddress = _oracle;
    }

    function setBridge(address bridge, bool allowed) external override {
        allowedBridges[bridge] = allowed;
        emit BridgeUpdated(bridge, allowed);
    }

    function isBridgeAllowed(
        address bridge
    ) external view override returns (bool) {
        return allowedBridges[bridge];
    }

    function oracle() external view override returns (IOracleRegistry) {
        return IOracleRegistry(oracleAddress);
    }

    // Unused interface parts for tests
    function initialize(address, address, address) external {}
    function isPermissionless() external pure returns (bool) {
        return false;
    }
    function addFacet(address, bytes4[] calldata) external {}
    function editFacet(address, bytes4[] calldata, bool[] calldata) external {}
    function removeFacet(address) external {}
    function updateOracleRegistry(address) external {}
    function setProtocolFeeInfo(address, address, uint96) external {}
    function setSelectorAndMask(address, bytes4, bool, bytes memory) external {}
    function setDefaultCrossChainAccountingManager(address) external {}
    function getFacetSelectors(
        address
    ) external pure returns (bytes4[] memory) {
        bytes4[] memory a;
        return a;
    }
    function getAllowedFacets() external pure returns (address[] memory) {
        address[] memory a;
        return a;
    }
    function protocolFeeInfo(address) external pure returns (address, uint96) {
        return (address(0), 0);
    }
    function selectorToFacet(bytes4) external pure returns (address) {
        return address(0);
    }
    function facetsList(uint256) external pure returns (address) {
        return address(0);
    }
    function getDenominationAssetDecimals() external pure returns (uint8) {
        return 18;
    }
    function getDenominationAsset() external pure returns (address) {
        return address(0);
    }
    function isFacetAllowed(address) external pure returns (bool) {
        return true;
    }
    function addToWhitelist(address) external {}
    function removeFromWhitelist(address) external {}
    function isWhitelisted(address) external pure returns (bool) {
        return true;
    }
    function selectorInfo(
        address,
        bytes4
    ) external pure returns (bool, bytes memory) {
        return (true, "");
    }
    function isCrossChainAccountingManager(
        address
    ) external pure returns (bool) {
        return false;
    }
    function defaultCrossChainAccountingManager()
        external
        pure
        returns (address)
    {
        return address(0);
    }
}
