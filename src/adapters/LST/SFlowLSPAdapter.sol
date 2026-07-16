// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../../interfaces/IProtocolAdapter.sol";
import {IWrappedToken} from "../../interfaces/IWrappedToken.sol";
import {ILSPVault} from "../../interfaces/external/sflow/ILSPVault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SFlowLSPAdapter
 * @notice Stateless adapter for sFlow Cadence EVM liquid staking used by StakingFacet
 * @dev Execution paths are delegatecall-safe: only immutables and external calls.
 *      Staking uses native FLOW via `requestStake`; depositToken must be the vault wrapped native (WFLOW).
 *
 *      Async lifecycle (per LSPVault):
 *      - Stake: WFLOW → native → `requestStake` mints FLOW_RECEIPT; keeper fulfills → sFlow on vault wallet.
 *        Until fulfillment, `getUnstakeableReceipts` is zero — unstake requires wallet sFlow, not FLOW_RECEIPT.
 *      - Unstake: sFlow → `requestUnstake` locks sFlow in LSPVault and mints FLOW_RECEIPT (FLOW-denominated);
 *        keeper fulfills → FLOW_RECEIPT burned, native accrues in `pendingWithdrawals`.
 *      - Finalize: `claimPendingWithdrawal` drains the shared pending-withdrawal bucket for the vault.
 *
 *      Withdrawal identity:
 *      - `protocolRequestId` is `bytes32(unstakeRequestId)` from LSPVault.
 *      - Multiple fulfilled requests share one `pendingWithdrawals` bucket (same pattern as Ankr manual claim).
 *      - First finalize claims the full bucket; later finalizes for already-fulfilled requests sync via
 *        `isWithdrawalCompleted` and return 0 (no native transfer in that transaction).
 *
 *      Informational:
 *      - `getWithdrawalClaimableAt` returns `block.timestamp + UNSTAKE_ETA_UPPER_BOUND` (~14 days) for active
 *        unstake requests; not read from LSPVault `unlockEpoch` and not enforced by StakingFacet. Flow unstake
 *        typically completes in 1–2 Cadence epochs (~7–14 days).
 *      - The vault diamond must accept native FLOW (receive) for claim delivery.
 *      - Deployment: whitelist WFLOW (depositToken) and sFlow (`receiptToken`) in vault `availableAssets` if
 *        wallet balances should appear in VaultFacet. Do **not** whitelist `FLOW_RECEIPT` — it is an internal
 *        async-stake/unstake IOU counted only via `getAccountingDepositValue`.
 */
