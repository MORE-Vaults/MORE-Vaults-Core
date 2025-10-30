// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";

/**
 * @title BaseDexAdapter
 * @notice Abstract base contract for DEX aggregator adapters
 * @dev Provides common functionality that all adapters can inherit
 *      Follows the same pattern as cross-chain adapters for consistency
 */
abstract contract BaseDexAdapter is IDexAdapter {
    address public immutable router;
    address public immutable quoter;
    uint256[] internal supportedChains;

    constructor(address _router, address _quoter, uint256[] memory _supportedChains) {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
        quoter = _quoter;
        supportedChains = _supportedChains;
    }

    function getRouterAddress() external view override returns (address) {
        return router;
    }

    function getQuoterAddress() external view override returns (address) {
        return quoter;
    }

    function isChainSupported(uint256 chainId) public view override returns (bool) {
        for (uint256 i = 0; i < supportedChains.length; i++) {
            if (supportedChains[i] == chainId) {
                return true;
            }
        }
        return false;
    }

    function getSupportedChains() external view override returns (uint256[] memory) {
        return supportedChains;
    }

    function validateSwapParams(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        view
        virtual
        override
        returns (bool)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) return false;
        if (tokenIn == tokenOut) return false;
        if (amountIn == 0 || minAmountOut == 0) return false;
        if (!isChainSupported(block.chainid)) return false;
        return true;
    }

    function estimateGas(address, address, uint256) external pure virtual override returns (uint256) {
        return 300000;
    }

    function decodeSwapResult(bytes memory) external pure virtual override returns (uint256) {
        return 0;
    }

    function adapterName() external pure virtual override returns (string memory);

    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        virtual
        override
        returns (uint256 amountOut);

    function buildSwapCalldata(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external view virtual override returns (bytes memory swapCalldata);

    function buildSwapCalldataWithParams(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        bytes calldata extraParams
    ) external view virtual override returns (bytes memory swapCalldata);
}
