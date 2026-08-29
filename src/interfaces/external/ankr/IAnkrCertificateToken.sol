// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title IAnkrCertificateToken
 * @notice Minimal interface for Ankr certificate (ankrFLOW) token
 * @dev Mainnet: 0x1b97100eA1D7126C4d60027e231EA4CB25314bdb
 */
interface IAnkrCertificateToken is IERC20 {
    function sharesToBonds(uint256 shares) external view returns (uint256);

    function bondsToShares(uint256 bonds) external view returns (uint256);

    function ratio() external view returns (uint256);
}
