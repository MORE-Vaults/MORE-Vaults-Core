// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../../interfaces/IProtocolAdapter.sol";
import {IWrappedToken} from "../../interfaces/IWrappedToken.sol";
import {ILido} from "../../interfaces/external/lido/ILido.sol";
import {IWstETH} from "../../interfaces/external/lido/IWstETH.sol";
import {IWithdrawalQueue} from "../../interfaces/external/lido/IWithdrawalQueue.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LidoAdapter
 * @notice Stateless adapter for Lido liquid staking (wstETH) used by StakingFacet
 * @dev Execution paths are delegatecall-safe: only immutables and external calls.
 *      Staking uses WETH as depositToken; ETH is forwarded to Lido and wrapped as wstETH.
 *      Mainnet references: wstETH 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
 *      WithdrawalQueue 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1.
 *
 *      Stake:
 *      - Default: unwrap WETH → send ETH to wstETH (auto submit + wrap).
 *      - Optional `params`: abi.encode(referral) uses `ILido.submit` + `IWstETH.wrap`.
 *
 *      Unstake:
 *      - `requestWithdrawalsWstETH` locks wstETH in the queue and mints an unstETH NFT to the vault.
 *      - `protocolRequestId` is `bytes32(requestId)` from the queue.
 *      - The unstETH ERC721 **must stay owned by the vault** until `finalizeUnstake`. Transferring or selling
 *        the NFT breaks `claimWithdrawal` (`NotOwner`) and leaves the facet `WithdrawalRequest` unclosable.
 *        Do not route unstETH through generic NFT-transfer flows.
 *      - Lido enforces at most `MAX_STETH_WITHDRAWAL_AMOUNT` (1000 stETH) per queue entry, checked on the
 *        stETH amount after unwrapping wstETH. This adapter creates exactly one queue entry per call and
 *        returns one `protocolRequestId`. Withdrawals above the limit must be split into multiple
 *        `StakingFacet.requestUnstake` transactions (one facet `requestId` and one unstETH NFT each).
 *        Before unstaking large wstETH balances, ensure `IWstETH.getStETHByWstETH(receipts)` is within the
 *        limit (wstETH amount alone is not the on-chain check).
 *
 *      Finalize:
 *      - `claimWithdrawal` delivers **native ETH** to the vault (not WETH). The adapter does not wrap on exit.
 *      - Each request is claimed independently (no shared manual-claim bucket like Ankr/sFlow).
 *      - Returned `amount` / `UnstakeFinalized.nativeAmountReceived` is the vault native balance delta.
 *      - Default finalize uses `claimWithdrawal` (on-chain hint search; may OOG on very old requests). Pass
 *        `abi.encode(hint)` in `params` to call `claimWithdrawals` instead; hint from `getClaimHint` for
 *        moderately old requests. For very stale requestIds, `getClaimHint` itself may OOG on-chain — compute
 *        the checkpoint hint off-chain (Lido SDK / withdrawal API) and pass it in `params`.
 *
 *      Slashing / discounted finalization:
 *      - Open withdrawals accrue in accounting via `amountOfStETH` fixed at request time. If Lido finalizes a
 *        request below that amount after validator losses, claimable native ETH can be less than
 *        `getAccountingDepositValue` until `finalizeUnstake`; actual payout is reflected only after claim.
 *        This is Lido protocol risk, not an adapter bug.
 *
 *      Native ETH on the vault:
 *      - NAV: `VaultFacet` counts `address(vault).balance` together with the WETH ERC-20 balance when WETH is
 *        the diamond `wrappedNative` and listed in `availableAssets`. Unclaimed staking position value remains
 *        in `getAccountingDepositValue` until `finalizeUnstake` removes it from the adapter bucket.
 *      - Wallet: after finalize, proceeds sit as **native ETH** until the curator wraps via WETH.deposit or
 *        spends through a facet that accepts native. ERC20-only flows see zero WETH until wrap.
 *
 *      Deployment / ops:
 *      - `depositToken` (WETH) must equal the diamond `wrappedNative` and **must stay** in `availableAssets`.
 *        `MoreVaultsDiamond.receive()` reverts with `NativeTokenNotAvailable` when WETH is not available;
 *        Lido `claimWithdrawal` sends ETH to the vault and will fail finalize if receive rejects it.
 *      - Stake already requires WETH in `availableAssets` via `_resolveAdapterTokens`; do not remove WETH while
 *        Lido (or Ankr/sFlow) withdrawals are open or claimable.
 *      - Whitelist wstETH (`receiptToken`) in `availableAssets` if wallet balances should appear in VaultFacet;
 *        adapter accounting excludes wallet wstETH when it is listed (see `receiptIsAvailableAsset`).
 *
 *      Informational:
 *      - `getWithdrawalClaimableAt` returns `block.timestamp` once finalized; otherwise
 *        `block.timestamp + WITHDRAWAL_ETA_UPPER_BOUND` (~5 days). Not enforced by StakingFacet.
 */
