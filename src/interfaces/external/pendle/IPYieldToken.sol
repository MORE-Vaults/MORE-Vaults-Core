// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPYieldToken {
    function mintPY(address receiverPT, address receiverYT) external returns (uint256 amountPYOut);

    function redeemPY(address receiver) external returns (uint256 amountSyOut);

    function redeemDueInterestAndRewards(address user, bool redeemInterest, bool redeemRewards)
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);

    function SY() external view returns (address);
    function PT() external view returns (address);
}
