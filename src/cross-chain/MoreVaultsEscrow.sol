// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {IConfigurationFacet} from "../interfaces/facets/IConfigurationFacet.sol";

interface IVaultEscrowHooks {
    function isAssetDepositable(address token) external view returns (bool);
}

/**
 * @title MoreVaultsEscrow
 * @dev Escrow contract for holding locked tokens during cross-chain operations
 * @notice Simplifies BridgeFacet by moving management of locked funds into a dedicated contract
 * 
 * Benefits of using Escrow:
 * 1. Separation of concerns: BridgeFacet focuses on cross-chain logic, Escrow on token custody
 * 2. Simpler BridgeFacet: no need to track pending balances inside the vault's storage
 * 3. Cleaner architecture: all locked funds are held in one place
 * 
 * Usage:
 * - On request creation: vault calls escrow.lockTokens() - ERC20 tokens are transferred into escrow; native (if any) is also moved into escrow
 * - On request execution: vault calls escrow.releaseTokensForExecution()
 *   - ERC20: escrow approves the vault, and vault pulls required amounts via transferFrom during ERC4626 calls
 *   - shares (WITHDRAW/REDEEM): vault burns shares directly from escrow during finalization
 *   - native (MULTI_ASSETS_DEPOSIT): escrow sends native to the vault so it can be used as msg.value in the deposit call
 * - After execution: vault calls escrow.unlockTokensAfterExecution() - excess (if any) is returned from escrow to the owner
 * - On refund: vault calls escrow.refundTokens() - all escrow-held assets/shares/native are returned to the appropriate recipient
 */
