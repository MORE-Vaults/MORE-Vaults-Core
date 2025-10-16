// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockLzAdapterView {
    mapping(address => bool) public trusted;
    address public lzAdapter;

    function setTrusted(address oft, bool v) external {
        trusted[oft] = v;
    }

    function isTrustedOFT(address oft) external view returns (bool) {
        return trusted[oft];
    }

    function setLzAdapter(address _lzAdapter) external {
        lzAdapter = _lzAdapter;
    }
}
