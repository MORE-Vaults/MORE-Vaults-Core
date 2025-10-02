// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IOFTAdapterFactory
 * @notice Interface for OFT Adapter Factory contract
 */
interface IOFTAdapterFactory {
    error ZeroAddress();
    error InvalidToken();
    error AdapterAlreadyExists(address token);
    error AdapterNotDeployed(address token);

    event OFTAdapterDeployed(address indexed token, address indexed adapter, bytes32 salt);
    event EndpointUpdated(address indexed newEndpoint);
    event OwnerUpdated(address indexed newOwner);

    /**
     * @notice Deploy OFT adapter for a given token
     * @param token The token address to create adapter for
     * @param salt The salt for deterministic deployment
     * @return adapter The address of the deployed adapter
     */
    function deployOFTAdapter(address token, bytes32 salt) external returns (address adapter);

    /**
     * @notice Predict the address of an OFT adapter deployed with given salt
     * @param token The token address
     * @param salt The salt for deterministic deployment
     * @return The predicted address of the adapter
     */
    function predictAdapterAddress(address token, bytes32 salt) external view returns (address);

    /**
     * @notice Get adapter address for a given token
     * @param token The token address
     * @return The adapter address, or address(0) if not deployed
     */
    function getAdapter(address token) external view returns (address);

    /**
     * @notice Check if adapter exists for a given token
     * @param token The token address
     * @return True if adapter exists
     */
    function hasAdapter(address token) external view returns (bool);

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
