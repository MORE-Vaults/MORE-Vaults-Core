// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

interface IAaveV3Facet is IGenericMoreVaultFacetInitializable {
    error UnsupportedAsset(address);
    error UnsupportedPool(address);

    function facetName() external pure returns (string memory);

    function accountingAaveV3Facet()
        external
        view
        returns (uint256 sum, bool isPositive);

    /**
     * @notice Supplies an asset to a pool
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param amount The amount of the asset to supply
     * @param referralCode The referral code
     */
    function supply(
        address pool,
        address asset,
        uint256 amount,
        uint16 referralCode
    ) external;

    /**
     * @notice Withdraws an asset from a pool
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param amount The amount of the asset to withdraw
     * @return withdrawnAmount The amount of the asset withdrawn
     */
    function withdraw(
        address pool,
        address asset,
        uint256 amount
    ) external returns (uint256 withdrawnAmount);

    /**
     * @notice Borrows an asset from a pool
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param amount The amount of the asset to borrow
     * @param interestRateMode The interest rate mode
     * @param referralCode The referral code
     */
    function borrow(
        address pool,
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /**
     * @notice Repays an asset from a pool
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param amount The amount of the asset to repay
     * @param interestRateMode The interest rate mode
     * @return repaidAmount The amount of the asset repaid
     */
    function repay(
        address pool,
        address asset,
        uint256 amount,
        uint256 interestRateMode
    ) external returns (uint256 repaidAmount);

    /**
     * @notice Repays an asset from a pool with aTokens
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param amount The amount of the asset to repay
     * @param interestRateMode The interest rate mode
     * @return repaidAmount The amount of the asset repaid
     */
    function repayWithATokens(
        address pool,
        address asset,
        uint256 amount,
        uint256 interestRateMode
    ) external returns (uint256 repaidAmount);

    /**
     * @notice Swaps the borrow rate mode of an asset
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param interestRateMode The interest rate mode
     */
    function swapBorrowRateMode(
        address pool,
        address asset,
        uint256 interestRateMode
    ) external;

    /**
     * @notice Rebalances the stable borrow rate of an asset
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param user The address of the user
     */
    function rebalanceStableBorrowRate(
        address pool,
        address asset,
        address user
    ) external;

    /**
     * @notice Sets the user use reserve as collateral status of an asset
     * @param pool The address of the pool
     * @param asset The address of the asset
     * @param useAsCollateral The status of the user use reserve as collateral
     */
    function setUserUseReserveAsCollateral(
        address pool,
        address asset,
        bool useAsCollateral
    ) external;

    /**
     * @notice Performs a flash loan
     * @param pool The address of the pool
     * @param receiverAddress The address of the receiver
     * @param assets The addresses of the assets
     * @param amounts The amounts of the assets
     * @param interestRateModes The interest rate modes of the assets
     * @param onBehalfOf The address of the user
     * @param params The parameters of the flash loan
     * @param referralCode The referral code
     */
    function flashLoan(
        address pool,
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /**
     * @notice Performs a simple flash loan
     * @param pool The address of the pool
     * @param receiverAddress The address of the receiver
     * @param asset The address of the asset
     * @param amount The amount of the asset
     * @param params The parameters of the flash loan
     * @param referralCode The referral code
     */
    function flashLoanSimple(
        address pool,
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    /**
     * @notice Sets the user e-mode of a pool
     * @param pool The address of the pool
     * @param categoryId The category id
     */
    function setUserEMode(address pool, uint8 categoryId) external;

    /**
     * @notice Claims all rewards for a user
     * @param rewardsController The address of the rewards controller
     * @param assets The addresses of the assets
     * @return rewardsList The addresses of the rewards
     * @return claimedAmounts The amounts of the rewards
     */
    function claimAllRewards(
        address rewardsController,
        address[] calldata assets
    )
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}
