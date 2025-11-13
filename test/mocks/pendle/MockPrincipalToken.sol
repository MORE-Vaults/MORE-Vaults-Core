// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPrincipalToken} from "../../../src/interfaces/external/pendle/IPrincipalToken.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockPrincipalToken is IPrincipalToken, IERC20 {
    uint256 public expiry;
    address public immutable YT;
    address public immutable SY;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    constructor(address _sy, address _yt, uint256 _expiry) {
        SY = _sy;
        YT = _yt;
        expiry = _expiry;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    function setExpiry(uint256 _expiry) external {
        expiry = _expiry;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowances[from][msg.sender] != type(uint256).max) {
            allowances[from][msg.sender] -= amount;
        }
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}
