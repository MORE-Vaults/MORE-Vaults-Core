// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ERC4626Router
/// @notice Adds slippage protection to ERC-4626 vault operations
contract ERC4626Router {
    using SafeERC20 for IERC20;

    error SlippageExceeded(uint256 actual, uint256 limit);

    function depositWithSlippage(IERC4626 vault, uint256 assets, uint256 minShares, address receiver)
        external
        returns (uint256 shares)
    {
        IERC20 asset = IERC20(vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(vault), assets);

        shares = vault.deposit(assets, receiver);

        if (shares < minShares) revert SlippageExceeded(shares, minShares);
    }

    function mintWithSlippage(IERC4626 vault, uint256 shares, uint256 maxAssets, address receiver)
        external
        returns (uint256 assets)
    {
        IERC20 asset = IERC20(vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), maxAssets);
        asset.forceApprove(address(vault), maxAssets);

        assets = vault.mint(shares, receiver);

        if (assets > maxAssets) revert SlippageExceeded(assets, maxAssets);

        uint256 refund = maxAssets - assets;
        if (refund > 0) asset.safeTransfer(msg.sender, refund);
    }

    function withdrawWithSlippage(IERC4626 vault, uint256 assets, uint256 maxShares, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        IERC20(address(vault)).safeTransferFrom(owner, address(this), maxShares);

        shares = vault.withdraw(assets, receiver, address(this));

        if (shares > maxShares) revert SlippageExceeded(shares, maxShares);

        uint256 refund = maxShares - shares;
        if (refund > 0) IERC20(address(vault)).safeTransfer(owner, refund);
    }

    function redeemWithSlippage(IERC4626 vault, uint256 shares, uint256 minAssets, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        IERC20(address(vault)).safeTransferFrom(owner, address(this), shares);

        assets = vault.redeem(shares, receiver, address(this));

        if (assets < minAssets) revert SlippageExceeded(assets, minAssets);
    }
}