contract MoreVaultsEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error RequestNotFound();
    error RequestAlreadyExists();
    error RequestAlreadyFinalized();
    error RequestAlreadyRefunded();
    error InvalidActionType();
    error OwnerMustBeInitiator();
    error InsufficientTokensReceived();
    error EscrowNotSet();
    error TokenNotWhitelisted(address token);
    error ArraysLengthMismatch();
    error TokensMismatch();
    error NativeTransferFailed();
    error NativeRefundFailed();
    error UsedAmountExceedsReleased(uint256 usedAmount, uint256 releasedAmount);

    event TokensLocked(
        bytes32 indexed guid,
        address indexed vault,
        address indexed token,
        uint256 amount,
        address owner
    );
    event TokensUnlocked(
        bytes32 indexed guid,
        address indexed vault,
        address indexed token,
        uint256 amount,
        address recipient
    );
    event NativeLocked(bytes32 indexed guid, address indexed vault, uint256 amount);
    event NativeUnlocked(bytes32 indexed guid, address indexed vault, uint256 amount, address recipient);

    /// @dev Mapping vault => guid => locked funds info
    mapping(address vault => mapping(bytes32 guid => EscrowInfo)) public escrowInfo;

    struct EscrowInfo {
        /// @dev Owner of the tokens/shares (always equals initiator for all action types)
        address owner;
        /// @dev Type of action being executed (DEPOSIT, WITHDRAW, REDEEM, MINT, MULTI_ASSETS_DEPOSIT)
        MoreVaultsLib.ActionType actionType;
        /// @dev Whether the request has been finalized (execution completed)
        bool finalized;
        /// @dev Whether the request has been refunded (cancelled/refunded)
        bool refunded;
        /// @dev Array of token addresses locked in escrow for this request
        address[] tokens;
        /// @dev Mapping token => total amount locked in escrow (actual received amount, may exceed requiredAmount)
        mapping(address token => uint256) amount;
        /// @dev Mapping token => amount released/approved for vault execution (set in releaseTokensForExecution)
        /// @notice For ERC20 tokens: amount approved for vault to pull via transferFrom
        /// @notice For share tokens (WITHDRAW/REDEEM): amount of shares marked for burning
        mapping(address token => uint256) releasedAmount;
        /// @dev Mapping token => amount required for execution (from actionCallData/amountLimit)
        /// @notice This is the planned amount needed, may differ from actual used amount
        mapping(address token => uint256) requiredAmount;
        /// @dev Native token amount locked (only for MULTI_ASSETS_DEPOSIT)
        uint256 nativeAmount;
    }

    /// @dev Mapping vault => user => locked shares (for balance checks)
    mapping(address vault => mapping(address user => uint256)) public lockedSharesPerUser;

    /// @dev Factory that deployed vaults; used as allowlist source.
    address public immutable vaultsFactory;

    modifier onlyVault() {
        if (!IVaultsFactory(vaultsFactory).isFactoryVault(msg.sender)) {
            revert OnlyVault();
        }
        _;
    }

    constructor(address _vaultsFactory) {
        if (_vaultsFactory == address(0)) revert MoreVaultsLib.ZeroAddress();
        vaultsFactory = _vaultsFactory;
    }

    /**
     * @dev Locks tokens/shares in escrow for a cross-chain request
     * @notice Transfers tokens from initiator to escrow and records the amounts
     * @param guid Unique request identifier (GUID from cross-chain messaging)
     * @param actionType Type of action: DEPOSIT, MINT, WITHDRAW, REDEEM, MULTI_ASSETS_DEPOSIT
     * @param actionCallData Encoded action parameters (decoded based on actionType)
     * @param amountLimit Maximum amount for MINT/WITHDRAW (used as exact amount for these actions)
     * @param initiator Address initiating the request (must equal owner for WITHDRAW/REDEEM)
     * @notice For DEPOSIT/MINT: locks underlying asset tokens
     * @notice For WITHDRAW/REDEEM: locks vault shares (vault token itself)
     * @notice For MULTI_ASSETS_DEPOSIT: locks multiple tokens + optional native token
     */
    function lockTokens(
        bytes32 guid,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        uint256 amountLimit,
        address initiator
    ) external payable onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.owner != address(0)) {
            revert RequestAlreadyExists();
        }

        info.actionType = actionType;

        if (actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            if (msg.value != 0) revert InvalidActionType();
            (uint256 assets,) = abi.decode(actionCallData, (uint256, address));
            address assetToken = _getUnderlyingToken(vault_);
            info.owner = initiator;

            // Measure actual received amount using balance difference (handles potential transfer hooks)
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;

            info.tokens.push(assetToken);
            // Strict validation: must receive at least the requested amount (no fee-on-transfer tokens supported)
            if (actualReceived < assets) revert InsufficientTokensReceived();
            info.requiredAmount[assetToken] = assets;
            info.amount[assetToken] = actualReceived;

            emit TokensLocked(guid, vault_, assetToken, actualReceived, initiator);

        } else if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            _lockMultiAssetsDeposit(vault_, info, guid, actionCallData, initiator);

        } else if (actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            if (msg.value != 0) revert InvalidActionType();
            (, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));
            // Defense-in-depth: prevent initiating requests on behalf of an arbitrary owner
            // (e.g., with a pre-existing approval to escrow). Only the owner can initiate WITHDRAW.
            if (owner != initiator) revert OwnerMustBeInitiator();

            if (amountLimit == 0) {
                revert InvalidActionType();
            }
            uint256 shares = amountLimit;
            info.owner = owner;

            // Transfer shares from owner to escrow (owner must approve escrow first)
            // Shares are held by escrow and will be burned by vault during execution
            IERC20(vault_).safeTransferFrom(owner, address(this), shares);

            info.tokens.push(vault_); // vault address is the share token address
            info.amount[vault_] = shares;
            info.requiredAmount[vault_] = shares;
            lockedSharesPerUser[vault_][owner] += shares;

            emit TokensLocked(guid, vault_, vault_, shares, owner);

        } else if (actionType == MoreVaultsLib.ActionType.REDEEM) {
            if (msg.value != 0) revert InvalidActionType();
            (uint256 shares, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));
            // Defense-in-depth: prevent initiating requests on behalf of an arbitrary owner
            // (e.g., with a pre-existing approval to escrow). Only the owner can initiate REDEEM.
            if (owner != initiator) revert OwnerMustBeInitiator();
            info.owner = owner;

            // Transfer shares from owner to escrow (owner must approve escrow first)
            // Shares are held by escrow and will be burned by vault during execution
            IERC20(vault_).safeTransferFrom(owner, address(this), shares);

            info.tokens.push(vault_);
            info.amount[vault_] = shares;
            info.requiredAmount[vault_] = shares;
            lockedSharesPerUser[vault_][owner] += shares;

            emit TokensLocked(guid, vault_, vault_, shares, owner);

        } else if (actionType == MoreVaultsLib.ActionType.MINT) {
            if (msg.value != 0) revert InvalidActionType();
            abi.decode(actionCallData, (uint256, address)); // shares, receiver - unused

            if (amountLimit == 0) {
                revert InvalidActionType();
            }
            uint256 assets = amountLimit;
            address assetToken = _getUnderlyingToken(vault_);
            info.owner = initiator;

            // Measure actual received amount using balance difference
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;

            // For MINT: require full amountLimit assets (no fee-on-transfer tokens supported)
            if (actualReceived < assets) revert InsufficientTokensReceived();

            info.tokens.push(assetToken);
            info.requiredAmount[assetToken] = assets;
            info.amount[assetToken] = actualReceived;

            emit TokensLocked(guid, vault_, assetToken, actualReceived, initiator);
        }
        // No locking is required for ACCRUE_FEES
    }

    /**
     * @dev Internal function to lock multiple tokens for MULTI_ASSETS_DEPOSIT
     * @param vault_ Vault address
     * @param info EscrowInfo storage reference
     * @param guid Request identifier
     * @param actionCallData Decoded action data containing tokens, amounts, receiver, minAmountOut, value
     * @param initiator Request initiator
     * @notice Validates token whitelist before transfer, handles duplicate tokens by summing amounts
     */
    function _lockMultiAssetsDeposit(
        address vault_,
        EscrowInfo storage info,
        bytes32 guid,
        bytes calldata actionCallData,
        address initiator
    ) internal {
        (address[] memory tokens, uint256[] memory amounts, address receiver, uint256 minAmountOut, uint256 value) =
            abi.decode(actionCallData, (address[], uint256[], address, uint256, uint256));
        if (tokens.length != amounts.length) revert ArraysLengthMismatch();
        if (msg.value != value) revert InvalidActionType();

        // receiver and minAmountOut are validated/used by vault during execution, not here
        // No fee-on-transfer support: calldata amounts are used as-is
        receiver;
        minAmountOut;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 actualReceived = _lockOneMultiAssetToken(vault_, info, tokens[i], amounts[i], initiator);
            emit TokensLocked(guid, vault_, tokens[i], actualReceived, initiator);
        }

        if (value > 0) {
            info.nativeAmount = value;
            emit NativeLocked(guid, vault_, value);
        }
        info.owner = initiator;
    }

    /**
     * @dev Internal function to lock a single token for MULTI_ASSETS_DEPOSIT
     * @param vault_ Vault address
     * @param info EscrowInfo storage reference
     * @param token Token address to lock
     * @param amount Amount to transfer from initiator
     * @param initiator Request initiator
     * @return actualReceived Actual amount received (may differ from amount for tokens with hooks)
     * @notice Validates token whitelist before transfer to prevent arbitrary code execution
     * @notice Handles duplicate tokens by summing amounts (token added to array only once)
     */
    function _lockOneMultiAssetToken(
        address vault_,
        EscrowInfo storage info,
        address token,
        uint256 amount,
        address initiator
    ) internal returns (uint256 actualReceived) {
        // Validate token is whitelisted BEFORE transfer to prevent arbitrary code execution
        _validateAssetDepositable(vault_, token);

        // Add token to array only once (MULTI_ASSETS_DEPOSIT can include same token multiple times)
        // Required amounts are summed across all occurrences for approval
        if (info.requiredAmount[token] == 0 && info.amount[token] == 0) {
            info.tokens.push(token);
        }

        // Measure actual received amount using balance difference
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        actualReceived = balanceAfter - balanceBefore;

        // Strict validation: must receive at least requested amount (no fee-on-transfer tokens supported)
        if (actualReceived < amount) revert InsufficientTokensReceived();
        info.requiredAmount[token] += amount;
        info.amount[token] += actualReceived;
    }

    /**
     * @dev Prepares tokens for request execution by approving vault or marking shares for burning
     * @param guid Unique request identifier
     * @return tokens Array of token addresses involved in the request
     * @return amounts Array of amounts released for execution (matches tokens array)
     * @return nativeAmount Native token amount (transferred directly to vault)
     * @notice For ERC20 tokens: approves vault to pull tokens via transferFrom (doesn't transfer here)
     * @notice For share tokens (WITHDRAW/REDEEM): marks shares as released (vault burns from escrow)
     * @notice For native token: transfers directly to vault for use as msg.value
     * @notice Must be called before vault executes the action, followed by unlockTokensAfterExecution
     */
    function releaseTokensForExecution(bytes32 guid)
        external
        onlyVault
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.owner == address(0)) {
            revert RequestNotFound();
        }
        if (info.refunded) {
            revert RequestAlreadyRefunded();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        tokens = info.tokens;
        amounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 required = info.requiredAmount[token];

            // Handle share tokens (WITHDRAW/REDEEM): shares are held by escrow, vault burns them directly
            if (token == vault_ && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                uint256 shares = required;
                if (shares > 0) {
                    amounts[i] = shares;
                    info.releasedAmount[token] = shares; // Mark as released for accounting
                    // Shares remain in escrow, vault will burn them during execution
                }
            } else {
                // ERC20 tokens: validate we have enough locked, then approve vault to pull
                if (info.amount[token] < required) {
                    revert InsufficientTokensReceived();
                }

                // Approve vault to pull tokens (don't transfer here - vault pulls via transferFrom during ERC4626 call)
                // Uses forceApprove to handle tokens like USDT that require zero before non-zero approval
                IERC20(token).forceApprove(vault_, required);
                amounts[i] = required;
                info.releasedAmount[token] = required;
            }
        }

        nativeAmount = info.nativeAmount;
        if (nativeAmount > 0) {
            (bool success,) = vault_.call{value: nativeAmount}("");
            if (!success) revert NativeTransferFailed();
        }
    }

    /**
     * @dev Cleans up after successful request execution: returns excess tokens and clears storage
     * @param guid Unique request identifier
     * @param tokens Array of token addresses (must match tokens from releaseTokensForExecution)
     * @param usedAmounts Array of actual amounts used by vault (matches tokens array)
     * @notice Called by vault after successful execution to:
     *   - Return excess tokens if usedAmount < releasedAmount
     *   - Return any tokens that were locked but not released
     *   - Clear allowances and storage
     *   - Update lockedSharesPerUser for WITHDRAW/REDEEM
     * @notice Reverts if usedAmount > releasedAmount (indicates logic error in vault)
     */
    function unlockTokensAfterExecution(
        bytes32 guid,
        address[] memory tokens,
        uint256[] memory usedAmounts
    ) external onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.owner == address(0)) {
            revert RequestNotFound();
        }
        if (info.refunded) {
            revert RequestAlreadyRefunded();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        info.finalized = true;

        // Validate tokens array matches stored tokens
        if (tokens.length != usedAmounts.length) revert ArraysLengthMismatch();
        if (tokens.length != info.tokens.length) revert ArraysLengthMismatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != info.tokens[i]) revert TokensMismatch();
        }

        // Unlock tokens and return excess
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            // Cache storage reads for gas optimization
            uint256 released = info.releasedAmount[token];
            uint256 usedAmount = usedAmounts[i];
            uint256 totalLocked = info.amount[token];
            bool isShareToken = token == vault_;
            bool isWithdrawOrRedeem = info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM;

            // Safety check: used amount should never exceed released amount
            if (usedAmount > released) {
                revert UsedAmountExceedsReleased(usedAmount, released);
            }

            // Handle share tokens (WITHDRAW/REDEEM): shares were burned by vault, update accounting
            if (isShareToken && isWithdrawOrRedeem) {
                lockedSharesPerUser[vault_][info.owner] -= released;
                // Clear storage: shares were burned by vault during execution
                info.amount[token] = 0;                
                // Return excess shares if vault burned less than was released
                if (usedAmount < released) {
                    uint256 excessShares = released - usedAmount;
                    IERC20(token).safeTransfer(info.owner, excessShares);
                    emit TokensUnlocked(guid, vault_, token, excessShares, info.owner);
                }
            }

            // Handle ERC20 tokens: return excess and clear storage
            if (!isShareToken) {
                // Return excess if vault used less than was released (e.g., slippage protection)
                if (usedAmount < released) {
                    uint256 excess = released - usedAmount;
                    IERC20(token).safeTransfer(info.owner, excess);
                    emit TokensUnlocked(guid, vault_, token, excess, info.owner);
                }

                // Return any tokens that were locked but never released (shouldn't happen normally)
                if (totalLocked > released) {
                    uint256 remainingAmount = totalLocked - released;
                    info.amount[token] = 0;
                    IERC20(token).safeTransfer(info.owner, remainingAmount);
                    emit TokensUnlocked(guid, vault_, token, remainingAmount, info.owner);
                } else {
                    // All locked tokens were released, just clear storage
                    info.amount[token] = 0;
                }

                // Clear allowance for security (defense-in-depth: vault shouldn't have access after execution)
                IERC20(token).forceApprove(vault_, 0);
            }
        }
    }

    /**
     * @dev Refunds all locked tokens/shares/native to the owner when request is cancelled
     * @param guid Unique request identifier
     * @notice Called by vault when cross-chain request fails or times out
     * @notice For native token: attempts to refund to owner, falls back to cross-chain accounting manager if owner rejects
     * @notice Clears allowances and updates lockedSharesPerUser accounting
     * @notice Idempotent: returns early if already refunded or finalized
     */
    function refundTokens(bytes32 guid) external onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.owner == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized || info.refunded) {
            return; // Already processed
        }

        info.refunded = true;

        // Refund native token: try owner first, fallback to cross-chain accounting manager if owner rejects
        if (info.nativeAmount > 0) {
            (bool success,) = info.owner.call{value: info.nativeAmount}("");
            if (!success) {
                // Owner contract may reject native transfers, redirect to manager (e.g., LayerZero adapter)
                address manager = IConfigurationFacet(vault_).getCrossChainAccountingManager();
                if (manager == address(0)) revert NativeRefundFailed();

                (success,) = payable(manager).call{value: info.nativeAmount}("");
                if (!success) revert NativeRefundFailed();
                emit NativeUnlocked(guid, vault_, info.nativeAmount, manager);
            } else {
                emit NativeUnlocked(guid, vault_, info.nativeAmount, info.owner);
            }
        }

        // Refund all tokens to owner
        _refundTokensToRecipient(guid, vault_, info, info.owner);
    }

    /**
     * @dev Internal function to refund tokens to a recipient
     * @param guid Unique request identifier
     * @param recipient Address to receive the refund (owner or composer)
     * @notice Used by refundToComposer to refund to composer instead of owner
     * @notice Validates request exists and hasn't been finalized/refunded
     * @notice Refunds native token directly, delegates token refunds to _refundTokensToRecipient
     */
    function _refundTokens(bytes32 guid, address recipient) internal {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.owner == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized || info.refunded) {
            return;
        }

        info.refunded = true;

        // Refund native token to recipient
        if (info.nativeAmount > 0) {
            (bool success,) = recipient.call{value: info.nativeAmount}("");
            if (!success) revert NativeTransferFailed();
            emit NativeUnlocked(guid, vault_, info.nativeAmount, recipient);
        }

        // Refund all tokens to recipient
        _refundTokensToRecipient(guid, vault_, info, recipient);
    }

    /**
     * @dev Internal helper to refund ERC20 tokens and shares to a recipient
     * @param guid Unique request identifier
     * @param vault_ Vault address (msg.sender)
     * @param info EscrowInfo storage reference
     * @param recipient Address to receive the refund
     * @notice Handles both ERC20 tokens and share tokens
     * @notice Updates lockedSharesPerUser accounting for WITHDRAW/REDEEM
     * @notice Clears allowances and storage after refund
     */
    function _refundTokensToRecipient(
        bytes32 guid,
        address vault_,
        EscrowInfo storage info,
        address recipient
    ) internal {
        address[] memory tokens = info.tokens;
        bool isWithdrawOrRedeem = info.actionType == MoreVaultsLib.ActionType.WITHDRAW
            || info.actionType == MoreVaultsLib.ActionType.REDEEM;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            bool isShareToken = token == vault_;

            // Update locked shares accounting for WITHDRAW/REDEEM
            if (isShareToken && isWithdrawOrRedeem) {
                uint256 requiredShares = info.requiredAmount[token];
                lockedSharesPerUser[vault_][info.owner] -= requiredShares;
            }

            if (isShareToken) {
                // Refund shares: if shares were released to vault, BridgeFacet must return them first
                uint256 shares = info.requiredAmount[token];
                if (shares > 0) {
                    IERC20(token).safeTransfer(recipient, shares);
                    emit TokensUnlocked(guid, vault_, token, shares, recipient);
                }
            } else {
                // Refund ERC20 tokens: clear allowance and transfer all locked amount
                IERC20(token).forceApprove(vault_, 0); // Clear allowance (defense-in-depth)

                uint256 amountToRefund = info.amount[token];
                if (amountToRefund > 0) {
                    info.amount[token] = 0; // Clear storage before transfer
                    IERC20(token).safeTransfer(recipient, amountToRefund);
                    emit TokensUnlocked(guid, vault_, token, amountToRefund, recipient);
                }
            }
        }
    }

    /**
     * @dev Refunds tokens to the composer when refunding a stuck deposit from composer
     * @param guid Unique request identifier
     * @param composer Composer address to receive the refund
     * @notice Used when a deposit initiated by vault composer gets stuck
     * @notice Similar to refundTokens but refunds to composer instead of original owner
     * @notice Reverts if composer is zero address
     */
    function refundToComposer(bytes32 guid, address composer) external onlyVault nonReentrant {
        if (composer == address(0)) revert MoreVaultsLib.ZeroAddress();
        _refundTokens(guid, composer);
    }

    /**
     * @dev Returns information about locked tokens for a request
     * @param vault_ Vault address
     * @param guid Unique request identifier
     * @return tokens Array of token addresses locked in escrow
     * @return amounts Array of required amounts (what will be released for execution)
     * @return nativeAmount Native token amount locked (0 if not MULTI_ASSETS_DEPOSIT)
     * @notice Returns requiredAmount, not actual locked amount (for compatibility with BridgeFacet)
     */
    function getEscrowInfo(address vault_, bytes32 guid)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        EscrowInfo storage info = escrowInfo[vault_][guid];
        tokens = info.tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            // For compatibility, return required amount (what is planned to be released to the vault for execution)
            amounts[i] = info.requiredAmount[tokens[i]];
        }
        nativeAmount = info.nativeAmount;
    }

    /**
     * @dev Returns user's locked shares
     * @param user User address
     * @return Locked shares
     */
    function getLockedShares(address vault_, address user) external view returns (uint256) {
        return lockedSharesPerUser[vault_][user];
    }

    /**
     * @dev Validates that a token is whitelisted for deposit in the vault
     * @param vault_ Vault address
     * @param token Token address to validate
     * @notice Reverts if token is not whitelisted
     * @notice Called BEFORE transfer to prevent arbitrary code execution via malicious token transferFrom hooks
     */
    function _validateAssetDepositable(address vault_, address token) internal view {
        if (!IVaultEscrowHooks(vault_).isAssetDepositable(token)) {
            revert TokenNotWhitelisted(token);
        }
    }

    /**
     * @dev Helper function to get the underlying token address
     * @return Underlying token address of the vault
     */
    function _getUnderlyingToken(address vault_) internal view returns (address) {
        return IERC4626(vault_).asset();
    }


    /**
     * @dev Receive function to accept native token transfers
     * @notice Used for MULTI_ASSETS_DEPOSIT when native token is included
     * @notice Native token is sent via msg.value in lockTokens call, not via this function
     */
    receive() external payable {
        // This function exists for safety but native tokens are sent via msg.value in lockTokens
    }
}
