// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAnkrFlowPool} from "../interfaces/external/ankr/IAnkrFlowPool.sol";
import {IAnkrFlowToken} from "../interfaces/external/ankr/IAnkrFlowToken.sol";
import {IWrappedNative} from "../interfaces/external/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AnkrAdapter
 * @notice Protocol adapter for Ankr's Flow Liquid Staking (ankrFLOW).
 *
 * Why this exists
 * ---------------
 * The MORE Vaults `StakingFacet` is built on top of `IProtocolAdapter` so it
 * can talk to any protocol uniformly. Ankr's Flow pool deviates from the
 * pattern in two ways that this adapter normalises:
 *
 *   1. The pool takes / returns NATIVE FLOW, not WFLOW. The vault, however,
 *      tracks WFLOW (the wrapped form in `availableAssets`). We therefore
 *      unwrap on the way in and wrap on the way out so the facet only ever
 *      sees the ERC-20.
 *
 *   2. `unstakeCerts` does not return a per-call request id — pending claims
 *      are aggregated by claimer address. We mint our own opaque id so the
 *      facet's `withdrawalRequests` mapping still works, and we remember
 *      the expected FLOW per request so `finalizeUnstake` can settle one at
 *      a time even when the pool pays them out batched.
 *
 * Deposit token / receipt token
 * -----------------------------
 *   depositToken  = WFLOW (0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e)
 *   receiptToken  = ankrFLOW (0x1b97100eA1D7126C4d60027e231EA4CB25314bdb)
 *
 * Unbonding window
 * ----------------
 * Flow protocol unbond ≈ 7–15 days; the pool does not expose this on-chain
 * as a constant. We seed an optimistic 7-day timer locally (matching the
 * StakingFacet's `timelockEnd` convention) so the facet's curator-side
 * `finalizeUnstake` doesn't try to settle prematurely. The real availability
 * is still gated by `isWithdrawalClaimable` which queries the pool.
 *
 * Reward stream
 * -------------
 * ankrFLOW is reward-bearing through price appreciation (the cert token's
 * `ratio()` grows over time). There is no separate reward token to claim,
 * so `harvest()` returns empty arrays and `getPendingRewards()` returns 0.
 */
contract AnkrAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------
    address public immutable depositToken; // WFLOW
    address public immutable receiptToken; // ankrFLOW
    IAnkrFlowPool public immutable pool;
    IAnkrFlowToken public immutable cert;

    // -------------------------------------------------------------------------
    // Local request tracking
    // -------------------------------------------------------------------------
    struct UnstakeRequest {
        uint256 expectedAmount; // FLOW expected at request time (via sharesToBonds)
        uint64  createdAt;      // timestamp the request was made
        bool    finalized;      // settled by finalizeUnstake
    }

    mapping(bytes32 => UnstakeRequest) public requests;
    uint256 private _requestNonce;

    /// @dev Soft-hint window before `isWithdrawalClaimable` is willing to say "yes".
    ///      The pool itself is the source of truth, but the StakingFacet's
    ///      curator flow polls this view so we err on the safe side.
    uint64 public constant UNBONDING_HINT = 7 days;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------
    error ZeroAmount();
    error WithdrawalNotFound();
    error WithdrawalAlreadyFinalized();
    error WithdrawalNotReady();
    error NativeTransferFailed();
    error InsufficientNativeBalance();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(address _depositToken, address _pool) {
        if (_depositToken == address(0) || _pool == address(0)) revert ZeroAmount();
        depositToken = _depositToken;
        pool = IAnkrFlowPool(_pool);
        (, address _cert) = IAnkrFlowPool(_pool).getTokens();
        receiptToken = _cert;
        cert = IAnkrFlowToken(_cert);
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // IProtocolAdapter — write
    // -------------------------------------------------------------------------

    /**
     * @notice Stake `amount` of WFLOW into Ankr's Flow pool. Returns the
     *         ankrFLOW receipts minted to the caller.
     * @dev    Flow:
     *           1. pull WFLOW from msg.sender
     *           2. unwrap to native FLOW
     *           3. snapshot ankrFLOW balance, call `stakeCerts{value: amount}()`
     *           4. transfer the minted ankrFLOW back to msg.sender
     */
    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        if (amount == 0) revert ZeroAmount();

        IERC20(depositToken).safeTransferFrom(msg.sender, address(this), amount);
        IWrappedNative(depositToken).withdraw(amount);

        uint256 balanceBefore = IERC20(receiptToken).balanceOf(address(this));
        pool.stakeCerts{value: amount}();
        receipts = IERC20(receiptToken).balanceOf(address(this)) - balanceBefore;

        IERC20(receiptToken).safeTransfer(msg.sender, receipts);
    }

    /**
     * @notice Burn `receipts` ankrFLOW and queue an unstake.
     * @dev    Generates a local request id; the pool itself aggregates pending
     *         claims by adapter address, but the StakingFacet expects per-call
     *         ids so we mint our own and remember the expected payout amount.
     *         No external call value is moved here — funds arrive later via
     *         `distributePendingRewards` (auto-push) or `claimManually`.
     */
    function requestUnstake(uint256 receipts, bytes calldata)
        external
        returns (bytes32 requestId)
    {
        if (receipts == 0) revert ZeroAmount();

        IERC20(receiptToken).safeTransferFrom(msg.sender, address(this), receipts);

        // Snapshot the FLOW expected for these shares. Used by finalizeUnstake
        // to settle a specific request even when the pool batches payouts.
        uint256 expected = cert.sharesToBonds(receipts);

        unchecked {
            _requestNonce += 1;
        }
        requestId = keccak256(abi.encodePacked(msg.sender, _requestNonce, block.timestamp));

        requests[requestId] = UnstakeRequest({
            expectedAmount: expected,
            createdAt: uint64(block.timestamp),
            finalized: false
        });

        pool.unstakeCerts(receipts);
    }

    /**
     * @notice Settle a previously-requested unstake. Wraps native FLOW back to
     *         WFLOW and returns it to the caller (typically the StakingFacet).
     * @dev    Two pathways depending on what the pool did:
     *           - Auto-push succeeded → adapter already holds the FLOW.
     *           - Auto-push failed → `isMarkedForManualClaim(this) == true`,
     *             pull funds via `claimManually(this)`.
     *         We then wrap the request's `expectedAmount` worth back to WFLOW.
     *         If for some reason the held balance is below `expectedAmount`
     *         (e.g. slashing, partial settlement) we revert rather than send
     *         a short amount silently.
     */
    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount) {
        UnstakeRequest storage req = requests[requestId];
        if (req.expectedAmount == 0) revert WithdrawalNotFound();
        if (req.finalized) revert WithdrawalAlreadyFinalized();

        // Pull from manual-claim escrow if the auto-push to this contract failed.
        if (pool.isMarkedForManualClaim(address(this))) {
            pool.claimManually(address(this));
        }

        amount = req.expectedAmount;
        if (address(this).balance < amount) revert InsufficientNativeBalance();

        req.finalized = true;

        IWrappedNative(depositToken).deposit{value: amount}();
        IERC20(depositToken).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice ankrFLOW is reward-bearing via price appreciation — no separate
     *         token stream to harvest.
     */
    function harvest()
        external
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = new address[](0);
        amounts = new uint256[](0);
    }

    // -------------------------------------------------------------------------
    // IProtocolAdapter — view
    // -------------------------------------------------------------------------

    function getPendingRewards() external pure returns (uint256) {
        return 0;
    }

    /// @notice Convert ankrFLOW shares to FLOW (1:1 with `depositToken` accounting).
    function getDepositTokenForReceipts(uint256 receiptAmount)
        external
        view
        returns (uint256)
    {
        if (receiptAmount == 0) return 0;
        return cert.sharesToBonds(receiptAmount);
    }

    /**
     * @notice Best-effort claimability check. The pool exposes no per-request
     *         flag, so this returns true once:
     *           - the request exists and has not been finalized, AND
     *           - the soft `UNBONDING_HINT` window has elapsed, AND
     *           - either the adapter already holds enough FLOW or the pool
     *             flags us for manual claim.
     */
    function isWithdrawalClaimable(bytes32 requestId) external view returns (bool) {
        UnstakeRequest storage req = requests[requestId];
        if (req.expectedAmount == 0 || req.finalized) return false;
        if (block.timestamp < uint256(req.createdAt) + UNBONDING_HINT) return false;
        return address(this).balance >= req.expectedAmount
            || pool.isMarkedForManualClaim(address(this));
    }

    function getProtocolName() external pure returns (string memory) {
        return "AnkrFlow";
    }
}
