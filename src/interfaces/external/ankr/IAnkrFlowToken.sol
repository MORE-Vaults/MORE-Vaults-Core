// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IAnkrFlowToken
 * @notice Subset of the ankrFLOW ERC20 used by the adapter for unit conversion.
 *
 * Mainnet (chainId 747): 0x1b97100eA1D7126C4d60027e231EA4CB25314bdb
 *
 * ankrFLOW is a "cert" (price-appreciating) LST: balance stays constant per
 * holder while the ratio against native FLOW grows with accrued rewards.
 * The conversion is therefore done via `sharesToBonds` / `bondsToShares`
 * rather than a rebase.
 */
interface IAnkrFlowToken {
    /// @notice Convert an ankrFLOW (shares) amount to the equivalent native FLOW (bonds).
    function sharesToBonds(uint256 shares) external view returns (uint256);

    /// @notice Convert a native FLOW (bonds) amount to the equivalent ankrFLOW (shares).
    function bondsToShares(uint256 bonds) external view returns (uint256);

    /// @notice Current ratio (1e18-scaled). FLOW = shares * 1e18 / ratio().
    function ratio() external view returns (uint256);

    /// @notice Always false for the cert token (true only for the bond/rebasing variant).
    function isRebasing() external pure returns (bool);
}
