// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";
import {StakingFacetStorage} from "../../libraries/StakingFacetStorage.sol";

/**
 * @title IStakingFacet
 * @notice Interface for staking vault assets into external LST protocols via whitelisted adapters
 */
interface IStakingFacet is IGenericMoreVaultFacetInitializable {
    /// @param receipts Adapter-reported receipt amount. Sync adapters (e.g. Ankr): actual minted shares.
    ///                 Async adapters (e.g. sFlow): expected quote at stake time — not minted yet; do not
    ///                 use this event alone for indexer position tracking until keeper fulfillment.
    event Staked(address indexed adapter, address indexed depositToken, uint256 amount, uint256 receipts);
    event UnstakeRequested(address indexed adapter, uint256 receipts, bytes32 indexed requestId);
    /// @param nativeAmountReceived Native balance increase on the vault in this transaction (ETH/FLOW/etc.).
    ///                           Not an ERC-20 mint; adapters do not auto-wrap to WETH. Zero when
    ///                           `alreadySettled` is true. May exceed `requestedSharesAmount` on the first
    ///                           claim that drains a shared protocol bucket; sum `nativeAmountReceived` only
    ///                           where `alreadySettled` is false. Included in NAV via `VaultFacet` native +
    ///                           wrapped-native accounting when wrapped native is in `availableAssets`.
    /// @param alreadySettled True when the protocol already delivered withdrawal funds before this call.
    /// @param requestedSharesAmount Receipt-share amount recorded on the facet withdrawal request at unstake
    ///        time (`WithdrawalRequest.amount`). Informational attribution in share units; not a native payout
    ///        guarantee.
    event UnstakeFinalized(
        bytes32 indexed requestId, uint256 nativeAmountReceived, bool alreadySettled, uint256 requestedSharesAmount
    );
    event RewardsHarvested(address indexed adapter, bool success);
    /// @param amount Native deposit-token amount recovered in this transaction.
    event StrandedWithdrawalsRecovered(address indexed adapter, uint256 amount);

    function accountingStakingFacet() external view returns (uint256 sum, bool isPositive);

    function beforeAccounting() external;

    function stake(address adapter, uint256 amount, bytes calldata params) external returns (uint256 receipts);

    /// @notice Request unstake from a whitelisted adapter; records one facet withdrawal request.
    /// @dev Returns one `requestId` per call. Protocol limits are per adapter call — e.g. Lido at most
    ///      1000 stETH per queue entry; split large exits into multiple transactions.
    function requestUnstake(address adapter, uint256 receipts, bytes calldata params)
        external
        returns (bytes32 requestId);

    /// @notice Claim a finalized adapter withdrawal. Returns native received on the vault (not ERC-20).
    /// @param params Adapter-specific finalize options forwarded via delegatecall. Lido: optional
    ///        `abi.encode(uint256 checkpointHint)` from `LidoAdapter.getClaimHint`; empty uses protocol default.
    function finalizeUnstake(bytes32 requestId, bytes calldata params) external returns (uint256 amount);

    /// @notice Recover native deposit-token refunds stranded in the adapter protocol without a facet
    ///         withdrawal request. For edge cases only (e.g. async stake cancel); normal unstake uses
    ///         `finalizeUnstake`. After a shared bucket is drained here, open fulfilled requests still
    ///         close via `finalizeUnstake` (sync: `alreadySettled=true`, `nativeAmountReceived=0`).
    /// @param params Forwarded to the adapter; adapter-specific and may be unused.
    function recoverStrandedWithdrawals(address adapter, bytes calldata params) external returns (uint256 amount);

    function getStakedBalance(address adapter) external view returns (uint256);

    function getPendingUnstake(address adapter) external view returns (uint256);

    function getUnstakeableReceipts(address adapter) external view returns (uint256);

    function getAccountingDepositValue(address adapter) external view returns (uint256);

    function getActiveAdapters() external view returns (address[] memory);

    function getWithdrawalRequest(bytes32 requestId)
        external
        view
        returns (StakingFacetStorage.WithdrawalRequest memory);
}
