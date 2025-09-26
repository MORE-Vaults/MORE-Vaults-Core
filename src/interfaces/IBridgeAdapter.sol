// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultsFactory} from "./IVaultsFactory.sol";
import {MessagingReceipt, MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title IBridgeAdapter - Common interface for bridge adapters
interface IBridgeAdapter {
    /**
     * @notice Common errors
     */
    error InvalidAmount();
    error InvalidDestChain();
    error UnauthorizedVault();
    error BridgeFailed();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ChainPaused();
    error UntrustedOFT();

    /**
     * @notice Shared events (each adapter has its own specific BridgeExecuted event)
     */
    event ChainPausedEvent(uint256 indexed chainId);
    event ChainUnpausedEvent(uint256 indexed chainId);

    /**
     * @notice Quote fee for read operation
     * @param vaultInfos Array of vault information
     * @param _extraOptions Extra options for the read operation
     * @return fee The fee for the read operation
     */
    function quoteReadFee(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions
    ) external view returns (MessagingFee memory fee);

    /**
     * @notice Execute a cross-chain bridge operation
     * @param bridgeSpecificParams Encoded parameters specific to the bridge implementation
     * @dev Implementation should emit BridgeExecuted event
     */
    function executeBridging(
        bytes calldata bridgeSpecificParams
    ) external payable;

    /**
     * @notice Initiate a cross-chain accounting operation
     * @param vaultInfos Array of vault information
     * @param _extraOptions Extra options for the cross-chain accounting operation
     * @param _initiator The initiator of the cross-chain accounting operation
     * @return receipt The receipt of the cross-chain accounting operation
     */
    function initiateCrossChainAccounting(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt);

    /**
     * @notice Set the LayerZero EID for a specific chain
     * @param chainId Chain ID to set
     * @param eid The LayerZero EID to set
     */
    function setChainIdToEid(uint16 chainId, uint32 eid) external;

    /**
     * @notice Set the LayerZero read channel
     * @param _channelId The channel ID to set
     * @param _active Whether the channel is active
     */
    function setReadChannel(uint32 _channelId, bool _active) external;

    /**
     * @notice Emergency token rescue (admin only)
     * @param token Token to rescue
     * @param to Recipient address
     * @param amount Amount to rescue
     */
    function rescueToken(
        address token,
        address payable to,
        uint256 amount
    ) external;

    /**
     * @notice Get quote for bridge operation
     * @param bridgeSpecificParams Encoded parameters specific to the bridge implementation
     * @return nativeFee The native token fee required for the bridge operation
     */
    function quoteBridgeFee(
        bytes calldata bridgeSpecificParams
    ) external view returns (uint256 nativeFee);

    /**
     * @notice Pause/unpause bridge operations (admin only)
     */
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);

    /**
     * @notice Set supported chain (admin only)
     * @param chainId Chain ID to set
     * @param supported Whether chain is supported
     * @dev If supported=true, use setChainIdToEid instead. If false, removes EID mapping.
     */
    function setSupportedChain(uint256 chainId, bool supported) external;

    /**
     * @notice Pause bridge operations for particular chain(admin only)
     * @param chainId Chain ID to check
     */
    function pauseChain(uint256 chainId) external;
    /**
     * @notice Unpause bridge operations for particular chain(admin only)
     * @param chainId Chain ID to unpause
     */
    function unpauseChain(uint256 chainId) external;

    /**
     * @notice Set slippage (admin only)
     * @param newSlippageBps New slippage in basis points
     */
    function setSlippage(uint256 newSlippageBps) external;

    /**
     * @notice Set composer (admin only)
     * @param _composer Composer address
     */
    function setComposer(address _composer) external;

    /**
     * @notice Get supported chains and their status
     * @return chains Array of supported chain IDs
     * @return statuses Array of chain status (true = active, false = inactive)
     */
    function getSupportedChains()
        external
        view
        returns (uint256[] memory chains, bool[] memory statuses);

    /**
     * @notice Get configuration for a specific chain
     * @param chainId Chain ID to query
     * @return supported Whether chain is supported
     * @return isPaused Whether chain is paused
     * @return additionalInfo Additional adapter-specific information (e.g., transfer mode)
     */
    function getChainConfig(
        uint256 chainId
    )
        external
        view
        returns (bool supported, bool isPaused, string memory additionalInfo);

    /**
     * @notice Get the LayerZero EID for a specific chain
     * @param chainId Chain ID to query
     * @return eid The LayerZero EID for the chain
     */
    function chainIdToEid(uint16 chainId) external view returns (uint32);

    /**
     * @notice Batch set trust status for multiple OFT tokens
     * @param ofts Array of OFT token addresses
     * @param trusted Array of trust statuses (must match ofts length)
     * @dev Moved from VaultsRegistry to adapter for better separation of concerns
     *      Protected against reentrancy in implementations
     */
    function setTrustedOFTs(
        address[] calldata ofts,
        bool[] calldata trusted
    ) external;

    /**
     * @notice Check if an OFT token is trusted for bridging
     * @param oft Address of the OFT token to check
     * @return bool True if the token is trusted, false otherwise
     */
    function isTrustedOFT(address oft) external view returns (bool);

    /**
     * @notice Get all trusted OFT tokens
     * @return address[] Array of trusted OFT addresses
     */
    function getTrustedOFTs() external view returns (address[] memory);
}
