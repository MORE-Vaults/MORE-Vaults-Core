// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWrappedNative
 * @notice Canonical wrapped-native interface (WETH-style).
 *
 * Used by adapters that need to bridge between an ERC-20 deposit token (e.g.
 * WFLOW, the form the vault holds) and the chain's native coin (e.g. FLOW,
 * required by `IAnkrFlowPool.stakeCerts{value:...}`).
 */
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
