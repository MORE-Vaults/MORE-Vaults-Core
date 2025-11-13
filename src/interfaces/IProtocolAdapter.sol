// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IProtocolAdapter {
    function stake(uint256 amount, bytes calldata params) external returns (uint256 receipts);

    function requestUnstake(uint256 receipts, bytes calldata params) external returns (bytes32 requestId);

    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount);

    function harvest() external returns (address[] memory tokens, uint256[] memory amounts);

    function getPendingRewards() external view returns (uint256);

    function getDepositTokenForReceipts(uint256 receiptAmount) external view returns (uint256);

    function isWithdrawalClaimable(bytes32 requestId) external view returns (bool);

    function getProtocolName() external pure returns (string memory);
}
