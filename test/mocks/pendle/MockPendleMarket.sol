// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPMarket} from "../../../src/interfaces/external/pendle/IPMarket.sol";

contract MockPendleMarket is IPMarket {
    address public immutable SY;
    address public immutable PT;
    address public immutable YT;
    uint256 public expiry;
    uint256 public ptToSyRate = 1e18;

    constructor(address _sy, address _pt, address _yt, uint256 _expiry) {
        SY = _sy;
        PT = _pt;
        YT = _yt;
        expiry = _expiry;
    }

    function swapExactPtForSy(address, uint256, bytes calldata) external pure returns (uint256, uint256) {
        revert("Use router");
    }

    function getPtToSyRate(uint32) external view returns (uint256) {
        return ptToSyRate;
    }

    function readTokens() external view returns (address _SY, address _PT, address _YT) {
        return (SY, PT, YT);
    }

    function setPtToSyRate(uint256 _rate) external {
        ptToSyRate = _rate;
    }
}
