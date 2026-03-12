// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMoreVaultsOftFactory} from "../interfaces/IMoreVaultsOftFactory.sol";
import {MoreVaultOftAdapter} from "../cross-chain/layerZero/MoreVaultOftAdapter.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MoreVaultsOftAdapterFactory
 * @notice Factory contract for deploying OFT adapters for hub vault shares
 */
contract MoreVaultsOftAdapterFactory is Initializable, IMoreVaultsOftFactory, OwnableUpgradeable {
    /// @dev LayerZero endpoint address
    address public endpoint;

    /// @dev Mapping token => OFT address
    mapping(address => address) public OFTs;

    /// @dev Array of all deployed OFTs
    address[] public deployedOFTs;

    /// @dev Factory address
    address public factory;

    event FactoryUpdated(address indexed newFactory);

    function initialize(address _endpoint, address _owner, address _factory) external initializer {
        if (_endpoint == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        endpoint = _endpoint;
        factory = _factory;
    }

    /**
     * @notice Deploy OFT adapter for a given token
     * @param token The token address to create OFT adapter for
     * @param isHub Whether the vault is a hub vault. Must be true for this factory
     * @param salt The salt for deterministic deployment
     * @return oft The address of the deployed OFT adapter
     */
    function deployOFT(address token, bool isHub, bytes32 salt) external returns (address oft) {
        if (factory != msg.sender && msg.sender != owner()) revert OwnableUnauthorizedAccount(msg.sender);
        if (token == address(0)) revert ZeroAddress();
        if (OFTs[token] != address(0)) revert OFTAlreadyExists(token);
        if (!isHub) revert InvalidToken();

        oft = CREATE3.deployDeterministic(
            abi.encodePacked(type(MoreVaultOftAdapter).creationCode, abi.encode(token, endpoint, owner())), salt
        );

        OFTs[token] = oft;
        deployedOFTs.push(oft);

        emit OFTDeployed(token, oft, true, salt);
    }

    /**
     * @notice Predict the address of an OFT deployed with given salt
     * @param salt The salt for deterministic deployment
     * @return The predicted address of the OFT
     */
    function predictOFTAddress(address, bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt, address(this));
    }

    /**
     * @notice Get OFT address for a given token
     * @param token The token address
     * @return The OFT address, or address(0) if not deployed
     */
    function getOFT(address token) external view returns (address) {
        return OFTs[token];
    }

    /**
     * @notice Check if adapter exists for a given token
     * @param token The token address
     * @return True if adapter exists
     */
    function hasOFT(address token) external view returns (bool) {
        return OFTs[token] != address(0);
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
     * @notice Set authorized VaultsFactory address
     * @param _factory The new factory address
     */
    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
        emit FactoryUpdated(_factory);
    }

    /**
     * @notice Get all deployed OFTs
     * @return Array of OFT addresses
     */
    function getDeployedOFTs() external view returns (address[] memory) {
        return deployedOFTs;
    }

    /**
     * @notice Get number of deployed OFTs
     * @return Number of adapters
     */
    function getOFTsCount() external view returns (uint256) {
        return deployedOFTs.length;
    }
}
