// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockEndpointV2 {
    uint32 private _eid;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }
}
