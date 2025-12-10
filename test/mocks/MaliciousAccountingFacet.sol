// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract MaliciousAccountingFacet {
    function accountingMaliciousFacet() external pure returns (uint256, bool) {
        return (type(uint256).max, true);
    }
}
