// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ILSPVault
 * @notice Minimal interface for sFlow Cadence EVM liquid staking vault
 * @dev Source: https://github.com/sFLOW-Project/cadence-evm-liquid-staking/tree/main/evm/src
 */
interface ILSPVault {
    enum RequestStatus {
        NONE,
        QUEUED,
        AWAITING_FULFILLMENT,
        UNSTAKE_CONFIRMED,
        FULFILLED,
        CANCELLED
    }

    struct UnstakeRequest {
        RequestStatus status;
        address user;
        uint256 amount;
        uint256 flowAmount;
        uint256 unlockEpoch;
    }

    function S_FLOW_ADDRESS() external view returns (address);

    function FLOW_RECEIPT() external view returns (address);

    function unstakeRequestCount() external view returns (uint256);

    function unstakeRequests(uint256 id)
        external
        view
        returns (RequestStatus status, address user, uint256 amount, uint256 flowAmount, uint256 unlockEpoch);

    function pendingWithdrawals(address user) external view returns (uint256);

    function requestStake() external payable returns (uint256 requestId);

    function requestUnstake(uint256 amount) external returns (uint256 requestId);

    function claimPendingWithdrawal() external;

    function getSFlowQuote(uint256 flowWei) external view returns (uint256 sFlowWei);

    function getFlowQuote(uint256 sFlowWei) external view returns (uint256 flowWei);
}
