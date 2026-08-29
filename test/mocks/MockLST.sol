// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Stateful mock LST staking pool for tests.
 * @dev Holds protocol state: stake, async unstake queue, manual claim and auto-settle.
 */
contract MockLST {
    using SafeERC20 for IERC20;

    IERC20 public immutable depositToken;
    IERC20 public immutable receiptToken;
    uint256 public immutable exchangeRate;
    uint256 public immutable withdrawalDelay;

    mapping(bytes32 => uint256) public lockedReceipts;
    mapping(bytes32 => bool) public claimableWithdrawals;
    mapping(bytes32 => uint256) public claimableAt;
    mapping(bytes32 => bool) public completedWithdrawals;
    mapping(bytes32 => uint256) public settledAmounts;
    mapping(address => uint256) public pendingUnstakeByVault;

    constructor(
        address _depositToken,
        address _receiptToken,
        uint256 _exchangeRate,
        uint256 _withdrawalDelay
    ) {
        depositToken = IERC20(_depositToken);
        receiptToken = IERC20(_receiptToken);
        exchangeRate = _exchangeRate;
        withdrawalDelay = _withdrawalDelay;
    }

    function stake(uint256 amount) external returns (uint256 receipts) {
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        receipts = (amount * 1e18) / exchangeRate;
        receiptToken.safeTransfer(msg.sender, receipts);
    }

    function requestUnstake(uint256 receipts) external returns (bytes32 requestId) {
        receiptToken.safeTransferFrom(msg.sender, address(this), receipts);
        requestId = keccak256(abi.encodePacked(msg.sender, receipts, block.timestamp));
        lockedReceipts[requestId] = receipts;
        pendingUnstakeByVault[msg.sender] += receipts;
        claimableAt[requestId] = block.timestamp + withdrawalDelay;
    }

    function setClaimable(bytes32 requestId, bool claimable) external {
        claimableWithdrawals[requestId] = claimable;
    }

    function isClaimable(bytes32 requestId) external view returns (bool) {
        return claimableWithdrawals[requestId] && block.timestamp >= claimableAt[requestId];
    }

    function isCompleted(bytes32 requestId) external view returns (bool) {
        return completedWithdrawals[requestId];
    }

    function getSettledAmount(bytes32 requestId) external view returns (uint256) {
        return settledAmounts[requestId];
    }

    function getWithdrawalClaimableAt(bytes32 requestId) external view returns (uint256) {
        return claimableAt[requestId];
    }

    /// @notice Simulates protocol auto-settlement without an explicit vault claim transaction.
    function autoSettle(bytes32 requestId, address recipient) external returns (uint256 amount) {
        return _settle(requestId, recipient, false);
    }

    function claim(bytes32 requestId, address recipient) external returns (uint256 amount) {
        require(claimableWithdrawals[requestId], "Not claimable");
        return _settle(requestId, recipient, true);
    }

    function syncCompleted(bytes32 requestId) external view returns (uint256 amount) {
        require(completedWithdrawals[requestId], "Not completed");
        return settledAmounts[requestId];
    }

    function _settle(bytes32 requestId, address recipient, bool requireClaimableFlag)
        private
        returns (uint256 amount)
    {
        require(!completedWithdrawals[requestId], "Already completed");

        uint256 receipts = lockedReceipts[requestId];
        require(receipts > 0, "Unknown request");
        if (requireClaimableFlag) {
            require(claimableWithdrawals[requestId], "Not claimable");
        }

        amount = (receipts * exchangeRate) / 1e18;

        delete lockedReceipts[requestId];
        delete claimableWithdrawals[requestId];
        pendingUnstakeByVault[recipient] -= receipts;
        completedWithdrawals[requestId] = true;
        settledAmounts[requestId] = amount;

        depositToken.safeTransfer(recipient, amount);
    }
}
