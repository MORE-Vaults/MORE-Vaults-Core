// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStandardizedYield} from "../../../src/interfaces/external/pendle/IStandardizedYield.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockStandardizedYield is IStandardizedYield {
    address public immutable underlyingToken;
    uint256 private _exchangeRate = 1e18;

    constructor(address _underlyingToken) {
        underlyingToken = _underlyingToken;
    }

    function deposit(address receiver, address, uint256 amountTokenToDeposit, uint256, bool)
        external
        returns (uint256 amountSharesOut)
    {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), amountTokenToDeposit);
        amountSharesOut = (amountTokenToDeposit * 1e18) / _exchangeRate;
        _mint(receiver, amountSharesOut);
        return amountSharesOut;
    }

    function redeem(address receiver, uint256 amountSharesToRedeem, address, uint256, bool)
        external
        returns (uint256 amountTokenOut)
    {
        _burn(msg.sender, amountSharesToRedeem);
        amountTokenOut = (amountSharesToRedeem * _exchangeRate) / 1e18;
        IERC20(underlyingToken).transfer(receiver, amountTokenOut);
        return amountTokenOut;
    }

    function previewDeposit(address, uint256 amountTokenToDeposit) external view returns (uint256) {
        return (amountTokenToDeposit * 1e18) / _exchangeRate;
    }

    function previewRedeem(address, uint256 amountSharesToRedeem) external view returns (uint256) {
        return (amountSharesToRedeem * _exchangeRate) / 1e18;
    }

    function exchangeRate() external view returns (uint256) {
        return _exchangeRate;
    }

    function getTokensIn() external view returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = underlyingToken;
        return tokens;
    }

    function getTokensOut() external view returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = underlyingToken;
        return tokens;
    }

    function yieldToken() external view returns (address) {
        return underlyingToken;
    }

    function assetInfo() external view returns (uint8, address, uint8) {
        return (0, underlyingToken, 18);
    }

    function setExchangeRate(uint256 _rate) external {
        _exchangeRate = _rate;
    }

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    function _mint(address to, uint256 amount) internal {
        balances[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balances[from] -= amount;
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
}
