// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOFTAdapterFactory} from "../interfaces/IOFTAdapterFactory.sol";
import {MoreVaultOftAdapter} from "../cross-chain/layerZero/MoreVaultOftAdapter.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OFTAdapterFactory
 * @notice Factory contract for deploying OFT adapters for vault shares
 */
contract OFTAdapterFactory is IOFTAdapterFactory, Ownable {
    /// @dev LayerZero endpoint address
    address public endpoint;

    /// @dev Mapping token => adapter address
    mapping(address => address) public adapters;

    /// @dev Array of all deployed adapters
    address[] public deployedAdapters;

    constructor(address _endpoint, address _owner) Ownable(_owner) {
        if (_endpoint == address(0)) revert ZeroAddress();
        endpoint = _endpoint;
    }

    /**
     * @notice Deploy OFT adapter for a given token
     * @param token The token address to create adapter for
     * @param salt The salt for deterministic deployment
     * @return adapter The address of the deployed adapter
     */
    function deployOFTAdapter(address token, bytes32 salt) external returns (address adapter) {
        if (token == address(0)) revert ZeroAddress();
        if (adapters[token] != address(0)) revert AdapterAlreadyExists(token);

        // Deploy OFT adapter using CREATE3
        adapter = CREATE3.deployDeterministic(
            abi.encodePacked(type(MoreVaultOftAdapter).creationCode, abi.encode(token, endpoint, owner())), salt
        );

        adapters[token] = adapter;
        deployedAdapters.push(adapter);

        emit OFTAdapterDeployed(token, adapter, salt);
    }

    /**
     * @notice Predict the address of an OFT adapter deployed with given salt
     * @param salt The salt for deterministic deployment
     * @return The predicted address of the adapter
     */
    function predictAdapterAddress(address, bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt, address(this));
    }

    /**
     * @notice Get adapter address for a given token
     * @param token The token address
     * @return The adapter address, or address(0) if not deployed
     */
    function getAdapter(address token) external view returns (address) {
        return adapters[token];
    }

    /**
     * @notice Check if adapter exists for a given token
     * @param token The token address
     * @return True if adapter exists
     */
    function hasAdapter(address token) external view returns (bool) {
        return adapters[token] != address(0);
    }

    /**
     * @notice Set LayerZero endpoint address
     * @param _endpoint The new endpoint address
     */
    function setEndpoint(address _endpoint) external onlyOwner {
        if (_endpoint == address(0)) revert ZeroAddress();
        endpoint = _endpoint;
        emit EndpointUpdated(_endpoint);
    }

    /**
     * @notice Get all deployed adapters
     * @return Array of adapter addresses
     */
    function getDeployedAdapters() external view returns (address[] memory) {
        return deployedAdapters;
    }

    /**
     * @notice Get number of deployed adapters
     * @return Number of adapters
     */
    function getAdaptersCount() external view returns (uint256) {
        return deployedAdapters.length;
    }
}
