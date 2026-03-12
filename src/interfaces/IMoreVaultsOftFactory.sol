// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IMoreVaultsOftFactory
 * @notice Interface for OFT Adapter Factory contract
 */
interface IMoreVaultsOftFactory {
    error ZeroAddress();
    error InvalidToken();
    error OFTAlreadyExists(address token);
    error OFTNotDeployed(address token);

    event OFTDeployed(address indexed token, address indexed oft, bool isAdapter, bytes32 salt);
    event EndpointUpdated(address indexed newEndpoint);
    event OwnerUpdated(address indexed newOwner);

    /**
     * @notice Deploy OFT adapter for a given token
     * @param token The token address to create adapter for
     * @param isHub Whether the vault is a hub vault
     * @param salt The salt for deterministic deployment
     * @return oft The address of the deployed OFT
     */
    function deployOFT(address token, bool isHub, bytes32 salt) external returns (address oft);

    /**
     * @notice Predict the address of an OFT deployed with given salt
     * @param token The token address
     * @param salt The salt for deterministic deployment
     * @return The predicted address of the OFT
     */
    function predictOFTAddress(address token, bytes32 salt) external view returns (address);

    /**
     * @notice Get OFT address for a given token
     * @param token The token address
     * @return The OFT address, or address(0) if not deployed
     */
    function getOFT(address token) external view returns (address);

    /**
     * @notice Check if OFT exists for a given token
     * @param token The token address
     * @return True if OFT exists
     */
    function hasOFT(address token) external view returns (bool);

    /**
     * @notice Get LayerZero endpoint address
     * @return The endpoint address
     */
    function endpoint() external view returns (address);

    /**
     * @notice Set LayerZero endpoint address
     * @param _endpoint The new endpoint address
     */
    function setEndpoint(address _endpoint) external;
}
