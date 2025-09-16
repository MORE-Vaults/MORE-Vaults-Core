// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IAggregatorV2V3Interface} from "../interfaces/Chainlink/IAggregatorV2V3Interface.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";

/**
 * @title OracleRegistry
 * @author MORE Labs
 * @notice Contract to get asset prices, manage price sources
 * - Use of Chainlink compatible Aggregators as source of price
 * - Owned by the MORE Vaults governance
 */
contract OracleRegistry is IOracleRegistry, AccessControlUpgradeable {
    // Map of asset price sources (asset => priceSource)
    mapping(address => OracleInfo) private oracleInfos;

    address public override BASE_CURRENCY;
    uint256 public override BASE_CURRENCY_UNIT;

    bytes32 public constant ORACLE_MANAGER_ROLE =
        keccak256("ORACLE_MANAGER_ROLE");

    /**
     * @notice Initialize the OracleRegistry
     * @param assets The addresses of the assets
     * @param infos The infos of each asset
     * @param owner The owner of the OracleRegistry
     * @param baseCurrency The base currency used for the price quotes. If USD is used, base currency is 0x0
     * @param baseCurrencyUnit The unit of the base currency
     */
    function initialize(
        address[] memory assets,
        OracleInfo[] memory infos,
        address owner,
        address baseCurrency,
        uint256 baseCurrencyUnit
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(ORACLE_MANAGER_ROLE, owner);

        _setOracleInfos(assets, infos);
        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_UNIT = baseCurrencyUnit;
        emit BaseCurrencySet(baseCurrency, baseCurrencyUnit);
    }

    function setOracleInfos(
        address[] calldata assets,
        OracleInfo[] calldata infos
    ) external override onlyRole(ORACLE_MANAGER_ROLE) {
        _setOracleInfos(assets, infos);
    }

    /**
     * @notice Internal function to set the infos for each asset
     * @param assets The addresses of the assets
     * @param infos The infos of each asset
     */
    function _setOracleInfos(
        address[] memory assets,
        OracleInfo[] memory infos
    ) internal {
        if (assets.length != infos.length) {
            revert InconsistentParamsLength();
        }
        for (uint256 i = 0; i < assets.length; ) {
            oracleInfos[assets[i]].aggregator = infos[i].aggregator;
            oracleInfos[assets[i]].stalenessThreshold = infos[i]
                .stalenessThreshold;
            emit OracleInfoUpdated(assets[i], infos[i]);
            unchecked {
                ++i;
            }
        }
    }

    function getAssetPrice(
        address asset
    ) public view override returns (uint256) {
        OracleInfo memory info = oracleInfos[asset];

        if (asset == BASE_CURRENCY) {
            return BASE_CURRENCY_UNIT;
        } else {
            (, int256 price, , uint256 updatedAt, ) = info
                .aggregator
                .latestRoundData();
            _verifyPrice(price, updatedAt, info.stalenessThreshold);
            return uint256(price);
        }
    }

    function getAssetsPrices(
        address[] calldata assets
    ) external view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ) {
            prices[i] = getAssetPrice(assets[i]);
            unchecked {
                ++i;
            }
        }
        return prices;
    }

    function getOracleInfo(
        address asset
    ) external view override returns (OracleInfo memory) {
        return oracleInfos[asset];
    }

    function _verifyPrice(
        int256 answer,
        uint256 updatedAt,
        uint96 stalenessThreshold
    ) internal view {
        if (updatedAt < block.timestamp - stalenessThreshold) {
            revert OraclePriceIsOld();
        }
        if (answer <= 0) {
            revert PriceIsNotAvailable();
        }
    }
}

// TODO: Permissionless OracleRegistry
// TODO: Permissionless deployment of the vault with flag
// TODO: deployment script revamp
// TODO: put timelock to any role change
