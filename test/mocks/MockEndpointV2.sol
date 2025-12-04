// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockEndpointV2 {
    uint32 private _eid;
    mapping(address => address) public delegates;

    event DelegateSet(address sender, address delegate);

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
        emit DelegateSet(msg.sender, _delegate);
    }
}
