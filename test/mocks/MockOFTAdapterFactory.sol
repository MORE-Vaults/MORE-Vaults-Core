// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IOFTAdapterFactory} from "../../src/interfaces/IOFTAdapterFactory.sol";

contract MockOFTAdapterFactory is IOFTAdapterFactory {
    mapping(address => address) public adapters;
    address public endpoint;
    address public owner;

    constructor(address _endpoint, address _owner) {
        endpoint = _endpoint;
        owner = _owner;
    }

    function deployOFTAdapter(address token, bytes32 salt) external returns (address adapter) {
        // Create a mock adapter address based on token and salt
        adapter = address(uint160(uint256(keccak256(abi.encodePacked(token, salt, block.timestamp)))));
        adapters[token] = adapter;
        emit OFTAdapterDeployed(token, adapter, salt);
        return adapter;
    }

    function predictAdapterAddress(address token, bytes32 salt) external pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(token, salt)))));
    }

    function getAdapter(address token) external view returns (address) {
        return adapters[token];
    }

    function hasAdapter(address token) external view returns (bool) {
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