contract SFlowLSPAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    /// @dev Informational upper bound for curator UI; Flow unstake is typically 1–2 epochs (~7–14 days).
    uint256 private constant UNSTAKE_ETA_UPPER_BOUND = 14 days;

    address public immutable lspVault;
    address public immutable depositToken;
    address public immutable receiptToken;
    address public immutable flowReceipt;

    constructor(address _lspVault, address _wrappedNative) {
        lspVault = _lspVault;
        depositToken = _wrappedNative;
        receiptToken = ILSPVault(_lspVault).S_FLOW_ADDRESS();
        flowReceipt = ILSPVault(_lspVault).FLOW_RECEIPT();
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        return _sumActiveUnstakeReceipts(vault);
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        // Wallet sFlow only. Pending async stake (FLOW_RECEIPT) is not unstakeable until keeper fulfillment.
        return IERC20(receiptToken).balanceOf(vault);
    }

    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        depositTokenAmount =
            IERC20(flowReceipt).balanceOf(vault) + ILSPVault(lspVault).pendingWithdrawals(vault);

        if (!receiptIsAvailableAsset) {
            depositTokenAmount += ILSPVault(lspVault).getFlowQuote(IERC20(receiptToken).balanceOf(vault));
        }
    }

    /// @notice Queue async stake. Mints FLOW_RECEIPT immediately; sFlow arrives after keeper fulfillment.
    /// @return receipts Expected sFlow at the current rate (`getSFlowQuote`); not minted synchronously.
    ///         Actual amount may differ after fulfillment (slippage / rate drift). Wallet sFlow stays 0 until then.
    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        IWrappedToken(depositToken).withdraw(amount);
        ILSPVault(lspVault).requestStake{value: amount}();
        // Return expected sFlow quote; actual sFlow arrives after keeper fulfillment.
        receipts = ILSPVault(lspVault).getSFlowQuote(amount);
    }

    function requestUnstake(uint256 receipts, bytes calldata)
        external
        returns (bytes32 requestId, uint256 actualReceipts)
    {
        IERC20(receiptToken).forceApprove(lspVault, receipts);
        uint256 protocolRequestId = ILSPVault(lspVault).requestUnstake(receipts);
        IERC20(receiptToken).forceApprove(lspVault, 0);

        requestId = bytes32(protocolRequestId);
        actualReceipts = receipts;
    }

    /// @notice Claim pending native FLOW or sync an already-claimed fulfilled request (returns 0).
    function finalizeUnstake(bytes32 requestId, bytes calldata params) external returns (uint256 amount) {
        address vault = address(this);
        uint256 id = uint256(requestId);

        if (_isWithdrawalCompleted(vault, id)) {
            return 0;
        }

        uint256 balanceBefore = vault.balance;
        ILSPVault(lspVault).claimPendingWithdrawal();
        amount = vault.balance - balanceBefore;
    }

    /// @notice Drain `LSPVault.pendingWithdrawals` when native FLOW is not tied to a facet unstake request.
    /// @dev Primary case: keeper `cancelStakeRequestSlippage` after an async stake fails slippage checks —
    ///      FLOW_RECEIPT is burned and the partial refund lands in `pendingWithdrawals` with no
    ///      `WithdrawalRequest` to finalize. Can also drain a shared bucket if unstake proceeds were
    ///      not claimed via `finalizeUnstake` first; then finalize each open fulfilled request afterward
    ///      (sync path). Prefer `finalizeUnstake` for normal unstake flow.
    function recoverStrandedWithdrawals(bytes calldata) external returns (uint256 amount) {
        address vault = address(this);
        if (ILSPVault(lspVault).pendingWithdrawals(vault) == 0) return 0;

        uint256 balanceBefore = vault.balance;
        ILSPVault(lspVault).claimPendingWithdrawal();
        amount = vault.balance - balanceBefore;
    }

    function isWithdrawalClaimable(address vault, bytes32 requestId) external view returns (bool) {
        uint256 id = uint256(requestId);
        if (id == 0) return false;
        if (_isWithdrawalCompleted(vault, id)) return false;

        (ILSPVault.RequestStatus status,,,,) = ILSPVault(lspVault).unstakeRequests(id);
        if (status != ILSPVault.RequestStatus.FULFILLED) return false;

        return ILSPVault(lspVault).pendingWithdrawals(vault) > 0;
    }

    function isWithdrawalCompleted(address vault, bytes32 requestId) external view returns (bool) {
        return _isWithdrawalCompleted(vault, uint256(requestId));
    }

    /// @notice Informational upper-bound ETA as a Unix timestamp. Not enforced by StakingFacet and not
    ///         derived from LSPVault `unlockEpoch` (Cadence epoch). Uses `block.timestamp + 14 days` for any
    ///         non-terminal unstake request, matching the typical 1–2 epoch Flow unstake window.
    function getWithdrawalClaimableAt(address, bytes32 requestId) external view returns (uint256) {
        uint256 id = uint256(requestId);
        if (id == 0) return 0;

        (ILSPVault.RequestStatus status,,,,) = ILSPVault(lspVault).unstakeRequests(id);
        if (status == ILSPVault.RequestStatus.NONE || status == ILSPVault.RequestStatus.CANCELLED) {
            return 0;
        }

        return block.timestamp + UNSTAKE_ETA_UPPER_BOUND;
    }

    /// @notice sFlow LSPVault does not gate `requestUnstake` on `pendingWithdrawals`; always false here.
    ///         Ankr uses this hook to block while manual-claim balance is non-zero (adapter-specific).
    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "sFlowLSP";
    }

    function _isWithdrawalCompleted(address vault, uint256 id) private view returns (bool) {
        if (id == 0 || vault == address(0)) return false;

        (ILSPVault.RequestStatus status,,,,) = ILSPVault(lspVault).unstakeRequests(id);
        if (status != ILSPVault.RequestStatus.FULFILLED) return false;

        // Per-request FULFILLED, but completion also requires the shared `pendingWithdrawals` bucket to be
        // empty — LSPVault has no per-request claim, so all fulfilled requests flip to completed together
        // after the first `claimPendingWithdrawal` drains the bucket.
        return ILSPVault(lspVault).pendingWithdrawals(vault) == 0;
    }

    function _sumActiveUnstakeReceipts(address vault) private view returns (uint256 total) {
        uint256 count = ILSPVault(lspVault).unstakeRequestCount();
        for (uint256 id = 1; id < count;) {
            (ILSPVault.RequestStatus status, address user, uint256 amount,,) =
                ILSPVault(lspVault).unstakeRequests(id);

            if (user == vault && _isActiveUnstakeStatus(status)) {
                total += amount;
            }

            unchecked {
                ++id;
            }
        }
    }

    function _isActiveUnstakeStatus(ILSPVault.RequestStatus status) private pure returns (bool) {
        return status == ILSPVault.RequestStatus.QUEUED || status == ILSPVault.RequestStatus.AWAITING_FULFILLMENT
            || status == ILSPVault.RequestStatus.UNSTAKE_CONFIRMED;
    }
}
