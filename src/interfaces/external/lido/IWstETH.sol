// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWstETH
 * @notice Minimal wstETH wrapper interface
 * @dev Mainnet: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 */
interface IWstETH {
    function stETH() external view returns (address);

    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);

    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);

    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256 wstETHAmount);
}
