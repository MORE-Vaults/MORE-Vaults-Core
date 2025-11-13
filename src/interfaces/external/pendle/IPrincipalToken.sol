// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPrincipalToken {
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
    function YT() external view returns (address);
    function SY() external view returns (address);
}
