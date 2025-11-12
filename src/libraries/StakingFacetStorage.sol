// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library StakingFacetStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

    error ProtocolNotActive(address protocol);
    error ProtocolAlreadyExists(address protocol);
    error InsufficientStakedBalance(uint256 requested, uint256 available);
    error DepegThresholdExceeded(uint256 depeg, uint256 threshold);
    error WithdrawalNotReady(bytes32 requestId, uint256 timelockEnd);
    error CircuitBreakerActive();
    error InvalidProtocolConfig();
    error ProtocolHasBalance(address protocol, uint256 balance);

    bytes32 constant POSITION = keccak256("MoreVaults.StakingFacet.storage");

    enum ProtocolType {
        LIQUID_STAKING,
        YIELD_TOKENIZATION,
        LIQUID_RESTAKING
    }

    struct ProtocolConfig {
        address protocolAddress;
        ProtocolType protocolType;
        address depositToken;
        address receiptToken;
        address adapter;
        bool isActive;
        uint256 stakedBalance;
    }

    struct WithdrawalRequest {
        address protocol;
        address user;
        uint256 amount;
        uint256 timestamp;
        uint256 timelockEnd;
        bytes32 protocolRequestId;
        bool finalized;
    }

    struct Layout {
        mapping(address => ProtocolConfig) protocols;
        EnumerableSet.AddressSet activeProtocols;
        mapping(bytes32 => WithdrawalRequest) withdrawalRequests;
        uint256 lastTotalStakedValue;
        uint256 lastAccountingTimestamp;
        uint256 depegThresholdBps;
        uint256 circuitBreakerThresholdBps;
        uint256 circuitBreakerTimeWindow;
        bool circuitBreakerTriggered;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 position = POSITION;
        assembly {
            l.slot := position
        }
    }
}
