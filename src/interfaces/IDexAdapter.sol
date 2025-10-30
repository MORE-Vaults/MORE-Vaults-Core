// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDexAdapter
 * @notice Common interface for DEX aggregator adapters
 * @dev Each aggregator implementation (Eisen, 1inch, Paraswap, etc.) must implement this interface
 *      Follows the same pattern as IBridgeAdapter for consistency across the protocol
 */
interface IDexAdapter {
    // ==================== ERRORS ====================

    error InvalidAmount();
    error InvalidToken();
    error InvalidReceiver();
    error SlippageTooHigh();
    error ChainNotSupported(uint256 chainId);
    error RouterNotSet();
    error QuoterNotAvailable();
    error InvalidSwapPath();
    error ZeroAddress();

    // ==================== EVENTS ====================

    event SwapQuoted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    event SwapCalldataBuilt(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, address indexed receiver
    );

    // ==================== CORE FUNCTIONS ====================

    function adapterName() external pure returns (string memory name);

    function getRouterAddress() external view returns (address router);

    function getQuoterAddress() external view returns (address quoter);

    function isChainSupported(uint256 chainId) external view returns (bool supported);

    function getSupportedChains() external view returns (uint256[] memory chainIds);

    // ==================== QUOTE FUNCTIONS ====================

    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    function estimateGas(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 gasEstimate);

    // ==================== CALLDATA BUILDER ====================

    function buildSwapCalldata(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external view returns (bytes memory swapCalldata);

    function buildSwapCalldataWithParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata extraParams
    ) external view returns (bytes memory swapCalldata);

    // ==================== UTILITY FUNCTIONS ====================

    function decodeSwapResult(bytes memory result) external pure returns (uint256 amountOut);

    function validateSwapParams(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        view
        returns (bool valid);
}
