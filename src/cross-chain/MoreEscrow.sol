// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";

/**
 * @title MoreEscrow
 * @dev Escrow contract for holding locked tokens during cross-chain operations
 * @notice Simplifies BridgeFacet by moving management of locked funds into a dedicated contract
 * 
 * Benefits of using Escrow:
 * 1. Separation of concerns: BridgeFacet focuses on cross-chain logic, Escrow on token custody
 * 2. Simpler BridgeFacet: no need to track pendingTokens and lockedSharesPerUser in the vault's storage
 * 3. Cleaner architecture: all locked funds are held in one place
 * 4. Simpler accounting: the vault can query totalLockedPerVault[token] from the escrow
 * 
 * Usage:
 * - On request creation: BridgeFacet calls escrow.lockTokens() - tokens are transferred to escrow
 * - On request execution: BridgeFacet calls escrow.releaseTokensForExecution() - tokens are transferred to the vault
 * - After execution: BridgeFacet calls escrow.unlockTokensAfterExecution() - excess is returned to the user
 * - On refund: BridgeFacet calls escrow.refundTokens() - all tokens are returned to the user
 */
contract MoreEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyVault();
    error OnlyCrossChainAccountingManager();
    error RequestNotFound();
    error RequestAlreadyFinalized();
    error RequestAlreadyRefunded();
    error InvalidActionType();
    error TransferFailed();
    error InsufficientTokensReceived();
    error EscrowNotSet();
    error TokenNotWhitelisted(address token);

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
        // How much was actually released to the vault for execution (absolute amounts).
        mapping(address token => uint256) releasedAmount;
        // How much needs to be released to the vault for execution (absolute amounts).
        mapping(address token => uint256) requiredAmount;
        // Native token (for MULTI_ASSETS_DEPOSIT)
        uint256 nativeAmount;
    }

    /// @dev Mapping vault => token => total amount locked INSIDE the vault (to exclude from accounting)
    mapping(address vault => mapping(address token => uint256)) public totalLockedPerVault;

    /// @dev Mapping vault => user => locked shares (for balance checks)
    mapping(address vault => mapping(address user => uint256)) public lockedSharesPerUser;

    /// @dev Mapping vault => token => total shares for a token in escrow.
    /// @notice Used ONLY for ERC20 that remain inside escrow until release.
    mapping(address vault => mapping(address token => uint256)) public totalSharesPerVault;

    /// @dev Vault contract address allowed to call locking methods
    address public immutable vault;

    /// @dev Cross-chain accounting manager address allowed to call unlocking methods
    address public crossChainAccountingManager;

    modifier onlyVault() {
        if (msg.sender != vault) {
            revert OnlyVault();
        }
        _;
    }

    modifier onlyCrossChainAccountingManager() {
        if (msg.sender != crossChainAccountingManager) {
            revert OnlyCrossChainAccountingManager();
        }
        _;
    }

    constructor(address _vault) {
        vault = _vault;
    }

    /**
     * @dev Sets the cross-chain accounting manager address
     * @param _manager Manager address
     */
    function setCrossChainAccountingManager(address _manager) external {
        // Access control checks can be added here if needed
        crossChainAccountingManager = _manager;
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
    ) external onlyVault nonReentrant {
        EscrowInfo storage info = escrowInfo[vault][guid];
        if (info.initiator != address(0)) {
            revert RequestNotFound(); // Already exists
        }

        info.initiator = initiator;
        info.actionType = actionType;

        if (actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets,) = abi.decode(actionCallData, (uint256, address));
            address assetToken = _getUnderlyingToken();
            info.owner = initiator;

            // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;
            
            // DEPOSIT requires exact `assets` for execution, so we don't allow under-receipt.
            if (actualReceived < assets) {
                revert InsufficientTokensReceived();
            }

            info.tokens.push(assetToken);
            info.requiredAmount[assetToken] = assets;
            _mintEscrowShares(info, assetToken, actualReceived);

            emit TokensLocked(guid, vault, assetToken, actualReceived, initiator);

        } else if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory amounts,,, uint256 value) =
                abi.decode(actionCallData, (address[], uint256[], address, uint256, uint256));

            for (uint256 i = 0; i < tokens.length; i++) {
                // Validate token is whitelisted BEFORE transfer to prevent arbitrary code execution
                _validateAssetDepositable(tokens[i]);
                // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
                uint256 balanceBefore = IERC20(tokens[i]).balanceOf(address(this));
                IERC20(tokens[i]).safeTransferFrom(initiator, address(this), amounts[i]);
                uint256 balanceAfter = IERC20(tokens[i]).balanceOf(address(this));
                uint256 actualReceived = balanceAfter - balanceBefore;
                
                // MULTI_ASSETS_DEPOSIT requires exact amounts[i] for execution.
                if (actualReceived < amounts[i]) {
                    revert InsufficientTokensReceived();
                }

                info.tokens.push(tokens[i]);
                info.requiredAmount[tokens[i]] = amounts[i];
                _mintEscrowShares(info, tokens[i], actualReceived);

                emit TokensLocked(guid, vault, tokens[i], actualReceived, initiator);
            }

            if (value > 0) {
                info.nativeAmount = value;
                emit NativeLocked(guid, vault, value);
            }
            info.owner = initiator;

        } else if (actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));

            if (amountLimit == 0) {
                revert InvalidActionType();
            }
            uint256 shares = amountLimit;
            info.owner = owner;

            // Transfer shares from owner via the vault (using initiator's allowance from owner)
            (bool success, bytes memory returnData) = vault.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transferSharesFromOwner(address,uint256,address)")),
                    owner,
                    shares,
                    initiator
                )
            );
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                revert TransferFailed();
            }

            // Shares are now in the vault, but we track them as locked
            info.tokens.push(vault); // vault address = share token address
            info.sharesOrAmount[vault] = shares;
            info.requiredAmount[vault] = shares;
            // Locked shares are held in the vault, so we immediately exclude them from accounting.
            totalLockedPerVault[vault][vault] += shares;
            lockedSharesPerUser[vault][owner] += shares;

            emit TokensLocked(guid, vault, vault, shares, owner);

        } else if (actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, , address owner) =
                abi.decode(actionCallData, (uint256, address, address));
            info.owner = owner;

            // Transfer shares from owner via the vault
            (bool success, bytes memory returnData) = vault.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transferSharesFromOwner(address,uint256,address)")),
                    owner,
                    shares,
                    initiator
                )
            );
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                revert TransferFailed();
            }

            info.tokens.push(vault);
            info.sharesOrAmount[vault] = shares;
            info.requiredAmount[vault] = shares;
            // Locked shares are held in the vault, so we immediately exclude them from accounting.
            totalLockedPerVault[vault][vault] += shares;
            lockedSharesPerUser[vault][owner] += shares;

            emit TokensLocked(guid, vault, vault, shares, owner);

        } else if (actionType == MoreVaultsLib.ActionType.MINT) {
            abi.decode(actionCallData, (uint256, address)); // shares, receiver - unused

            if (amountLimit == 0) {
                revert InvalidActionType();
            }
            uint256 assets = amountLimit;
            address assetToken = _getUnderlyingToken();
            info.owner = initiator;

            // Fee-on-transfer/rebasing: use balanceBefore/After to get the actual received amount
            uint256 balanceBefore = IERC20(assetToken).balanceOf(address(this));
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
            uint256 balanceAfter = IERC20(assetToken).balanceOf(address(this));
            uint256 actualReceived = balanceAfter - balanceBefore;
            
            // In the current flow, MINT requires max assets to be available for safe execution.
            if (actualReceived < assets) {
                revert InsufficientTokensReceived();
            }

            info.tokens.push(assetToken);
            info.requiredAmount[assetToken] = assets;
            _mintEscrowShares(info, assetToken, actualReceived);

            emit TokensLocked(guid, vault, assetToken, actualReceived, initiator);
        }
        // No locking is required for ACCRUE_FEES
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
        onlyCrossChainAccountingManager
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        EscrowInfo storage info = escrowInfo[vault][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        tokens = info.tokens;
        amounts = new uint256[](tokens.length);
        
        // Transfer tokens to the vault (for WITHDRAW/REDEEM shares are already in the vault, so nothing to transfer)
        bool isWithdrawOrRedeem = info.actionType == MoreVaultsLib.ActionType.WITHDRAW
            || info.actionType == MoreVaultsLib.ActionType.REDEEM;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 required = info.requiredAmount[token];
            
            // For WITHDRAW/REDEEM shares are already in the vault (transferred in lockTokens)
            if (!isWithdrawOrRedeem || token != vault) {
                // Compute claim from shares and release exactly `required` amount.
                uint256 claim = _sharesToAmount(token, info.sharesOrAmount[token]);
                if (claim < required) {
                    revert InsufficientTokensReceived();
                }

                uint256 sharesToRedeem = _amountToShares(token, required);
                // Burn this request's shares for `required` amount and decrease totalShares
                info.sharesOrAmount[token] -= sharesToRedeem;
                totalSharesPerVault[vault][token] -= sharesToRedeem;

                IERC20(token).safeTransfer(vault, required);
                amounts[i] = required;
                info.releasedAmount[token] = required;
                // Locked amount is now held inside the vault; exclude it from accounting
                totalLockedPerVault[vault][token] += required;
            } else {
                // For WITHDRAW/REDEEM use the stored amount (shares); no transfer required
                amounts[i] = required;
                info.releasedAmount[token] = required;
            }
        }

        nativeAmount = info.nativeAmount;
        if (nativeAmount > 0) {
            (bool success,) = vault.call{value: nativeAmount}("");
            require(success, "Native transfer failed");
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
    ) external onlyCrossChainAccountingManager nonReentrant {
        EscrowInfo storage info = escrowInfo[vault][guid];
        if (info.initiator == address(0)) {
            revert RequestNotFound();
        }
        if (info.finalized) {
            revert RequestAlreadyFinalized();
        }

        info.finalized = true;

        // Unlock tokens and return excess
        require(tokens.length == usedAmounts.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 released = info.releasedAmount[token];
            uint256 usedAmount = usedAmounts[i];

            // Update total locked amounts (use released amount since it was held in the vault)
            if (released > 0) {
                totalLockedPerVault[vault][token] -= released;
            }

            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault][info.owner] -= released;
            }

            // If less was used than was released to the vault, return the excess.
            // IMPORTANT: the excess must be transferred back from the vault to escrow beforehand (BridgeFacet),
            // otherwise escrow won't be able to send it to the owner.
            if (usedAmount < released) {
                uint256 excess = released - usedAmount;
                if (token == vault) {
                    // Return excess shares: call the vault to transfer shares from the vault balance to the owner
                    _transferSharesFromVault(info.owner, excess);
                    emit TokensUnlocked(guid, vault, token, excess, info.owner);
                } else {
                    IERC20(token).safeTransfer(info.owner, excess);
                    emit TokensUnlocked(guid, vault, token, excess, info.owner);
                }
            }

            // Refund remaining claim (positive rebases) for remaining shares, if any (ERC20 only).
            if (token != vault) {
                uint256 remainingShares = info.sharesOrAmount[token];
                if (remainingShares > 0) {
                    uint256 refundAmount = _sharesToAmount(token, remainingShares);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault][token] -= remainingShares;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(info.owner, refundAmount);
                        emit TokensUnlocked(guid, vault, token, refundAmount, info.owner);
                    }
                }
            }
        }

        // Unlock native token, if any
        if (info.nativeAmount > 0) {
            // Native token was already used in MULTI_ASSETS_DEPOSIT
            totalLockedPerVault[vault][address(0)] -= info.nativeAmount;
        }
    }

    /**
     * @dev Refunds tokens on request cancellation/refund
     * @param guid Unique request identifier
     */
    function refundTokens(bytes32 guid) external onlyCrossChainAccountingManager nonReentrant {
        EscrowInfo storage info = escrowInfo[vault][guid];
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
            if (!success && crossChainAccountingManager != address(0)) {
                // If refund fails, send to the manager
                (bool managerSuccess,) = crossChainAccountingManager.call{value: info.nativeAmount}("");
                require(managerSuccess, "Native refund failed");
            }
            totalLockedPerVault[vault][address(0)] -= info.nativeAmount;
            emit NativeUnlocked(guid, vault, info.nativeAmount, info.initiator);
        }

        // Refund all tokens
        address[] memory tokens = info.tokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 released = info.releasedAmount[token];
            if (released > 0) {
                totalLockedPerVault[vault][token] -= released;
            }

            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault][info.owner] -= info.requiredAmount[token];
            }

            if (token == vault) {
                uint256 shares = info.requiredAmount[token];
                if (shares > 0) {
                    _transferSharesFromVault(info.owner, shares);
                    emit TokensUnlocked(guid, vault, token, shares, info.owner);
                }
            } else {
                uint256 sharesToRefund = info.sharesOrAmount[token];
                if (sharesToRefund > 0) {
                    uint256 refundAmount = _sharesToAmount(token, sharesToRefund);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault][token] -= sharesToRefund;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(info.owner, refundAmount);
                        emit TokensUnlocked(guid, vault, token, refundAmount, info.owner);
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
    function refundToComposer(bytes32 guid, address composer) external onlyCrossChainAccountingManager nonReentrant {
        EscrowInfo storage info = escrowInfo[vault][guid];
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
            require(success, "Native transfer failed");
            totalLockedPerVault[vault][address(0)] -= info.nativeAmount;
            emit NativeUnlocked(guid, vault, info.nativeAmount, composer);
        }

        // Refund all tokens to the composer
        address[] memory tokens = info.tokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 released = info.releasedAmount[token];
            if (released > 0) {
                totalLockedPerVault[vault][token] -= released;
            }

            if (token == vault && (info.actionType == MoreVaultsLib.ActionType.WITHDRAW
                || info.actionType == MoreVaultsLib.ActionType.REDEEM)) {
                lockedSharesPerUser[vault][info.owner] -= info.requiredAmount[token];
            }

            if (token == vault) {
                uint256 shares = info.requiredAmount[token];
                if (shares > 0) {
                    _transferSharesFromVault(composer, shares);
                    emit TokensUnlocked(guid, vault, token, shares, composer);
                }
            } else {
                uint256 sharesToRefund = info.sharesOrAmount[token];
                if (sharesToRefund > 0) {
                    uint256 refundAmount = _sharesToAmount(token, sharesToRefund);
                    info.sharesOrAmount[token] = 0;
                    totalSharesPerVault[vault][token] -= sharesToRefund;
                    if (refundAmount > 0) {
                        IERC20(token).safeTransfer(composer, refundAmount);
                        emit TokensUnlocked(guid, vault, token, refundAmount, composer);
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
    function getEscrowInfo(bytes32 guid)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        EscrowInfo storage info = escrowInfo[vault][guid];
        tokens = info.tokens;
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            // For compatibility, return required amount (what is planned to be released to the vault for execution)
            amounts[i] = info.requiredAmount[tokens[i]];
        }
        nativeAmount = info.nativeAmount;
    }

    /**
     * @dev Returns total locked amount of a token for the vault
     * @param token Token address
     * @return Total locked amount
     */
    function getTotalLocked(address token) external view returns (uint256) {
        return totalLockedPerVault[vault][token];
    }

    /**
     * @dev Returns user's locked shares
     * @param user User address
     * @return Locked shares
     */
    function getLockedShares(address user) external view returns (uint256) {
        return lockedSharesPerUser[vault][user];
    }

    /**
     * @dev Validates that a token is whitelisted for deposit in the vault
     * @param token Token address to validate
     * @notice Reverts if token is not whitelisted, preventing arbitrary code execution via transferFrom
     */
    function _validateAssetDepositable(address token) internal view {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("isAssetDepositable(address)")), token)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TokenNotWhitelisted(token);
        }
    }

    /**
     * @dev Helper function to get the underlying token address
     * @return Underlying token address of the vault
     */
    function _getUnderlyingToken() internal view returns (address) {
        // Call the vault to get the underlying token address
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("asset()")))
        );
        require(success, "Failed to get asset");
        return abi.decode(data, (address));
    }

    function _mintEscrowShares(EscrowInfo storage info, address token, uint256 amountReceived) internal {
        // Share model: shares = amount * totalShares / balanceBefore.
        // balanceBefore can be reconstructed as (balanceNow - amountReceived) since this function is called
        // immediately after transferFrom.
        uint256 balanceNow = IERC20(token).balanceOf(address(this));
        uint256 balanceBefore = balanceNow - amountReceived;
        uint256 totalShares = totalSharesPerVault[vault][token];
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
        totalSharesPerVault[vault][token] += shares;
    }

    function _sharesToAmount(address token, uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        uint256 totalShares = totalSharesPerVault[vault][token];
        if (totalShares == 0) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        return (shares * balance) / totalShares;
    }

    function _amountToShares(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalShares = totalSharesPerVault[vault][token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (totalShares == 0 || balance == 0) {
            return amount;
        }
        // round up to guarantee covering `amount`
        uint256 numerator = amount * totalShares;
        return (numerator + balance - 1) / balance;
    }

    function _transferSharesFromVault(address to, uint256 shares) internal {
        (bool success, bytes memory returnData) = vault.call(
            abi.encodeWithSelector(bytes4(keccak256("transferSharesFromVault(address,uint256)")), to, shares)
        );
        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
            revert TransferFailed();
        }
    }

    receive() external payable {
        // Receive native token for MULTI_ASSETS_DEPOSIT
    }
}
