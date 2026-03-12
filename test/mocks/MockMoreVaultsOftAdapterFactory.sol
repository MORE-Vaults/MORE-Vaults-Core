// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IMoreVaultsOftFactory} from "../../src/interfaces/IMoreVaultsOftFactory.sol";

contract MockMoreVaultsOftAdapterFactory is IMoreVaultsOftFactory {
    mapping(address => address) public adapters;
    address public endpoint;
    address public owner;

    constructor(address _endpoint, address _owner) {
        endpoint = _endpoint;
        owner = _owner;
    }

    function deployOFT(address token, bool isHub, bytes32 salt) external returns (address adapter) {
        if (!isHub) revert InvalidToken();
        adapter = address(uint160(uint256(keccak256(abi.encodePacked(token, salt, block.timestamp)))));
        adapters[token] = adapter;
        emit OFTDeployed(token, adapter, true, salt);
        return adapter;
    }

    function predictOFTAddress(address token, bytes32 salt) external pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(token, salt)))));
    }

    function getOFT(address token) external view returns (address) {
        return adapters[token];
    }

    function hasOFT(address token) external view returns (bool) {
        return adapters[token] != address(0);
    }

    function setEndpoint(address _endpoint) external {
        endpoint = _endpoint;
        emit EndpointUpdated(_endpoint);
    }

    function transferOwnership(address newOwner) external {
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }
}
