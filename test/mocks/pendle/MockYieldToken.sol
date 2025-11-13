// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPYieldToken} from "../../../src/interfaces/external/pendle/IPYieldToken.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockYieldToken is IPYieldToken {
    address public PT;
    address public immutable SY;

    constructor(address _pt, address _sy) {
        PT = _pt;
        SY = _sy;
    }

    function setPT(address _pt) external {
        PT = _pt;
    }

    function mintPY(address, address) external pure returns (uint256) {
        revert("Not implemented");
    }

    function redeemPY(address receiver) external returns (uint256 amountSyOut) {
        uint256 ptBalance = IERC20(PT).balanceOf(address(this));
        amountSyOut = ptBalance;
        IERC20(SY).transfer(receiver, amountSyOut);
        return amountSyOut;
    }

    function redeemDueInterestAndRewards(address, bool, bool)
        external
        pure
        returns (uint256 interestOut, uint256[] memory rewardsOut)
    {
        interestOut = 0;
        rewardsOut = new uint256[](0);
        return (interestOut, rewardsOut);
    }
}
