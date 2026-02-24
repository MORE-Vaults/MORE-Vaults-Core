// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    // function to exclude from coverage
    function test_skip() external {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address from, address to, uint256 amount) public returns (bool) {
        _transfer(from, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
