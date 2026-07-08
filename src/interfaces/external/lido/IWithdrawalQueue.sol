// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWithdrawalQueue
 * @notice Minimal Lido WithdrawalQueueERC721 interface
 * @dev Mainnet: 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
 */
interface IWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner)
        external
        returns (uint256[] memory requestIds);

    function claimWithdrawal(uint256 requestId) external;

    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external;

    function getLastCheckpointIndex() external view returns (uint256);

    function findCheckpointHints(uint256[] calldata requestIds, uint256 firstIndex, uint256 lastIndex)
        external
        view
        returns (uint256[] memory hintIds);

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestIds);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);
}
