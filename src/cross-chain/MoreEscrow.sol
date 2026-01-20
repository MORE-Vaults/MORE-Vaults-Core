// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";

interface IVaultEscrowHooks {
    function isAssetDepositable(address token) external view returns (bool);

    function isFeeOnTransferDepositAllowed(address token) external view returns (bool);

    function updateCrossChainRequestActionCallData(bytes32 guid, bytes calldata newActionCallData) external;
}

/**
 * @title MoreEscrow
 * @dev Escrow contract for holding locked tokens during cross-chain operations
 * @notice Simplifies BridgeFacet by moving management of locked funds into a dedicated contract
 * 
 * Benefits of using Escrow:
 * 1. Separation of concerns: BridgeFacet focuses on cross-chain logic, Escrow on token custody
 * 2. Simpler BridgeFacet: no need to track pending balances inside the vault's storage
 * 3. Cleaner architecture: all locked funds are held in one place
 * 
 * Usage:
 * - On request creation: vault calls escrow.lockTokens() - ERC20 + shares are transferred into escrow; native (if any) is also moved into escrow
 * - On request execution: vault calls escrow.releaseTokensForExecution()
 *   - ERC20: escrow approves the vault, and vault pulls required amounts via transferFrom during ERC4626 calls
 *   - shares (WITHDRAW/REDEEM): vault burns shares directly from escrow during finalization
 *   - native (MULTI_ASSETS_DEPOSIT): escrow sends native to the vault so it can be used as msg.value in the deposit call
 * - After execution: vault calls escrow.unlockTokensAfterExecution() - excess (if any) is returned from escrow to the owner
 * - On refund: vault calls escrow.refundTokens() - all escrow-held assets/shares/native are returned to the appropriate recipient
 */
