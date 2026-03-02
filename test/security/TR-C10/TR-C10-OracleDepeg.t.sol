// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * TR-C10 -- Oracle Configuration Traps
 *
 * This file verifies all four claimed paths from the original finding and
 * determines which deserve a proper security write-up.
 *
 * RESULTS SUMMARY (see individual tests):
 *   Path 1 (aggregator=address(0)) : CONFIRMED real DoS -- but admin-only.
 *   Path 2 (stalenessThreshold=0)  : CONFIRMED real DoS -- but admin-only.
 *   Path 3 (Stork heuristic misfire): CONFIRMED IMPOSSIBLE for real Chainlink data.
 *   Path 4 (BASE_CURRENCY hardcoded): CONFIRMED REAL -- oracle-level share inflation.
 */

import {Test} from "forge-std/Test.sol";
import {OracleRegistry, IOracleRegistry} from "../../../src/registry/OracleRegistry.sol";
import {IAggregatorV2V3Interface} from "../../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";

// Reusable mock aggregator
contract MockAggregatorC10 {
    int256  public answer;
    uint256 public updatedAt;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer    = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }

    function setAnswer(int256 _answer) external { answer = _answer; }
    function setUpdatedAt(uint256 _ts) external  { updatedAt = _ts;  }
}

contract TR_C10_OracleDepegTest is Test {

    OracleRegistry public registry;

    address public admin        = address(0xA1);
    address public asset        = address(0xA2);   // a regular vault asset
    address public baseCurrency = address(0xA3);   // e.g., USDC

    uint256 public constant BASE_CURRENCY_UNIT = 1e8; // $1.00 in 8-decimal Chainlink format
    uint96  public constant STALENESS          = 1 hours;

    // ── helpers ──────────────────────────────────────────────────────────
    function _initRegistry(MockAggregatorC10 agg) internal {
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0]  = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(agg)),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, BASE_CURRENCY_UNIT);
    }

    function setUp() public {
        vm.prank(admin);
        registry = new OracleRegistry();
        skip(1 hours); // ensure block.timestamp > 0
    }

    // ======================================================================
    // PATH 1 -- aggregator == address(0) causes permanent getAssetPrice DoS
    // ======================================================================
    /**
     * VERDICT: Real DoS, but admin-only.
     *
     * Calling getAssetPrice() on an asset whose aggregator is address(0) causes
     * a revert because calling latestRoundData() on address(0) returns empty bytes
     * which cannot be ABI-decoded as (uint80, int256, uint256, uint256, uint80).
     *
     * However: only ORACLE_MANAGER_ROLE can call setOracleInfos.  This requires
     * a privileged admin to either intentionally or accidentally configure a
     * zero-address aggregator.  Severity: Informational (admin self-inflicted).
     *
     * Note: the test for this was COMMENTED OUT in OracleRegistry.t.sol,
     * indicating the team was aware of it but did not implement the guard.
     */
    function test_C10_path1_aggregator_zero_reverts_getAssetPrice() public {
        // Initialize with a valid aggregator first
        MockAggregatorC10 validAgg = new MockAggregatorC10(1e8, block.timestamp);
        _initRegistry(validAgg);

        // Admin overwrites with address(0) aggregator
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory badInfos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        badInfos[0] = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(0)),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.setOracleInfos(assets, badInfos);

        // getAssetPrice now reverts -- call to address(0).latestRoundData()
        // fails on ABI decoding the empty return
        vm.expectRevert();
        registry.getAssetPrice(asset);

        // VERDICT: Real DoS -- but requires admin (ORACLE_MANAGER_ROLE) to set it.
        // Classification: Informational (same class as TR-C07 governance brick).
        // No external actor can trigger this.
    }

    // ======================================================================
    // PATH 2 -- stalenessThreshold == 0 causes permanent DoS
    // ======================================================================
    /**
     * VERDICT: Real DoS, but admin-only.
     *
     * _verifyAnswer checks: updatedAt < block.timestamp - stalenessThreshold
     * With stalenessThreshold=0: updatedAt < block.timestamp
     * This is true for ANY oracle not updated in the exact current block --
     * i.e., always true in practice.  Every getAssetPrice call reverts OraclePriceIsOld.
     *
     * Also: the uninitialized default for OracleInfo.stalenessThreshold is 0,
     * meaning any asset added to availableAssets without a subsequent setOracleInfos
     * call will also be permanently DoS'd (address(0) aggregator + staleness=0).
     *
     * Severity: Informational (admin self-inflicted, default-value pitfall).
     */
    function test_C10_path2_staleness_zero_always_reverts_getAssetPrice() public {
        // Configure aggregator with valid price but stalenessThreshold = 0
        MockAggregatorC10 agg = new MockAggregatorC10(1e8, block.timestamp - 1); // updated 1 second ago
        address[] memory assets = new address[](1);
        IOracleRegistry.OracleInfo[] memory infos = new IOracleRegistry.OracleInfo[](1);
        assets[0] = asset;
        infos[0] = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(agg)),
            stalenessThreshold: 0  // ← zero staleness
        });
        vm.prank(admin);
        registry.initialize(assets, infos, admin, baseCurrency, BASE_CURRENCY_UNIT);

        // Even though the oracle was updated just 1 second ago, staleness=0 means
        // "updatedAt must be >= block.timestamp" which is never true for past updates
        vm.expectRevert(IOracleRegistry.OraclePriceIsOld.selector);
        registry.getAssetPrice(asset);

        // VERDICT: Real permanent DoS with staleness=0.
        // Severity: Informational (admin self-inflicted, same as TR-C07).
    }

    // ======================================================================
    // PATH 3 -- Stork heuristic CANNOT misfire for real Chainlink timestamps
    // ======================================================================
    /**
     * VERDICT: Claim is mathematically invalid.  Not a real vulnerability.
     *
     * The heuristic in getSpokeValue:
     *   if (block.timestamp < updatedAt / 1e7) { updatedAt /= 1e9; }
     *
     * Trigger condition: updatedAt / 1e7 > block.timestamp
     *                    updatedAt > block.timestamp * 1e7
     *                    updatedAt > ~1.7e9 * 1e7 = ~1.7e16
     *
     * Chainlink real oracle: updatedAt ≈ 1.7e9 (seconds since Unix epoch).
     *   1.7e9 > 1.7e16? NO → heuristic does not trigger → correct behavior.
     *
     * Stork real oracle: updatedAt ≈ 1.7e18 (nanoseconds since Unix epoch).
     *   1.7e18 > 1.7e16? YES → divide by 1e9 → 1.7e9 seconds → correct.
     *
     * For the heuristic to misfire on Chainlink, the oracle would need to return
     * updatedAt > 1.7e16 -- about 500 million years in the future.  Impossible
     * for any legitimate Chainlink feed.
     */
    function test_C10_path3_stork_heuristic_cannot_misfire_for_chainlink() public {
        // Set up spoke oracle infrastructure for getSpokeValue
        MockAggregatorC10 validAgg = new MockAggregatorC10(1e8, block.timestamp);
        _initRegistry(validAgg);

        address hub      = address(0xB0B);
        uint32  chainId  = 101;
        uint32[] memory chainIds = new uint32[](1);
        chainIds[0] = chainId;

        // ── Case A: real Chainlink timestamp (current Unix epoch seconds) ──
        // block.timestamp ≈ 1 hour (forge default: ~3600 after skip(1 hours))
        // In production block.timestamp ≈ 1.7e9; we use block.timestamp here.
        uint256 chainlinkUpdatedAt = block.timestamp - 10 minutes; // recently updated

        IOracleRegistry.OracleInfo[] memory spokeInfos = new IOracleRegistry.OracleInfo[](1);
        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(new MockAggregatorC10(500e8, chainlinkUpdatedAt))),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        // Heuristic check: block.timestamp < chainlinkUpdatedAt / 1e7 ?
        // block.timestamp=3600, chainlinkUpdatedAt/1e7 = (3600-600)/1e7 ≈ 0 → condition FALSE → no division
        bool heuristicWouldTrigger = block.timestamp < chainlinkUpdatedAt / 1e7;
        assertFalse(heuristicWouldTrigger,
            "PATH3: Stork heuristic must NOT trigger for real Chainlink timestamp");

        // getSpokeValue works correctly -- no misfire
        uint256 value = registry.getSpokeValue(hub, chainId);
        assertEq(value, 500e8, "PATH3: spoke value correct with real Chainlink timestamp");

        // ── Case B: Stork timestamp (current epoch in nanoseconds) ──
        uint256 storkUpdatedAt = block.timestamp * 1e9; // nanoseconds

        // Heuristic check: block.timestamp < storkUpdatedAt / 1e7 ?
        // block.timestamp=3600, storkUpdatedAt/1e7 = 3600*1e9/1e7 = 360000 → condition TRUE
        bool storkTriggers = block.timestamp < storkUpdatedAt / 1e7;
        assertTrue(storkTriggers,
            "PATH3: Stork heuristic MUST trigger for real Stork nanosecond timestamp");

        spokeInfos[0] = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(new MockAggregatorC10(888e8, storkUpdatedAt))),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.setSpokeOracleInfos(hub, chainIds, spokeInfos);

        uint256 storkValue = registry.getSpokeValue(hub, chainId);
        assertEq(storkValue, 888e8, "PATH3: spoke value correct with Stork nanosecond timestamp");

        // VERDICT: The heuristic works correctly.  Path 3 is not a vulnerability.
    }

    // ======================================================================
    // PATH 4 -- BASE_CURRENCY hardcoded: no depeg detection
    // ======================================================================

    /**
     * C10-01 -- getAssetPrice(BASE_CURRENCY) ignores any oracle, always returns $1.00
     *
     * Even if a real oracle for BASE_CURRENCY is configured AND reports a depeg
     * price (e.g. $0.85), getAssetPrice short-circuits and returns BASE_CURRENCY_UNIT.
     * The oracle configuration is completely bypassed.
     */
    function test_C10_01_getAssetPrice_baseCurrency_ignores_oracle_during_depeg() public {
        MockAggregatorC10 regularAssetAgg = new MockAggregatorC10(2000e8, block.timestamp);
        _initRegistry(regularAssetAgg);

        // Configure a REAL oracle for BASE_CURRENCY reporting a depeg (USDC at $0.85)
        int256 depegPrice = 0.85e8; // $0.85 in 8-decimal Chainlink format
        MockAggregatorC10 baseCurrencyAgg = new MockAggregatorC10(depegPrice, block.timestamp);

        address[] memory bAssets = new address[](1);
        IOracleRegistry.OracleInfo[] memory bInfos  = new IOracleRegistry.OracleInfo[](1);
        bAssets[0] = baseCurrency;
        bInfos[0]  = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(baseCurrencyAgg)),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.setOracleInfos(bAssets, bInfos);

        // Verify oracle IS configured correctly for BASE_CURRENCY
        assertEq(
            address(registry.getOracleInfo(baseCurrency).aggregator),
            address(baseCurrencyAgg),
            "oracle should be configured for BASE_CURRENCY"
        );

        // BUG: getAssetPrice ignores the oracle and returns the hardcoded $1.00
        uint256 reportedPrice = registry.getAssetPrice(baseCurrency);
        assertEq(reportedPrice, BASE_CURRENCY_UNIT,
            "BUG: getAssetPrice(BASE_CURRENCY) returns $1.00 regardless of oracle");
        assertNotEq(reportedPrice, uint256(depegPrice),
            "BUG: depeg oracle price is completely ignored");
    }

    /**
     * C10-02 -- Share price inflation quantified during a depeg
     *
     * Demonstrates the overvaluation: if BASE_CURRENCY (USDC) depegs to $0.85,
     * every vault whose underlying or available asset is USDC has its asset
     * valued 17.6% above real market value.
     *
     * A user depositing at the inflated $1.00/USDC rate receives fewer shares
     * than the real value justifies.  A user redeeming at the inflated rate
     * receives more underlying than they are entitled to.
     */
    function test_C10_02_share_price_inflation_magnitude_during_depeg() public {
        MockAggregatorC10 regularAssetAgg = new MockAggregatorC10(2000e8, block.timestamp);
        _initRegistry(regularAssetAgg);

        // Simulated vault holds 10,000 USDC (BASE_CURRENCY)
        uint256 usdcHolding  = 10_000; // units
        uint256 usdcDecimals = 1e6;    // USDC has 6 decimals

        // Oracle price during depeg
        uint256 realUsdcPrice = 0.85e8; // $0.85

        // What the oracle would report (real market value)
        uint256 realUsdcValueUsd = (usdcHolding * usdcDecimals * realUsdcPrice) / 1e8;
        // What getAssetPrice(BASE_CURRENCY) reports (hardcoded)
        uint256 reportedUsdcValueUsd = (usdcHolding * usdcDecimals * registry.getAssetPrice(baseCurrency)) / 1e8;

        // BUG: reported value > real value
        assertGt(reportedUsdcValueUsd, realUsdcValueUsd,
            "BUG: totalAssets should be inflated when BASE_CURRENCY depegs");

        uint256 inflationBps = ((reportedUsdcValueUsd - realUsdcValueUsd) * 10_000) / realUsdcValueUsd;
        // ~1765 bps ≈ 17.65% inflation
        assertGt(inflationBps, 1700,
            "BUG: inflation must exceed 17% for a 15-cent depeg");

        // Log the precise inflation for the report
        emit log_named_uint("Real USDC value (USD, 8dec scaled)", realUsdcValueUsd);
        emit log_named_uint("Reported USDC value (USD, 8dec scaled)", reportedUsdcValueUsd);
        emit log_named_uint("Inflation (bps)", inflationBps);
    }

    // ======================================================================
    // C10-FIX -- With oracle wired to BASE_CURRENCY, depeg price is used
    // ======================================================================
    /**
     * FIX verification: getAssetPrice(BASE_CURRENCY) should use the oracle
     * feed when one is configured, enabling depeg detection.
     *
     * Fix: remove the early-return short-circuit for BASE_CURRENCY so the
     * oracle path is always followed.
     *
     * Without fix: returns BASE_CURRENCY_UNIT ($1.00) → assertTrue(reportedPrice == depegPrice) FAILS.
     * With fix: returns oracle price ($0.85) → assertion PASSES.
     */
    function test_C10_FIX_getAssetPrice_baseCurrency_uses_oracle_during_depeg() public {
        MockAggregatorC10 regularAssetAgg = new MockAggregatorC10(2000e8, block.timestamp);
        _initRegistry(regularAssetAgg);

        // Configure a depeg oracle for BASE_CURRENCY
        int256 depegPrice = 0.85e8;
        MockAggregatorC10 baseCurrencyAgg = new MockAggregatorC10(depegPrice, block.timestamp);

        address[] memory bAssets = new address[](1);
        IOracleRegistry.OracleInfo[] memory bInfos  = new IOracleRegistry.OracleInfo[](1);
        bAssets[0] = baseCurrency;
        bInfos[0]  = IOracleRegistry.OracleInfo({
            aggregator:         IAggregatorV2V3Interface(address(baseCurrencyAgg)),
            stalenessThreshold: STALENESS
        });
        vm.prank(admin);
        registry.setOracleInfos(bAssets, bInfos);

        // FIX: getAssetPrice(BASE_CURRENCY) should return oracle price ($0.85), not hardcoded $1.00.
        // Without fix: returns 1e8 → assertEqual fails.
        // With fix:    returns 0.85e8 → assertEqual passes.
        uint256 reportedPrice = registry.getAssetPrice(baseCurrency);
        assertEq(reportedPrice, uint256(depegPrice),
            "FIX: getAssetPrice(BASE_CURRENCY) must return oracle price during depeg");
    }
}
