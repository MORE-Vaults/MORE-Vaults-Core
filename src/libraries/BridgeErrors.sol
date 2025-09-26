// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BridgeErrors
 * @notice Consolidated error definitions for bridge adapters
 * @dev This library provides a common set of errors that can be used across
 *      different bridge adapter implementations, promoting consistency and
 *      reducing code duplication.
 */
library BridgeErrors {
    /**
     * @notice Thrown when an invalid amount is provided (e.g., zero amount)
     */
    error InvalidAmount();

    /**
     * @notice Thrown when an invalid destination chain ID is provided
     */
    error InvalidDestChain();

    /**
     * @notice Thrown when a non-vault address attempts to call vault-only functions
     */
    error UnauthorizedVault();

    /**
     * @notice Thrown when a bridge operation fails
     */
    error BridgeFailed();

    /**
     * @notice Thrown when insufficient balance for the operation
     */
    error InsufficientBalance();

    /**
     * @notice Thrown when insufficient token allowance for the operation
     */
    error InsufficientAllowance();

    /**
     * @notice Thrown when operations are attempted on a paused chain
     */
    error ChainPaused();

    /**
     * @notice Thrown when an untrusted OFT token is used for bridging
     */
    error UntrustedOFT();

    /**
     * @notice Thrown when a zero address is provided where it's not allowed
     */
    error ZeroAddress();

    /**
     * @notice Thrown when array lengths don't match in batch operations
     */
    error ArrayLengthMismatch();

    /**
     * @notice Thrown when an invalid OFT token address is provided
     */
    error InvalidOFTToken();

    /**
     * @notice Thrown when an invalid LayerZero EID is provided
     */
    error InvalidLayerZeroEid();

    /**
     * @notice Thrown when no responses are received for read operations
     */
    error NoResponses();

    /**
     * @notice Thrown when an unsupported chain is used
     * @param chainId The unsupported chain ID
     */
    error UnsupportedChain(uint16 chainId);

    /**
     * @notice Thrown when comprehensive bridge parameter validation fails
     * @dev Used for gas-optimized validation that checks multiple parameters at once
     */
    error InvalidBridgeParams();
}