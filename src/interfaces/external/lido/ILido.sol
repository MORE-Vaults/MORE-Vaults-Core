// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ILido
 * @notice Minimal Lido stETH pool interface for ETH deposits
 * @dev Mainnet: 0xae7ab96520DE3A18E5d933742Af6966E9070656C
 */
interface ILido {
    function submit(address referral) external payable returns (uint256 stETHAmount);
}
