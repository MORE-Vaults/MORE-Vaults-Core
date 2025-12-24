// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    IOFT,
    SendParam,
    MessagingFee,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    MessagingReceipt,
    MessagingParams,
    ILayerZeroEndpointV2
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

// Mock OFT Token
contract MockOFT {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public underlyingToken = address(this);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function setUnderlyingToken(address _underlyingToken) external {
        underlyingToken = _underlyingToken;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }

    function quoteSend(SendParam calldata, bool) external pure returns (MessagingFee memory) {
        return MessagingFee(0.01 ether, 0);
    }

    function send(SendParam calldata _sendParam, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        return (
            MessagingReceipt(bytes32(uint256(1)), 1, MessagingFee(0, 0)),
            OFTReceipt(_sendParam.amountLD, _sendParam.amountLD)
        );
    }

    function forceApprove(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function token() external view returns (address) {
        return underlyingToken;
    }
}
