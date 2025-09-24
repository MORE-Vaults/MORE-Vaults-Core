// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

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
    mapping(address => OracleInfo) private _oracleInfos;
    // Map of spoke value sources (hub => chainId => oracle)
    mapping(address => mapping(uint16 => OracleInfo))
        private _spokeVaultOracleInfos;

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
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        _setOracleInfos(assets, infos);
    }

    function setSpokeOracleInfos(
        address hub,
        uint16[] calldata chainIds,
        OracleInfo[] calldata infos
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        _setSpokeOracleInfos(hub, chainIds, infos);
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
            _oracleInfos[assets[i]].aggregator = infos[i].aggregator;
            _oracleInfos[assets[i]].stalenessThreshold = infos[i]
                .stalenessThreshold;
            emit OracleInfoUpdated(assets[i], infos[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal function to set the infos for spoke vaults
     */
    function _setSpokeOracleInfos(
        address hub,
        uint16[] calldata chainIds,
        OracleInfo[] calldata infos
    ) internal {
        if (chainIds.length != infos.length) {
            revert InconsistentParamsLength();
        }
        for (uint256 i = 0; i < chainIds.length; ) {
            _spokeVaultOracleInfos[hub][chainIds[i]] = infos[i];
            emit SpokeOracleInfoUpdated(hub, chainIds[i], infos[i]);
            unchecked {
                ++i;
            }
        }
    }

    function getSpokeValue(
        address hub,
        uint16 chainId
    ) external view returns (uint256) {
        OracleInfo memory info = _spokeVaultOracleInfos[hub][chainId];

        (, int256 value, , uint256 updatedAt, ) = info
            .aggregator
            .latestRoundData();

        // originally in nanoseconds for Stork oracles
        // workaround to convert from Stork's format to Chainlink's one.
        if (block.timestamp < updatedAt / 1e7) {
            updatedAt /= 1e9;
        }
        _verifyAnswer(value, updatedAt, info.stalenessThreshold);
        return uint256(value);
    }

    function getAssetPrice(
        address asset
    ) public view override returns (uint256) {
        OracleInfo memory info = _oracleInfos[asset];

        if (asset == BASE_CURRENCY) {
            return BASE_CURRENCY_UNIT;
        } else {
            (, int256 price, , uint256 updatedAt, ) = info
                .aggregator
                .latestRoundData();
            _verifyAnswer(price, updatedAt, info.stalenessThreshold);
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
        return _oracleInfos[asset];
    }

    function getSpokeOracleInfo(
        address hub,
        uint16 chainId
    ) external view returns (OracleInfo memory) {
        return _spokeVaultOracleInfos[hub][chainId];
    }

    function _verifyAnswer(
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
