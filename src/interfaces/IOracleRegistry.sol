// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IAggregatorV2V3Interface} from "../interfaces/Chainlink/IAggregatorV2V3Interface.sol";

/**
 * @title IOracleRegistry
 * @author MORE Labs
 * @notice Interface for the OracleRegistry contract to get asset prices and manage price sources
 */
interface IOracleRegistry {
    error PriceIsNotAvailable();
    error InconsistentParamsLength();
    error OraclePriceIsOld();

    /**
     * @notice Struct describing the asset price source and staleness threshold
     * @param aggregator The Chainlink aggregator interface for the asset
     * @param stalenessThreshold The maximum allowed staleness for the price data
     */
    struct OracleInfo {
        IAggregatorV2V3Interface aggregator;
        uint96 stalenessThreshold;
    }

    /**
     * @notice Emitted when the base currency is set
     * @param baseCurrency The address of the base currency
     * @param baseCurrencyUnit The unit of the base currency
     */
    event BaseCurrencySet(
        address indexed baseCurrency,
        uint256 baseCurrencyUnit
    );

    /**
     * @notice Emitted when an asset source is updated
     * @param asset The address of the asset
     * @param info The new OracleInfo struct for the asset
     */
    event OracleInfoUpdated(address indexed asset, OracleInfo info);

    /**
     * @notice Returns the base currency address used for price quotes
     * @return The address of the base currency (e.g., 0x0 for USD)
     */
    function BASE_CURRENCY() external view returns (address);

    /**
     * @notice Returns the unit of the base currency
     * @return The unit of the base currency (e.g., 1e8 for USD)
     */
    function BASE_CURRENCY_UNIT() external view returns (uint256);

    /**
     * @notice Sets the price sources for a list of assets
     * @dev Only callable by accounts with the ORACLE_MANAGER_ROLE
     * @param assets The addresses of the assets
     * @param infos The OracleInfo struct for each asset
     */
    function setOracleInfos(
        address[] calldata assets,
        OracleInfo[] calldata infos
    ) external;

    /**
     * @notice Returns the price of a given asset
     * @param asset The address of the asset
     * @return The price of the asset in the base currency
     */
    function getAssetPrice(address asset) external view returns (uint256);

    /**
     * @notice Returns the prices of a list of assets
     * @param assets The addresses of the assets
     * @return An array of prices for each asset in the base currency
     */
    function getAssetsPrices(
        address[] calldata assets
    ) external view returns (uint256[] memory);

    /**
     * @notice Returns the OracleInfo struct for a given asset
     * @param asset The address of the asset
     * @return The OracleInfo struct containing aggregator and staleness threshold
     */
    function getOracleInfo(
        address asset
    ) external view returns (OracleInfo memory);
}