contract LidoAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidStETHAddress(address wstETH);
    error WstEthStakeFailed();

    /// @dev Mirrors Lido `WithdrawalQueue.MAX_STETH_WITHDRAWAL_AMOUNT`. One unstake request per adapter call.
    uint256 public constant MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;

    /// @dev Informational upper bound for curator UI; Lido finalization is typically 1–5 days.
    uint256 private constant WITHDRAWAL_ETA_UPPER_BOUND = 5 days;

    address public immutable withdrawalQueue;
    address public immutable depositToken;
    address public immutable receiptToken;
    address public immutable stETH;

    constructor(address _wstETH, address _withdrawalQueue, address _wrappedNative) {
        if (_wstETH == address(0) || _withdrawalQueue == address(0) || _wrappedNative == address(0)) {
            revert ZeroAddress();
        }

        address stETHAddress = IWstETH(_wstETH).stETH();
        if (stETHAddress == address(0)) {
            revert InvalidStETHAddress(_wstETH);
        }

        receiptToken = _wstETH;
        withdrawalQueue = _withdrawalQueue;
        depositToken = _wrappedNative;
        stETH = stETHAddress;
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        (uint256 pendingReceipts,) = _sumOpenWithdrawals(vault);
        return pendingReceipts;
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(vault);
    }

    /// @dev Pending queue value uses `amountOfStETH` at request time; may exceed claimable ETH after Lido slashing
    ///      until finalize reflects the actual native payout.
    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        (, depositTokenAmount) = _sumOpenWithdrawals(vault);

        if (!receiptIsAvailableAsset) {
            depositTokenAmount +=
                IWstETH(receiptToken).getStETHByWstETH(IERC20(receiptToken).balanceOf(vault));
        }
    }

    /// @notice Stake WETH into Lido and receive wstETH on the vault wallet.
    /// @param params Optional `abi.encode(address referral)` for `ILido.submit`; empty uses wstETH receive shortcut.
    function stake(uint256 amount, bytes calldata params) external returns (uint256 receipts) {
        uint256 balanceBefore = IERC20(receiptToken).balanceOf(address(this));

        IWrappedToken(depositToken).withdraw(amount);

        if (params.length == 0) {
            (bool success,) = receiptToken.call{value: amount}("");
            if (!success) revert WstEthStakeFailed();
        } else {
            address referral = abi.decode(params, (address));
            uint256 stETHAmount = ILido(stETH).submit{value: amount}(referral);
            IERC20(stETH).forceApprove(receiptToken, stETHAmount);
            IWstETH(receiptToken).wrap(stETHAmount);
            IERC20(stETH).forceApprove(receiptToken, 0);
        }

        receipts = IERC20(receiptToken).balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Queue wstETH withdrawal via Lido WithdrawalQueue (single queue entry).
    /// @dev Reverts when the unwrapped stETH amount exceeds `MAX_STETH_WITHDRAWAL_AMOUNT`. Split large
    ///      exits across multiple facet `requestUnstake` calls; auto-split inside the adapter is intentionally
    ///      not implemented because `IProtocolAdapter.requestUnstake` returns only one `protocolRequestId`.
    ///      Mints unstETH to the vault — do not transfer the NFT before finalize.
    function requestUnstake(uint256 receipts, bytes calldata)
        external
        returns (bytes32 requestId, uint256 actualReceipts)
    {
        IERC20(receiptToken).forceApprove(withdrawalQueue, receipts);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = receipts;

        uint256[] memory requestIds =
            IWithdrawalQueue(withdrawalQueue).requestWithdrawalsWstETH(amounts, address(this));

        IERC20(receiptToken).forceApprove(withdrawalQueue, 0);

        requestId = bytes32(requestIds[0]);
        actualReceipts = receipts;
    }

    /// @notice Claim finalized Lido withdrawal; delivers native ETH to the vault (not WETH).
    /// @param params Optional `abi.encode(uint256 hint)` for `claimWithdrawals`; empty uses `claimWithdrawal`.
    /// @dev Hint from `getClaimHint` for moderately old requests; for very stale ids compute hint off-chain
    ///      (Lido SDK / withdrawal API) — on-chain lookup may OOG. Empty `params` is fine for recent requests.
    function finalizeUnstake(bytes32 requestId, bytes calldata params) external returns (uint256 amount) {
        uint256 id = uint256(requestId);
        if (_isWithdrawalCompleted(address(this), id)) {
            return 0;
        }

        uint256 balanceBefore = address(this).balance;
        IWithdrawalQueue queue = IWithdrawalQueue(withdrawalQueue);

        if (params.length == 0) {
            queue.claimWithdrawal(id);
        } else {
            uint256 hint = abi.decode(params, (uint256));
            uint256[] memory ids = new uint256[](1);
            uint256[] memory hints = new uint256[](1);
            ids[0] = id;
            hints[0] = hint;
            queue.claimWithdrawals(ids, hints);
        }

        amount = address(this).balance - balanceBefore;
    }

    /// @notice Lido checkpoint hint for `finalizeUnstake(..., abi.encode(hint))`. View-only; returns 0 for id 0.
    /// @dev Wraps `findCheckpointHints([requestId], 1, getLastCheckpointIndex())`. Avoids OOG in
    ///      `claimWithdrawal` for moderately old requests. For very stale requestIds this view itself may OOG —
    ///      compute the hint off-chain and pass it directly in `finalizeUnstake` params.
    function getClaimHint(bytes32 requestId) external view returns (uint256 hint) {
        uint256 id = uint256(requestId);
        if (id == 0) return 0;
        return _lookupClaimHint(id);
    }

    /// @notice Lido has no shared stranded-withdrawal bucket; always returns 0.
    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256 amount) {
        amount = 0;
    }

    function isWithdrawalClaimable(address vault, bytes32 requestId) external view returns (bool) {
        uint256 id = uint256(requestId);
        if (id == 0) return false;

        IWithdrawalQueue.WithdrawalRequestStatus memory status = _getRequestStatus(id);
        if (status.owner != vault) return false;

        return status.isFinalized && !status.isClaimed;
    }

    function isWithdrawalCompleted(address vault, bytes32 requestId) external view returns (bool) {
        return _isWithdrawalCompleted(vault, uint256(requestId));
    }

    function getWithdrawalClaimableAt(address vault, bytes32 requestId) external view returns (uint256) {
        uint256 id = uint256(requestId);
        if (id == 0) return 0;

        IWithdrawalQueue.WithdrawalRequestStatus memory status = _getRequestStatus(id);
        if (status.owner != vault || status.isClaimed) return 0;
        if (status.isFinalized) return block.timestamp;

        return status.timestamp + WITHDRAWAL_ETA_UPPER_BOUND;
    }

    /// @notice Lido WithdrawalQueue does not gate new unstake requests on open claims.
    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Lido";
    }

    function _isWithdrawalCompleted(address vault, uint256 id) private view returns (bool) {
        if (id == 0 || vault == address(0)) return false;

        IWithdrawalQueue.WithdrawalRequestStatus memory status = _getRequestStatus(id);
        return status.owner == vault && status.isClaimed;
    }

    function _getRequestStatus(uint256 id)
        private
        view
        returns (IWithdrawalQueue.WithdrawalRequestStatus memory status)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            IWithdrawalQueue(withdrawalQueue).getWithdrawalStatus(ids);
        return statuses[0];
    }

    function _lookupClaimHint(uint256 id) private view returns (uint256 hint) {
        IWithdrawalQueue queue = IWithdrawalQueue(withdrawalQueue);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory hints = queue.findCheckpointHints(ids, 1, queue.getLastCheckpointIndex());
        return hints[0];
    }

    /// @dev Single pass over open withdrawal requests. Shares ≈ wstETH receipt units; stETH ≈ WETH deposit value.
    function _sumOpenWithdrawals(address vault)
        private
        view
        returns (uint256 pendingReceipts, uint256 pendingDepositValue)
    {
        uint256[] memory requestIds = IWithdrawalQueue(withdrawalQueue).getWithdrawalRequests(vault);
        if (requestIds.length == 0) return (0, 0);

        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            IWithdrawalQueue(withdrawalQueue).getWithdrawalStatus(requestIds);

        for (uint256 i; i < statuses.length;) {
            IWithdrawalQueue.WithdrawalRequestStatus memory status = statuses[i];
            if (!status.isClaimed) {
                pendingReceipts += status.amountOfShares;
                pendingDepositValue += status.amountOfStETH;
            }
            unchecked {
                ++i;
            }
        }
    }
}