contract MoreEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error RequestNotFound();
    error RequestAlreadyExists();
    error RequestAlreadyFinalized();
    error RequestAlreadyRefunded();
    error InvalidActionType();
    error InsufficientTokensReceived();
    error EscrowNotSet();
    error TokenNotWhitelisted(address token);
    error FeeOnTransferNotAllowed(address token);
    error ArraysLengthMismatch();
    error NativeTransferFailed();
    error NativeRefundFailed();

    event TokensLocked(
        bytes32 indexed guid,
        address indexed vault,
        address indexed token,
        uint256 amount,
        address owner
    );
    /// @notice Emitted when deposit amounts are adjusted down due to fee-on-transfer (allowed mode).
    event DepositAmountAdjusted(
        bytes32 indexed guid,
        address indexed vault,
        address indexed token,
        uint256 requestedAmount,
        uint256 effectiveAmount
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
        address initiator;
        address owner; // For WITHDRAW/REDEEM - share owner, for others - initiator
        MoreVaultsLib.ActionType actionType;
        bool finalized;
        bool refunded;
        // Tokens and their amounts
        address[] tokens;
        // For rebasing ERC20 tokens we store shares to fairly distribute rebases across multiple concurrent locks.
        // For share-token vault (WITHDRAW/REDEEM) we use amount.
        mapping(address token => uint256) sharesOrAmount;
        // How much was reserved for execution (absolute amounts). For ERC20 the vault pulls from escrow via allowance.
        mapping(address token => uint256) releasedAmount;
        // How much needs to be used for execution (absolute amounts).
        mapping(address token => uint256) requiredAmount;
        // Native token (for MULTI_ASSETS_DEPOSIT)
        uint256 nativeAmount;
    }

    /// @dev Mapping vault => user => locked shares (for balance checks)
    mapping(address vault => mapping(address user => uint256)) public lockedSharesPerUser;

    /// @dev Mapping vault => token => total shares for a token in escrow (rebasing-safe accounting for concurrent locks).
    mapping(address vault => mapping(address token => uint256)) public totalSharesPerVault;

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
     * @dev Locks tokens for a cross-chain request
     * @param guid Unique request identifier
     * @param actionType Action type
     * @param actionCallData Action calldata
     * @param amountLimit Amount limit (for MINT/WITHDRAW)
     * @param initiator Request initiator
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
        if (info.initiator != address(0)) {
            revert RequestAlreadyExists();
        }

        info.initiator = initiator;
        info.actionType = actionType;

        if (actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            if (msg.value != 0) revert InvalidActionType();
            (uint256 assets,) = abi.decode(actionCallData, (uint256, address));
            address assetToken = _getUnderlyingToken(vault_);
            info.owner = initiator;

            // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;

            info.tokens.push(assetToken);
            // Default: strict mode (require exact assets). If enabled for this token, execute using actualReceived.
            if (actualReceived < assets) {
                if (!_isFeeOnTransferDepositAllowed(vault_, assetToken)) {
                    revert FeeOnTransferNotAllowed(assetToken);
                }
                info.requiredAmount[assetToken] = actualReceived;
                // Update request calldata to deposit actualReceived instead of requested assets
                (, address receiver) = abi.decode(actionCallData, (uint256, address));
                _updateRequestActionCallData(vault_, guid, abi.encode(actualReceived, receiver));
                emit DepositAmountAdjusted(guid, vault_, assetToken, assets, actualReceived);
            } else {
                info.requiredAmount[assetToken] = assets;
            }
            _mintEscrowShares(vault_, info, assetToken, actualReceived);

            emit TokensLocked(guid, vault_, assetToken, actualReceived, initiator);

        } else if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            _lockMultiAssetsDeposit(vault_, info, guid, actionCallData, initiator);

        } else if (actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            if (msg.value != 0) revert InvalidActionType();
            (, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));

            if (amountLimit == 0) {
                revert InvalidActionType();
            }
            uint256 shares = amountLimit;
            info.owner = owner;

            // Standard flow: owner approves escrow for share token (vault itself), then escrow pulls shares.
            IERC20(vault_).safeTransferFrom(owner, address(this), shares);

            // Shares are now held by escrow, but we track them as locked for accounting/fee logic.
            info.tokens.push(vault_); // vault address = share token address
            info.sharesOrAmount[vault_] = shares;
            info.requiredAmount[vault_] = shares;
            lockedSharesPerUser[vault_][owner] += shares;

            emit TokensLocked(guid, vault_, vault_, shares, owner);

        } else if (actionType == MoreVaultsLib.ActionType.REDEEM) {
            if (msg.value != 0) revert InvalidActionType();
            (uint256 shares, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));
            info.owner = owner;

            // Standard flow: owner approves escrow for share token (vault itself), then escrow pulls shares.
            IERC20(vault_).safeTransferFrom(owner, address(this), shares);

            info.tokens.push(vault_);
            info.sharesOrAmount[vault_] = shares;
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

            // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;

            // For MINT we require full `amountLimit` assets, otherwise mint(shares) will likely revert / break semantics.
            if (actualReceived < assets) {
                revert FeeOnTransferNotAllowed(assetToken);
            }

            info.tokens.push(assetToken);
            info.requiredAmount[assetToken] = assets;
            _mintEscrowShares(vault_, info, assetToken, actualReceived);

            emit TokensLocked(guid, vault_, assetToken, actualReceived, initiator);
        }
        // No locking is required for ACCRUE_FEES
    }

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

        (uint256[] memory effectiveAmounts, bool needsUpdate) =
            _lockMultiAssetsTokens(vault_, info, guid, tokens, amounts, initiator);

        if (value > 0) {
            info.nativeAmount = value;
            emit NativeLocked(guid, vault_, value);
        }
        info.owner = initiator;

        if (needsUpdate) {
            _updateRequestActionCallData(vault_, guid, abi.encode(tokens, effectiveAmounts, receiver, minAmountOut, value));
        }
    }

    function _lockMultiAssetsTokens(
        address vault_,
        EscrowInfo storage info,
        bytes32 guid,
        address[] memory tokens,
        uint256[] memory amounts,
        address initiator
    ) internal returns (uint256[] memory effectiveAmounts, bool needsUpdate) {
        effectiveAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 required, uint256 actualReceived, bool adjusted) =
                _lockOneMultiAssetToken(vault_, info, guid, tokens[i], amounts[i], initiator);
            effectiveAmounts[i] = required;
            if (adjusted) needsUpdate = true;
            emit TokensLocked(guid, vault_, tokens[i], actualReceived, initiator);
        }
    }

    function _lockOneMultiAssetToken(
        address vault_,
        EscrowInfo storage info,
        bytes32 guid,
        address token,
        uint256 amount,
        address initiator
    ) internal returns (uint256 required, uint256 actualReceived, bool adjusted) {
        // Validate token is whitelisted BEFORE transfer to prevent arbitrary code execution
        _validateAssetDepositable(vault_, token);

        // Push the token only once per request (MULTI_ASSETS_DEPOSIT can include duplicates).
        // We later approve the vault for the summed required amounts across all occurrences.
        if (info.requiredAmount[token] == 0 && info.sharesOrAmount[token] == 0) {
            info.tokens.push(token);
        }

        // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        actualReceived = balanceAfter - balanceBefore;

        required = amount;
        if (actualReceived < amount) {
            if (!_isFeeOnTransferDepositAllowed(vault_, token)) {
                revert FeeOnTransferNotAllowed(token);
            }
            required = actualReceived;
            adjusted = true;
            emit DepositAmountAdjusted(guid, vault_, token, amount, actualReceived);
        }
        info.requiredAmount[token] += required;
        _mintEscrowShares(vault_, info, token, actualReceived);
    }

    /**
     * @dev Transfers tokens from escrow to the vault for request execution
     * @param guid Unique request identifier
     * @return tokens Array of token addresses
     * @return amounts Array of token amounts to transfer
     * @return nativeAmount Native token amount
     */
    function releaseTokensForExecution(bytes32 guid)
        external
        onlyVault
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        tokens = info.tokens;
        amounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 required = info.requiredAmount[token];

            // Share-token (vault itself): shares are held by escrow until execution; transfer to vault now.
            if (token == vault_ && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                uint256 shares = required;
                if (shares > 0) {
                    amounts[i] = shares;
                    info.releasedAmount[token] = shares;
                }
            } else {
                // Compute claim from shares and release exactly `required` amount.
                uint256 claim = _sharesToAmount(vault_, token, info.sharesOrAmount[token]);
                if (claim < required) {
                    revert InsufficientTokensReceived();
                }

                uint256 sharesToRedeem = _amountToShares(vault_, token, required);
                // Burn this request's shares for `required` amount and decrease totalShares
                info.sharesOrAmount[token] -= sharesToRedeem;
                totalSharesPerVault[vault_][token] -= sharesToRedeem;

                // Do NOT transfer to the vault here.
                // Instead, approve the vault to pull `required` from escrow during the ERC4626 deposit/mint call.
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
     * @dev Unlocks and returns excess tokens after successful request execution
     * @param guid Unique request identifier
     * @param usedAmounts Array of used amounts (matches `tokens` returned by releaseTokensForExecution)
     */
    function unlockTokensAfterExecution(
        bytes32 guid,
        address[] memory tokens,
        uint256[] memory usedAmounts
    ) external onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        info.finalized = true;

        // Unlock tokens and return excess
        if (tokens.length != usedAmounts.length) revert ArraysLengthMismatch();
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 released = info.releasedAmount[token];
            uint256 usedAmount = usedAmounts[i];

            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault_ && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault_][info.owner] -= released;
            }

            // If less was used than was reserved for execution, return the excess from escrow.
            if (usedAmount < released) {
                uint256 excess = released - usedAmount;
                IERC20(token).safeTransfer(info.owner, excess);
                emit TokensUnlocked(guid, vault_, token, excess, info.owner);
            }

            // Refund remaining claim (positive rebases) for remaining shares, if any (ERC20 only).
            if (token != vault_) {
                uint256 remainingShares = info.sharesOrAmount[token];
                if (remainingShares > 0) {
                    uint256 refundAmount = _sharesToAmount(vault_, token, remainingShares);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault_][token] -= remainingShares;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(info.owner, refundAmount);
                        emit TokensUnlocked(guid, vault_, token, refundAmount, info.owner);
                    }
                }

                // Clear allowance after execution (defense-in-depth).
                IERC20(token).forceApprove(vault_, 0);
            }
        }
    }

    /**
     * @dev Refunds tokens on request cancellation/refund
     * @param guid Unique request identifier
     */
    function refundTokens(bytes32 guid) external onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized || info.refunded) {
            return; // Already processed
        }

        info.refunded = true;

        // Refund native token, if any
        if (info.nativeAmount > 0) {
            (bool success,) = info.initiator.call{value: info.nativeAmount}("");
            if (!success) revert NativeRefundFailed();
            emit NativeUnlocked(guid, vault_, info.nativeAmount, info.initiator);
        }

        // Refund all tokens
        address[] memory tokens = info.tokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault_ && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault_][info.owner] -= info.requiredAmount[token];
            }

            if (token == vault_) {
                uint256 shares = info.requiredAmount[token];
                if (shares > 0) {
                    // If shares were released to the vault, they must be returned to escrow beforehand (BridgeFacet).
                    IERC20(token).safeTransfer(info.owner, shares);
                    emit TokensUnlocked(guid, vault_, token, shares, info.owner);
                }
            } else {
                // Clear allowance on refund (defense-in-depth).
                IERC20(token).forceApprove(vault_, 0);

                uint256 sharesToRefund = info.sharesOrAmount[token];
                if (sharesToRefund > 0) {
                    uint256 refundAmount = _sharesToAmount(vault_, token, sharesToRefund);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault_][token] -= sharesToRefund;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(info.owner, refundAmount);
                        emit TokensUnlocked(guid, vault_, token, refundAmount, info.owner);
                    }
                }
            }
        }
    }

    /**
     * @dev Refunds tokens to the composer when refunding a stuck deposit
     * @param guid Unique request identifier
     * @param composer Composer address
     */
    function refundToComposer(bytes32 guid, address composer) external onlyVault nonReentrant {
        address vault_ = msg.sender;
        EscrowInfo storage info = escrowInfo[vault_][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized || info.refunded) {
            return;
        }

        info.refunded = true;

        // Refund native token to the composer
        if (info.nativeAmount > 0) {
            (bool success,) = composer.call{value: info.nativeAmount}("");
            if (!success) revert NativeTransferFailed();
            emit NativeUnlocked(guid, vault_, info.nativeAmount, composer);
        }

        // Refund all tokens to the composer
        address[] memory tokens = info.tokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault_ && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault_][info.owner] -= info.requiredAmount[token];
            }

            if (token == vault_) {
                uint256 shares = info.requiredAmount[token];
                if (shares > 0) {
                    // If shares were released to the vault, they must be returned to escrow beforehand (BridgeFacet).
                    IERC20(token).safeTransfer(composer, shares);
                    emit TokensUnlocked(guid, vault_, token, shares, composer);
                }
            } else {
                // Clear allowance on refund (defense-in-depth).
                IERC20(token).forceApprove(vault_, 0);

                uint256 sharesToRefund = info.sharesOrAmount[token];
                if (sharesToRefund > 0) {
                    uint256 refundAmount = _sharesToAmount(vault_, token, sharesToRefund);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault_][token] -= sharesToRefund;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(composer, refundAmount);
                        emit TokensUnlocked(guid, vault_, token, refundAmount, composer);
                    }
                }
            }
        }
    }

    /**
     * @dev Returns information about locked tokens for a request
     * @param guid Unique request identifier
     * @return tokens Array of token addresses
     * @return amounts Array of amounts
     * @return nativeAmount Native token amount
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
     * @param token Token address to validate
     * @notice Reverts if token is not whitelisted, preventing arbitrary code execution via transferFrom
     */
    function _validateAssetDepositable(address vault_, address token) internal view {
        if (!IVaultEscrowHooks(vault_).isAssetDepositable(token)) {
            revert TokenNotWhitelisted(token);
        }
    }

    function _isFeeOnTransferDepositAllowed(address vault_, address token) internal view returns (bool) {
        return IVaultEscrowHooks(vault_).isFeeOnTransferDepositAllowed(token);
    }

    function _updateRequestActionCallData(address vault_, bytes32 guid, bytes memory newActionCallData) internal {
        IVaultEscrowHooks(vault_).updateCrossChainRequestActionCallData(guid, newActionCallData);
    }

    /**
     * @dev Helper function to get the underlying token address
     * @return Underlying token address of the vault
     */
    function _getUnderlyingToken(address vault_) internal view returns (address) {
        return IERC4626(vault_).asset();
    }

    function _mintEscrowShares(address vault_, EscrowInfo storage info, address token, uint256 amountReceived) internal {
        // Share model: shares = amount * totalShares / balanceBefore.
        // balanceBefore can be reconstructed as (balanceNow - amountReceived) since this function is called
        // immediately after transferFrom.
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        uint256 balanceBefore = balanceNow - amountReceived;
        uint256 totalShares = totalSharesPerVault[vault_][token];
        uint256 shares;
        if (totalShares == 0 || balanceBefore == 0) {
            shares = amountReceived;
        } else {
            shares = (amountReceived * totalShares) / balanceBefore;
            if (shares == 0) {
                // minimum 1 share to avoid losing contribution due to rounding
                shares = 1;
            }
        }
        info.sharesOrAmount[token] += shares;
        totalSharesPerVault[vault_][token] += shares;
    }

    function _sharesToAmount(address vault_, address token, uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        uint256 totalShares = totalSharesPerVault[vault_][token];
        if (totalShares == 0) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        return (shares * balance) / totalShares;
    }

    function _amountToShares(address vault_, address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalShares = totalSharesPerVault[vault_][token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (totalShares == 0 || balance == 0) {
            return amount;
        }
        // round up to guarantee covering `amount`
        uint256 numerator = amount * totalShares;
        return (numerator + balance - 1) / balance;
    }

    receive() external payable {
        // Receive native token for MULTI_ASSETS_DEPOSIT
    }
}
