// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IAnkrFlowStakingPool
 * @notice Minimal interface for Ankr FlowStakingPool on Flow EVM
 * @dev Proxy: 0xFE8189A3016cb6A3668b8ccdAC520CE572D4287a
 */
interface IAnkrFlowStakingPool {
    function stakeCerts() external payable;

    function unstakeCerts(uint256 shares) external;

    function claimManually(address receiverAddress) external;

    function getTokens() external view returns (address bearingToken, address certificateToken);

    function getPendingRequestsOf(address claimer) external view returns (uint256[] memory);

    function getPendingUnstakesOf(address claimer) external view returns (uint256);

    function getForManualClaimOf(address claimer) external view returns (uint256);

    function isMarkedForManualClaim(address claimer) external view returns (bool);
}
