// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../../interfaces/IProtocolAdapter.sol";
import {IWrappedToken} from "../../interfaces/IWrappedToken.sol";
import {IAnkrFlowStakingPool} from "../../interfaces/external/ankr/IAnkrFlowStakingPool.sol";
import {IAnkrCertificateToken} from "../../interfaces/external/ankr/IAnkrCertificateToken.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AnkrFlowAdapter
 * @notice Stateless adapter for Ankr Flow liquid staking (ankrFLOW) used by StakingFacet
 * @dev Execution paths are delegatecall-safe: only immutables and external calls.
 *      Staking uses native FLOW via `stakeCerts`; depositToken must be the vault wrapped native (WFLOW).
 *      Flow mainnet pool proxy: 0xFE8189A3016cb6A3668b8ccdAC520CE572D4287a
 *
 *      Withdrawal identity:
 *      - `protocolRequestId` is `bytes32(bondAmount)` captured from the pending-queue delta at unstake time.
 *      - Ankr forbids duplicate bond amounts in the pending queue; `_resolveUniqueShares` may unstake fewer
 *        shares than requested and can leave dust ankrFLOW on the vault wallet.
 *
 *      Ankr queue settlement (per `QueueLiquidTokenStakingPool`):
 *      - Each `unstakeCerts` creates one atomic bond entry in the global pending queue.
 *      - `distributePendingRewards` settles each entry wholly: auto-transfer, move to manual claim, or leave
 *        pending if pool liquidity is insufficient. Partial settlement of a single entry is not possible.
 *      - Mixed states across multiple vault requests are normal (e.g. R1 auto-settled, R2 in manual claim,
 *        R3 still pending), but manual claim always holds full entries, never fragments of multiple requests.
 *
 *      Finalize / manual claim (important):
 *      - `claimManually` always transfers the FULL manual-claim balance, not a single bond entry.
 *      - The first finalize that hits the claim path receives all native FLOW currently in manual claim.
 *      - Any other vault requests whose bonds already left pending/manual state finalize via the sync path
 *        (`_isAutoSettled` → return `bondAmount`, no second transfer). Out-of-order finalize is safe for
 *        fund recovery; FIFO is optional and mainly helps per-request `amount` reporting in events.
 *      - `isWithdrawalClaimable` uses `getForManualClaimOf >= bondAmount`, so multiple vault requests can
 *        appear claimable while the pool still holds one shared manual-claim bucket. A smaller bond that
 *        already auto-settled may also read as claimable while a larger bond sits in manual claim; fund
 *        recovery still works via claim + sync, but `UnstakeFinalized.nativeAmountReceived` attribution can be
 *        misleading when multiple bonds share the manual-claim bucket.
 *      - `isUnstakeBlocked` is true while manual-claim balance > 0, preventing new unstakes until finalize
 *        drains the bucket (claim path on any eligible request, or operational cleanup via sync path).
 *
 *      Informational:
 *      - `getWithdrawalClaimableAt` returns `block.timestamp + 15 days`; not read from pool state.
 *      - Auto-settled withdrawals deliver native FLOW directly; the vault diamond must accept native (receive).
 */
