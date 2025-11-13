// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPMarket {
    function swapExactPtForSy(address receiver, uint256 exactPtIn, bytes calldata data)
        external
        returns (uint256 netSyOut, uint256 netSyFee);

    function getPtToSyRate(uint32 duration) external view returns (uint256);

    function expiry() external view returns (uint256);

    function readTokens() external view returns (address _SY, address _PT, address _YT);
}
