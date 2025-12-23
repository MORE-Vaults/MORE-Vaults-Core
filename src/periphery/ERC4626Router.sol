// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";

/// @title ERC4626Router
/// @notice Adds slippage protection to ERC-4626 vault operations
/// @dev This router is incompatible with vaults that have deposit whitelist or withdrawal queue enabled.
///      When whitelist is enabled, the router becomes msg.sender instead of the actual user, failing whitelist checks.
///      When withdrawal queue is enabled, all users would share a single withdrawal request slot under the router's address.
///      For permissioned vaults, users must interact directly with the vault.
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
        if (_isDepositWhitelistEnabled(address(vault))) revert DepositWhitelistEnabled();

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
        if (_isDepositWhitelistEnabled(address(vault))) revert DepositWhitelistEnabled();

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

    function requestWithdraw(IERC4626 vault, uint256 assets, address owner) external
    {
        if (IERC20(address(vault)).allowance(owner, address(this)) < IERC4626(address(vault)).convertToShares(assets)) {
            revert ERC20InsufficientAllowance(owner, IERC20(address(vault)).allowance(owner, address(this)), IERC4626(address(vault)).convertToShares(assets));
        }
        IVaultFacet(address(vault)).requestWithdraw(assets, owner);
    }

    function requestRedeem(IERC4626 vault, uint256 shares, address owner) external
    {
        if (IERC20(address(vault)).allowance(owner, address(this)) < shares) {
            revert ERC20InsufficientAllowance(owner, IERC20(address(vault)).allowance(owner, address(this)), IERC4626(address(vault)).convertToAssets(shares));
        }
        IVaultFacet(address(vault)).requestRedeem(shares, owner);
    }

    function withdrawWithSlippage(IERC4626 vault, uint256 assets, uint256 maxShares, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        if (_isWithdrawalQueueEnabled(address(vault))) revert WithdrawalQueueEnabled();
        shares = vault.withdraw(assets, receiver, owner);

        if (shares > maxShares) revert SlippageExceeded(shares, maxShares);
    }

    function redeemWithSlippage(IERC4626 vault, uint256 shares, uint256 minAssets, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        if (_isWithdrawalQueueEnabled(address(vault))) revert WithdrawalQueueEnabled();
        assets = vault.redeem(shares, receiver, owner);

        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
    }

    function _isDepositWhitelistEnabled(address vault) internal view returns (bool) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("isDepositWhitelistEnabled()")
        );
        if (!success || data.length == 0) return false;
        return abi.decode(data, (bool));
    }

    function _isWithdrawalQueueEnabled(address vault) internal view returns (bool) {
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature("getWithdrawalQueueStatus()")
        );
        if (!success || data.length == 0) return false;
        return abi.decode(data, (bool));
    }
}
