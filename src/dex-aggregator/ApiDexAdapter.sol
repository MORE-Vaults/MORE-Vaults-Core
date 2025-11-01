// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/**
 * @title ApiDexAdapter
 * @notice Generic adapter for API-based DEX aggregators
 * @dev Works with any DEX aggregator that provides off-chain API with ready-to-execute transaction data
 *
 *      Compatible with:
 *      - Eisen Finance
 *      - DefiLlama Swap
 *      - 1inch API
 *      - Paraswap API
 *      - Any aggregator that returns transaction calldata via API
 *
 *      How to use:
 *      1. Call aggregator's API off-chain to get a quote
 *      2. API typically returns a transaction object with:
 *         - to: target contract address (router/forwarder)
 *         - data: complete calldata for the swap
 *         - value: native token value if needed
 *      3. Pass the target address to SwapParams.targetContract
 *      4. Pass the API's calldata to buildSwapCalldataWithParams as extraParams
 *      5. Use with DexAggregatorFacet.executeSwap()
 *
 *      No hardcoded routers needed - everything comes from the API response.
 */
contract ApiDexAdapter is IDexAdapter {
    string public constant ADAPTER_NAME = "API DEX Adapter";

    /// @notice Returns the adapter name
    function adapterName() external pure override returns (string memory) {
        return ADAPTER_NAME;
    }

    /// @notice Not applicable - router address comes from API quote
    /// @dev The router is in the API response (e.g., result.transactionRequest.to)
    function getRouterAddress() external pure override returns (address) {
        revert RouterNotSet();
    }

    /// @notice Not applicable - API-based adapters use off-chain quotes
    function getQuoterAddress() external pure override returns (address) {
        revert QuoterNotAvailable();
    }

    /// @notice Chain support is dynamic and managed by the API
    /// @dev Always returns true - let the API validate chain support
    function isChainSupported(uint256) external pure override returns (bool) {
        return true;
    }

    /// @notice Returns supported chains
    /// @dev Not applicable - chain support is dynamic and managed off-chain by the API
    function getSupportedChains() external pure override returns (uint256[] memory) {
        // Return empty array since chains are managed by the API
        return new uint256[](0);
    }

    /// @notice Not applicable - quotes come from off-chain API
    /// @dev Use the aggregator's API endpoint to get quotes
    function getQuote(address, address, uint256) external pure override returns (uint256) {
        revert QuoterNotAvailable();
    }

    /// @notice Estimates gas for a swap
    /// @dev Returns a conservative estimate. Actual gas should come from API response
    function estimateGas(address, address, uint256) external pure override returns (uint256) {
        return 300000; // Conservative estimate for typical DEX aggregator swaps
    }

    /// @notice Not applicable - this adapter doesn't construct calldata
    /// @dev Use buildSwapCalldataWithParams instead, passing API calldata
    function buildSwapCalldata(address, address, uint256, uint256, address)
        external
        pure
        override
        returns (bytes memory)
    {
        revert("ApiDexAdapter: Use buildSwapCalldataWithParams with API data");
    }

    /// @notice Validates and returns the calldata from API response
    /// @dev extraParams must contain the calldata from the API response
    ///      Flow: API quote → transaction.data (or similar field) → extraParams → this function
    ///      SECURITY: Basic parameter validation only. Advanced validation relies on:
    ///      1. DexAggregatorFacet balance checks (will revert if tokens don't return to vault)
    ///      2. Curator trust model (only trusted curators can execute swaps)
    ///      3. Registry whitelist (targetContract must be whitelisted)
    /// @param tokenIn Token to swap from (for validation)
    /// @param tokenOut Token to swap to (for validation)
    /// @param amountIn Amount to swap (for validation)
    /// @param minAmountOut Minimum amount to receive (for validation)
    /// @param receiver Address to receive tokens (must be the vault)
    /// @param extraParams The calldata from the API response
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

        // TODO: SECURITY ENHANCEMENT - Validate receiver in calldata
        // API calldata structures are complex and dynamic, making it difficult to extract
        // the exact toAddress location reliably. For now, we rely on:
        // 1. The DexAggregatorFacet's balance checks (will revert if tokens don't return to vault)
        // 2. The caller (curator) being trusted to only use correct API responses
        // 3. The registry whitelist preventing calls to malicious contracts
        //
        // Future improvement: Implement aggregator-specific calldata validation if needed
        // _validateReceiverInCalldata(extraParams, receiver);

        // Return the calldata from API
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
