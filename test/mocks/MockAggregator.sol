// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal Chainlink aggregator mock — only needs decimals() for local tests.
contract MockAggregator {
    uint8 public immutable decimals;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }
}
