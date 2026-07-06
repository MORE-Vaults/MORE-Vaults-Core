// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title StakingFacetStorage
 * @notice Diamond storage for StakingFacet vault-level withdrawal tracking
 */
library StakingFacetStorage {
    bytes32 constant STAKING_FACET_STORAGE_POSITION = keccak256("MoreVaults.stakingFacet.storage");

    /// @dev Aligned with MoreVaultsLib.removeTokenIfnecessary dust handling.
    uint256 internal constant ADAPTER_DUST_THRESHOLD = 10e3;

    struct WithdrawalRequest {
        address adapter;
        uint256 amount;
        uint256 timestamp;
        /// @dev Informational snapshot from adapter at request time; not enforced on finalize
        uint256 expectedClaimableAt;
        bytes32 protocolRequestId;
        bool finalized;
    }

    struct Layout {
        mapping(bytes32 => WithdrawalRequest) withdrawalRequests;
        mapping(address => uint256) withdrawalRequestNonce;
        address facetAddress;
    }

    error InvalidUnstakeReceipts(uint256 requested, uint256 actual);
    error InvalidAdapter(address adapter);
    error InsufficientStakedBalance(uint256 requested, uint256 available);
    error WithdrawalAlreadyFinalized(bytes32 requestId);
    error WithdrawalRequestNotFound(bytes32 requestId);
    error WithdrawalNotReady(bytes32 requestId, uint256 expectedClaimableAt);
    error ZeroAmount();
    error AdapterExecutionFailed(address adapter, bytes reason);
    error UnstakeBlocked(address adapter);
    error NoStrandedWithdrawals(address adapter);

    function layout() internal pure returns (Layout storage l) {
        bytes32 position = STAKING_FACET_STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }
}
