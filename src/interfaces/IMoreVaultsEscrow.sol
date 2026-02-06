// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";

/**
 * @title IMoreVaultsEscrow
 * @dev Interface for MoreVaultsEscrow contract
 */
interface IMoreVaultsEscrow {
    function lockTokens(
        bytes32 guid,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        uint256 amountLimit,
        address initiator
    ) external payable;

    function releaseTokensForExecution(bytes32 guid)
        external
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount);

    function unlockTokensAfterExecution(
        bytes32 guid,
        address[] memory tokens,
        uint256[] memory usedAmounts
    ) external;

    function refundTokens(bytes32 guid) external;

    function refundToComposer(bytes32 guid, address composer) external;

    function getEscrowInfo(bytes32 guid)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount);

    function getLockedShares(address vault, address user) external view returns (uint256);
}
