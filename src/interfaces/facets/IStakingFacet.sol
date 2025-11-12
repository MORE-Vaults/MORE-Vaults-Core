// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StakingFacetStorage} from "../../libraries/StakingFacetStorage.sol";

interface IStakingFacet {
    event Staked(address indexed protocol, address indexed token, uint256 amount, uint256 receipts);
    event UnstakeRequested(address indexed protocol, uint256 receipts, bytes32 indexed requestId);
    event UnstakeFinalized(bytes32 indexed requestId, uint256 amount);
    event ProtocolAdded(address indexed protocol, address adapter);
    event ProtocolRemoved(address indexed protocol);
    event ProtocolUpdated(address indexed protocol);
    event CircuitBreakerTriggered(uint256 oldValue, uint256 newValue, uint256 dropPercent);
    event DepegDetected(address indexed token, uint256 expectedPrice, uint256 actualPrice, uint256 depegPercent);
    event InstantUnstakeExecuted(address indexed protocol, uint256 receipts, uint256 amountOut);
    event WithdrawalQueueCreated(bytes32 indexed requestId, address indexed user, uint256 amount);

    function stake(address protocol, address token, uint256 amount, bytes calldata params)
        external
        returns (uint256 receipts);

    function requestUnstake(address protocol, uint256 receipts, bytes calldata params)
        external
        returns (bytes32 requestId);

    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount);

    function curatorInstantUnstake(address protocol, uint256 receipts, bytes calldata swapParams)
        external
        returns (uint256 amount);

    function harvest(address protocol) external returns (address[] memory tokens, uint256[] memory amounts);

    function harvestAll() external returns (uint256 totalValue);

    function addProtocol(address protocol, StakingFacetStorage.ProtocolConfig calldata config) external;

    function removeProtocol(address protocol) external;

    function updateProtocol(address protocol, StakingFacetStorage.ProtocolConfig calldata config) external;

    function accountingStakingFacet() external returns (uint256 sum, bool isPositive);

    function beforeAccounting() external;

    function getStakedBalance(address protocol) external view returns (uint256);

    function getActiveProtocols() external view returns (address[] memory);

    function getTotalStakedValue() external view returns (uint256);

    function getProtocolConfig(address protocol) external view returns (StakingFacetStorage.ProtocolConfig memory);

    function getWithdrawalRequest(bytes32 requestId)
        external
        view
        returns (StakingFacetStorage.WithdrawalRequest memory);
}