contract AnkrFlowAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    error DuplicateBondAmount();

    uint256 private constant UNBONDING_PERIOD = 15 days;

    address public immutable stakingPool;
    address public immutable depositToken;
    address public immutable receiptToken;

    constructor(address pool, address wrappedNative) {
        stakingPool = pool;
        depositToken = wrappedNative;
        (, address certificateToken) = IAnkrFlowStakingPool(pool).getTokens();
        receiptToken = certificateToken;
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        uint256 pendingBonds = IAnkrFlowStakingPool(stakingPool).getPendingUnstakesOf(vault);
        if (pendingBonds == 0) return 0;
        return IAnkrCertificateToken(receiptToken).bondsToShares(pendingBonds);
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(vault);
    }

    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        IAnkrFlowStakingPool pool = IAnkrFlowStakingPool(stakingPool);
        IAnkrCertificateToken cert = IAnkrCertificateToken(receiptToken);

        depositTokenAmount = pool.getPendingUnstakesOf(vault) + pool.getForManualClaimOf(vault);

        if (!receiptIsAvailableAsset) {
            depositTokenAmount += cert.sharesToBonds(IERC20(receiptToken).balanceOf(vault));
        }
    }

    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        uint256 balanceBefore = IERC20(receiptToken).balanceOf(address(this));

        IWrappedToken(depositToken).withdraw(amount);
        IAnkrFlowStakingPool(stakingPool).stakeCerts{value: amount}();

        receipts = IERC20(receiptToken).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Queue unstake in Ankr pool. Returns bond snapshot as `protocolRequestId` and actual shares unstaked.
    /// @dev `actualReceipts` may be < `receipts` when dedup reduces shares. Reverts `DuplicateBondAmount` when no
    ///      unique bond can be formed (every candidate share collides with an entry in `getPendingRequestsOf`).
    function requestUnstake(uint256 receipts, bytes calldata) external returns (bytes32 requestId, uint256 actualReceipts) {
        IAnkrFlowStakingPool pool = IAnkrFlowStakingPool(stakingPool);
        uint256 shares = _resolveUniqueShares(address(this), receipts);

        uint256 pendingBefore = pool.getPendingUnstakesOf(address(this));
        pool.unstakeCerts(shares);
        uint256 bondAmount = pool.getPendingUnstakesOf(address(this)) - pendingBefore;

        requestId = bytes32(bondAmount);
        actualReceipts = shares;
    }

    /// @notice Claim manual bucket or sync an already-settled bond (returns 0).
    /// @dev Two paths:
    ///      1. Sync: bond no longer in pending/manual claim (`_isAutoSettled`) → return 0, no transfer.
    ///         Used for auto-settled withdrawals and for vault requests whose FLOW was already claimed by another
    ///         finalize that drained the shared manual-claim bucket. Order of finalize does not affect total payout.
    ///      2. Claim: call `claimManually` → vault receives the entire manual-claim balance; returned `amount` is
    ///         the native delta (may exceed this request's `bondAmount` when multiple bonds share the bucket).
    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount) {
        address vault = address(this);
        uint256 bondAmount = uint256(requestId);

        if (_isAutoSettled(vault, bondAmount)) {
            return 0;
        }

        uint256 balanceBefore = vault.balance;
        IAnkrFlowStakingPool(stakingPool).claimManually(vault);
        amount = vault.balance - balanceBefore;
    }

    /// @notice Drain the Ankr manual-claim bucket when native FLOW is not tied to a facet unstake request.
    /// @dev For edge cases where `getForManualClaimOf` is non-zero but there is no matching open
    ///      `finalizeUnstake` path (e.g. operational cleanup). Normal unstake withdrawals should use
    ///      `finalizeUnstake`. If this drains a bucket covering open fulfilled requests, finalize each
    ///      afterward (sync path). Not a substitute for per-request facet bookkeeping.
    /// @param params Reserved for adapter-specific recovery options; unused.
    function recoverStrandedWithdrawals(bytes calldata params) external returns (uint256 amount) {
        params;
        address vault = address(this);
        if (IAnkrFlowStakingPool(stakingPool).getForManualClaimOf(vault) == 0) return 0;

        uint256 balanceBefore = vault.balance;
        IAnkrFlowStakingPool(stakingPool).claimManually(vault);
        amount = vault.balance - balanceBefore;
    }

    function harvest() external {}

    /// @notice True when manual-claim bucket covers this bond (`>=`, not exact match).
    /// @dev Multiple vault requests can be claimable simultaneously while the pool holds one shared bucket.
    function isWithdrawalClaimable(address vault, bytes32 requestId) external view returns (bool) {
        uint256 bondAmount = uint256(requestId);

        if (bondAmount == 0) return false;
        if (_isAutoSettled(vault, bondAmount)) return false;

        return IAnkrFlowStakingPool(stakingPool).getForManualClaimOf(vault) >= bondAmount;
    }

    /// @notice True when bond left pending queue and is not covered by the manual-claim bucket anymore.
    function isWithdrawalCompleted(address vault, bytes32 requestId) external view returns (bool) {
        return _isAutoSettled(vault, uint256(requestId));
    }

    /// @notice Informational ETA for curators; not enforced by StakingFacet and not tied to pool unbonding start.
    function getWithdrawalClaimableAt(address, bytes32) external view returns (uint256) {
        return block.timestamp + UNBONDING_PERIOD;
    }

    /// @notice Adapter gate while manual-claim balance is non-zero (see StakingFacet `UnstakeBlocked`).
    function isUnstakeBlocked(address vault) external view returns (bool) {
        return IAnkrFlowStakingPool(stakingPool).getForManualClaimOf(vault) > 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "AnkrFlow";
    }

    /// @dev May leave dust ankrFLOW on the vault when `actualReceipts < receipts`.
    function _resolveUniqueShares(address vault, uint256 receipts) private view returns (uint256 shares) {
        IAnkrCertificateToken cert = IAnkrCertificateToken(receiptToken);
        shares = receipts;

        while (shares > 1) {
            uint256 projectedBond = cert.sharesToBonds(shares);
            if (!_amountInPendingRequests(vault, projectedBond)) {
                return shares;
            }
            unchecked {
                --shares;
            }
        }

        if (shares == 1 && !_amountInPendingRequests(vault, cert.sharesToBonds(shares))) {
            return shares;
        }

        revert DuplicateBondAmount();
    }

    /// @dev Completed when bond is absent from both pending queue and manual-claim bucket (threshold: `>= bondAmount`).
    function _isAutoSettled(address vault, uint256 bondAmount) private view returns (bool) {
        if (bondAmount == 0 || vault == address(0)) return false;

        IAnkrFlowStakingPool pool = IAnkrFlowStakingPool(stakingPool);

        if (pool.getForManualClaimOf(vault) >= bondAmount) return false;
        if (_amountInPendingRequests(vault, bondAmount)) return false;

        return true;
    }

    function _amountInPendingRequests(address claimer, uint256 amount) private view returns (bool) {
        uint256[] memory pending = IAnkrFlowStakingPool(stakingPool).getPendingRequestsOf(claimer);
        for (uint256 i; i < pending.length;) {
            if (pending[i] == amount) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
