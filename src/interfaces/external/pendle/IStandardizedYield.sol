// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStandardizedYield {
    function deposit(
        address receiver,
        address tokenIn,
        uint256 amountTokenToDeposit,
        uint256 minSharesOut,
        bool depositFromInternalBalance
    ) external returns (uint256 amountSharesOut);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit)
        external
        view
        returns (uint256 amountSharesOut);

    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        external
        view
        returns (uint256 amountTokenOut);

    function exchangeRate() external view returns (uint256);

    function getTokensIn() external view returns (address[] memory);

    function getTokensOut() external view returns (address[] memory);

    function yieldToken() external view returns (address);

    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);
}
