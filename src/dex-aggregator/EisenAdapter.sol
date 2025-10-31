// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/**
 * @title EisenAdapter
 * @notice Adapter for Eisen Finance DEX aggregator
 * @dev Eisen uses an off-chain API that returns ready-to-execute transaction data
 *
 *      How to use:
 *      1. Call Eisen API off-chain: GET /v1/quote with X-EISEN-KEY header
 *      2. API returns result.transactionRequest with:
 *         - to: router address for the specific chain
 *         - data: complete calldata for the swap
 *         - value: ETH value if swapping native token
 *      3. Pass the API's calldata to buildSwapCalldataWithParams
 *      4. Use with DexAggregatorFacet.executeSwap()
 *
 *      Eisen supports 22+ chains with dynamic router addresses per chain.
 *      No hardcoded routers needed - everything comes from the API.
 */
contract EisenAdapter is IDexAdapter {
    string public constant ADAPTER_NAME = "Eisen Finance";

    /// @notice Returns the adapter name
    function adapterName() external pure override returns (string memory) {
        return ADAPTER_NAME;
    }

    /// @notice Not applicable - router address comes from Eisen API quote
    /// @dev The router is in result.transactionRequest.to from the API response
    function getRouterAddress() external pure override returns (address) {
        revert RouterNotSet();
    }

    /// @notice Not applicable - Eisen uses off-chain API for quotes
    function getQuoterAddress() external pure override returns (address) {
        revert QuoterNotAvailable();
    }

    /// @notice Eisen supports 22+ chains dynamically
    /// @dev Always returns true - let Eisen API validate chain support
    function isChainSupported(uint256) external pure override returns (bool) {
        return true;
    }

    /// @notice Returns supported chains
    /// @dev Not applicable - Eisen's chain support is dynamic and managed off-chain
    function getSupportedChains() external pure override returns (uint256[] memory) {
        // Return empty array since chains are managed by Eisen API
        return new uint256[](0);
    }

    /// @notice Not applicable - quotes come from off-chain Eisen API
    /// @dev Use Eisen API endpoint: GET /v1/quote
    ///      The API returns result.estimate.toAmount (expected output amount)
    function getQuote(address, address, uint256) external pure override returns (uint256) {
        revert QuoterNotAvailable();
    }

    /// @notice Estimates gas for a swap
    /// @dev Returns a conservative estimate. Actual gas from API: result.estimate.gasCosts[0].limit
    function estimateGas(address, address, uint256) external pure override returns (uint256) {
        return 300000; // Conservative estimate for typical Eisen swaps
    }

    /// @notice Not applicable - this adapter doesn't construct calldata
    /// @dev Use buildSwapCalldataWithParams instead, passing API calldata
    function buildSwapCalldata(address, address, uint256, uint256, address)
        external
        pure
        override
        returns (bytes memory)
    {
        revert("EisenAdapter: Use buildSwapCalldataWithParams with API data");
    }

    /// @notice Validates and returns the calldata from Eisen API
    /// @dev extraParams must contain the calldata from Eisen API response
    ///      Flow: API quote → result.transactionRequest.data → extraParams → this function
    /// @param tokenIn Token to swap from (for validation)
    /// @param tokenOut Token to swap to (for validation)
    /// @param amountIn Amount to swap (for validation)
    /// @param minAmountOut Minimum amount to receive (for validation)
    /// @param receiver Address to receive tokens (must match API request)
    /// @param extraParams The calldata from result.transactionRequest.data
    /// @return swapCalldata The validated calldata ready for execution
    function buildSwapCalldataWithParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata extraParams
    ) external pure override returns (bytes memory swapCalldata) {
        // Validate parameters
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidToken();
        if (tokenIn == tokenOut) revert InvalidToken();
        if (amountIn == 0) revert InvalidAmount();
        if (minAmountOut == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        if (extraParams.length == 0) revert InvalidSwapPath();

        // Return the calldata from Eisen API
        return extraParams;
    }

    /// @notice Validates swap parameters
    /// @dev Basic validation - comprehensive validation happens in DexAggregatorFacet
    function validateSwapParams(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        pure
        override
        returns (bool)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) return false;
        if (tokenIn == tokenOut) return false;
        if (amountIn == 0 || minAmountOut == 0) return false;
        return true;
    }

    /// @notice Decodes the result of a swap
    /// @dev Not needed - DexAggregatorFacet uses balance checks for verification
    function decodeSwapResult(bytes memory) external pure override returns (uint256) {
        return 0;
    }
}
