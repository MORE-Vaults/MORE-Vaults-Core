// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";

/// @title ERC4626Router
/// @notice Adds slippage protection to ERC-4626 vault operations
/// @dev All operations (deposits, withdrawals, requests) are executed on behalf of msg.sender.
///      This means that vault shares and assets are credited/debited to/from msg.sender's address,
///      not the router contract. The router supports vaults with deposit whitelist and withdrawal queue enabled.
contract ERC4626Router {
    using SafeERC20 for IERC20;

    error SlippageExceeded(uint256 actual, uint256 limit);
    error DepositWhitelistEnabled();
    error WithdrawalQueueEnabled();
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error MaxDepositExceeded(uint256 assets, uint256 max);
    error MaxMintExceeded(uint256 shares, uint256 max);

    function depositWithSlippage(IERC4626 vault, uint256 assets, uint256 minShares)
        external
        returns (uint256 shares)
    {
        IERC20 asset = IERC20(vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(vault), assets);

        uint256 maxDeposit = vault.maxDeposit(msg.sender);
        if (assets > maxDeposit) revert MaxDepositExceeded(assets, maxDeposit);
        shares = vault.deposit(assets, msg.sender);

        if (shares < minShares) revert SlippageExceeded(shares, minShares);
    }

    function mintWithSlippage(IERC4626 vault, uint256 shares, uint256 maxAssets)
        external
        returns (uint256 assets)
    {
        IERC20 asset = IERC20(vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), maxAssets);
        asset.forceApprove(address(vault), maxAssets);

        uint256 maxMint = vault.maxMint(msg.sender);
        if (shares > maxMint) revert MaxMintExceeded(shares, maxMint);
        assets = vault.mint(shares, msg.sender);

        if (assets > maxAssets) revert SlippageExceeded(assets, maxAssets);

        uint256 refund = maxAssets - assets;
        if (refund > 0) asset.safeTransfer(msg.sender, refund);
    }

    function requestWithdraw(IERC4626 vault, uint256 assets) external
    {
        if (IERC20(address(vault)).allowance(msg.sender, address(this)) < IERC4626(address(vault)).convertToShares(assets)) {
            revert ERC20InsufficientAllowance(msg.sender, IERC20(address(vault)).allowance(msg.sender, address(this)), IERC4626(address(vault)).convertToShares(assets));
        }
        IVaultFacet(address(vault)).requestWithdraw(assets, msg.sender);
    }

    function requestRedeem(IERC4626 vault, uint256 shares) external
    {
        if (IERC20(address(vault)).allowance(msg.sender, address(this)) < shares) {
            revert ERC20InsufficientAllowance(msg.sender, IERC20(address(vault)).allowance(msg.sender, address(this)), IERC4626(address(vault)).convertToAssets(shares));
        }
        IVaultFacet(address(vault)).requestRedeem(shares, msg.sender);
    }

    function withdrawWithSlippage(IERC4626 vault, uint256 assets, uint256 maxShares, address receiver)
        external
        returns (uint256 shares)
    {
        if (IERC20(address(vault)).allowance(msg.sender, address(this)) < IERC4626(address(vault)).convertToShares(assets)) {
            revert ERC20InsufficientAllowance(msg.sender, IERC20(address(vault)).allowance(msg.sender, address(this)), IERC4626(address(vault)).convertToShares(assets));
        }
        shares = vault.withdraw(assets, receiver, msg.sender);

        if (shares > maxShares) revert SlippageExceeded(shares, maxShares);
    }

    function redeemWithSlippage(IERC4626 vault, uint256 shares, uint256 minAssets, address receiver)
        external
        returns (uint256 assets)
    {
        if (IERC20(address(vault)).allowance(msg.sender, address(this)) < shares) {
            revert ERC20InsufficientAllowance(msg.sender, IERC20(address(vault)).allowance(msg.sender, address(this)), IERC4626(address(vault)).convertToAssets(shares));
        }
        assets = vault.redeem(shares, receiver, msg.sender);

        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
    }
}
