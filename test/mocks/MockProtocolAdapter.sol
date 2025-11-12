// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockProtocolAdapter is IProtocolAdapter {
    address public immutable depositToken;
    address public immutable receiptToken;
    uint256 public exchangeRate = 1e18;
    uint256 public valueInETH = 1e18;

    mapping(bytes32 => uint256) public withdrawalRequests;
    mapping(bytes32 => bool) public claimableWithdrawals;
    uint256 private requestCounter;

    constructor(address _depositToken, address _receiptToken) {
        depositToken = _depositToken;
        receiptToken = _receiptToken;
    }

    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        IERC20(depositToken).transferFrom(msg.sender, address(this), amount);

        receipts = (amount * 1e18) / exchangeRate;

        require(IERC20(receiptToken).transfer(msg.sender, receipts), "Transfer failed");

        return receipts;
    }

    function requestUnstake(uint256 receipts, bytes calldata) external returns (bytes32 requestId) {
        IERC20(receiptToken).transferFrom(msg.sender, address(this), receipts);

        requestId = keccak256(abi.encodePacked(msg.sender, block.timestamp, requestCounter++));
        withdrawalRequests[requestId] = receipts;

        return requestId;
    }

    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount) {
        require(claimableWithdrawals[requestId], "Not claimable");

        uint256 receipts = withdrawalRequests[requestId];
        amount = (receipts * exchangeRate) / 1e18;

        delete withdrawalRequests[requestId];
        delete claimableWithdrawals[requestId];

        require(IERC20(depositToken).transfer(msg.sender, amount), "Transfer failed");

        return amount;
    }

    function harvest() external returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](1);
        amounts = new uint256[](1);

        tokens[0] = depositToken;
        amounts[0] = 0;

        return (tokens, amounts);
    }

    function getPendingRewards() external pure returns (uint256) {
        return 0;
    }

    function getValueInETH(uint256 amount) external view returns (uint256) {
        return (amount * valueInETH) / 1e18;
    }

    function getExchangeRate() external view returns (uint256) {
        return exchangeRate;
    }

    function isWithdrawalClaimable(bytes32 requestId) external view returns (bool) {
        return claimableWithdrawals[requestId];
    }

    function getProtocolName() external pure returns (string memory) {
        return "MockProtocol";
    }

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    function setValueInETH(uint256 _value) external {
        valueInETH = _value;
    }

    function setWithdrawalClaimable(bytes32 requestId, bool claimable) external {
        claimableWithdrawals[requestId] = claimable;
    }
}
