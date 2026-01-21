// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IMoreVaultsEscrow} from "../../src/interfaces/IMoreVaultsEscrow.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockMoreVaultsEscrow is IMoreVaultsEscrow {
    using SafeERC20 for IERC20;

    error OwnerMustBeInitiator();

    struct EscrowData {
        address[] tokens;
        uint256[] amounts;
        uint256 nativeAmount;
        bool finalized;
        bool refunded;
        address initiator;
        address owner;
        // Track released amounts for each token (index matches tokens array)
        mapping(uint256 => uint256) releasedAmounts;
    }

    mapping(address vault => mapping(bytes32 guid => EscrowData)) public escrowData;
    mapping(address vault => mapping(address user => uint256)) public lockedSharesPerUser;

    function lockTokens(
        bytes32 guid,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        uint256 amountLimit,
        address initiator
    ) external payable {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        
        data.initiator = initiator;
        
        if (actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets,) = abi.decode(actionCallData, (uint256, address));
            address assetToken = _getUnderlyingToken(vault);
            data.tokens.push(assetToken);
            data.amounts.push(assets);
            data.owner = initiator;
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
        } else if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory amounts,,, uint256 value) =
                abi.decode(actionCallData, (address[], uint256[], address, uint256, uint256));
            data.tokens = tokens;
            data.amounts = amounts;
            data.nativeAmount = value;
            data.owner = initiator;
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] != address(0)) {
                    IERC20(tokens[i]).safeTransferFrom(initiator, address(this), amounts[i]);
                }
            }
        } else if (actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (, , address owner) = abi.decode(actionCallData, (uint256, address, address));
            if (owner != initiator) revert OwnerMustBeInitiator();
            uint256 shares = amountLimit;
            data.tokens.push(vault);
            data.amounts.push(shares);
            data.owner = owner;
            lockedSharesPerUser[vault][owner] += shares;
            IERC20(vault).safeTransferFrom(owner, address(this), shares);
        } else if (actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, , address owner) = abi.decode(actionCallData, (uint256, address, address));
            if (owner != initiator) revert OwnerMustBeInitiator();
            data.tokens.push(vault);
            data.amounts.push(shares);
            data.owner = owner;
            lockedSharesPerUser[vault][owner] += shares;
            IERC20(vault).safeTransferFrom(owner, address(this), shares);
        } else if (actionType == MoreVaultsLib.ActionType.MINT) {
            address assetToken = _getUnderlyingToken(vault);
            uint256 assets = amountLimit;
            data.tokens.push(assetToken);
            data.amounts.push(assets);
            data.owner = initiator;
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);
        }
    }

    function releaseTokensForExecution(bytes32 guid)
        external
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        tokens = data.tokens;
        amounts = new uint256[](tokens.length);
        nativeAmount = data.nativeAmount;
        
        // For shares (WITHDRAW/REDEEM), approve vault to pull (shares stay in escrow)
        // For ERC20 tokens (DEPOSIT/MINT), approve vault to pull
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = data.amounts[i];
            // Track released amount
            data.releasedAmounts[i] = amounts[i];
            // Approve vault to pull tokens/shares (for both ERC20 and shares)
            IERC20(tokens[i]).forceApprove(vault, amounts[i]);
        }
        
        // Transfer native if needed
        if (nativeAmount > 0) {
            (bool success,) = vault.call{value: nativeAmount}("");
            require(success, "Native transfer failed");
        }
    }

    function unlockTokensAfterExecution(
        bytes32 guid,
        address[] memory tokens,
        uint256[] memory usedAmounts
    ) external {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        data.finalized = true;
        
        // Find token index in escrow data
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 usedAmount = usedAmounts[i];
            
            // Find matching token in escrow data
            uint256 escrowIndex = type(uint256).max;
            for (uint256 j = 0; j < data.tokens.length; j++) {
                if (data.tokens[j] == token) {
                    escrowIndex = j;
                    break;
                }
            }
            
            if (escrowIndex == type(uint256).max) continue;
            
            uint256 released = data.releasedAmounts[escrowIndex];
            
            // For WITHDRAW/REDEEM update lockedSharesPerUser
            if (token == vault) {
                if (data.owner != address(0) && lockedSharesPerUser[vault][data.owner] >= released) {
                    lockedSharesPerUser[vault][data.owner] -= released;
                }
            }
            
            // Refund remaining tokens, if any (ERC20 only).
            if (token != vault) {
                // If less was used than was released, return the excess from escrow.
                if (usedAmount < released) {
                    uint256 excess = released - usedAmount;
                    IERC20(token).safeTransfer(data.owner, excess);
                }

                // Refund any remaining locked tokens that weren't released
                uint256 totalLocked = data.amounts[escrowIndex];
                if (totalLocked > released) {
                    uint256 remainingAmount = totalLocked - released;
                    data.amounts[escrowIndex] = 0;
                    IERC20(token).safeTransfer(data.owner, remainingAmount);
                } else {
                    // Clear the amount if all was released
                    data.amounts[escrowIndex] = 0;
                }

                // Clear allowance after execution (defense-in-depth)
                IERC20(token).forceApprove(vault, 0);
            }
        }
    }

    function refundTokens(bytes32 guid) external {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        require(!data.refunded, "Already refunded");
        data.refunded = true;
        
        // Refund tokens
        for (uint256 i = 0; i < data.tokens.length; i++) {
            if (data.tokens[i] == vault) {
                // For shares, unlock locked shares and return to owner
                uint256 shares = data.amounts[i];
                if (data.owner != address(0) && lockedSharesPerUser[vault][data.owner] >= shares) {
                    lockedSharesPerUser[vault][data.owner] -= shares;
                }
                IERC20(vault).safeTransfer(data.owner, shares);
            } else {
                // Refund tokens to owner/initiator
                address recipient = data.owner != address(0) ? data.owner : data.initiator;
                IERC20(data.tokens[i]).safeTransfer(recipient, data.amounts[i]);
            }
        }
        
        // Refund native - try owner first, fallback to manager if owner rejects
        if (data.nativeAmount > 0) {
            address recipient = data.owner != address(0) ? data.owner : data.initiator;
            (bool success,) = recipient.call{value: data.nativeAmount}("");
            if (!success) {
                // If owner can't receive native token, redirect to cross-chain accounting manager
                address manager = IConfigurationFacet(vault).getCrossChainAccountingManager();
                if (manager == address(0)) {
                    revert("Native refund failed");
                }
                (success,) = payable(manager).call{value: data.nativeAmount}("");
                if (!success) {
                    revert("Native refund failed");
                }
            }
        }
    }

    function refundToComposer(bytes32 guid, address composer) external {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        require(!data.refunded, "Already refunded");
        data.refunded = true;
        
        // Refund tokens to composer
        for (uint256 i = 0; i < data.tokens.length; i++) {
            if (data.tokens[i] != address(0)) {
                IERC20(data.tokens[i]).safeTransfer(composer, data.amounts[i]);
            }
        }
        
        // Refund native to composer
        if (data.nativeAmount > 0) {
            (bool success,) = composer.call{value: data.nativeAmount}("");
            require(success, "Native refund failed");
        }
    }

    function getEscrowInfo(bytes32 guid)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, uint256 nativeAmount)
    {
        address vault = msg.sender;
        EscrowData storage data = escrowData[vault][guid];
        return (data.tokens, data.amounts, data.nativeAmount);
    }

    function getLockedShares(address vault, address user) external view returns (uint256) {
        return lockedSharesPerUser[vault][user];
    }

    // Helper function for tests to set underlying token
    mapping(address => address) public vaultToUnderlyingToken;
    
    function setUnderlyingToken(address vault, address token) external {
        vaultToUnderlyingToken[vault] = token;
    }

    function _getUnderlyingToken(address vault) internal view returns (address) {
        address token = vaultToUnderlyingToken[vault];
        require(token != address(0), "Underlying token not set");
        return token;
    }

    // Allow receiving native tokens
    receive() external payable {
        // Receive native token for MULTI_ASSETS_DEPOSIT
    }
}
