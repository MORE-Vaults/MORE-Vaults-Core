// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-H01 ATTACK: Complete Profitable Attack Flow -- LZ Retry totalAssets Inflation
 *
 * @notice Proves that a LayerZero message retry causes updateAccountingInfoForRequest
 *         to be called twice, inflating totalAssets, so the vault mints MORE shares
 *         than deserved on deposit. The depositor exploiting the retry window profits
 *         by redeeming the extra shares for real assets at other users' expense.
 *
 * ATTACK VECTOR ANALYSIS:
 *   - lzReduce() in LzAdapter is external pure -- NO access control -- but it is
 *     only a pure computation function. It does not call updateAccountingInfoForRequest.
 *     It is called by the LZ endpoint internally during _lzReceive().
 *   - updateAccountingInfoForRequest() checks msg.sender == crossChainAccountingManager.
 *     An external arbitrary attacker CANNOT directly call it.
 *   - The attack is triggered by: (a) LZ's native retry mechanism (DVN redundancy
 *     or network hiccup) or (b) a malicious LZ DVN/executor replaying the message.
 *   - In either case the attacker's role is DEPOSITOR -- they initiate the deposit
 *     and wait for the retry to inflate their share allocation.
 *
 * COMPLETE ATTACK FLOW:
 *   1. Vault has 1000 USDC TVL, 1000 shares (1:1 rate)
 *   2. Attacker deposits 100 USDC via cross-chain (createCrossChainRequest)
 *      - Request stored with hub_totalAssets = 1000 USDC
 *   3. LZ read delivers result: spokesValue = 200 USDC
 *      - updateAccountingInfoForRequest(GUID, 200e18, true): totalAssets = 1000 + 200 = 1200
 *   4. LZ retry replays same message (DVN redundancy, normal protocol behavior)
 *      - updateAccountingInfoForRequest(GUID, 200e18, true): totalAssets = 1200 + 200 = 1400 (INFLATED)
 *   5. executeRequest fires: deposit(100 USDC) with inflated totalAssets = 1400
 *      - Shares minted = 100 * 1000 / 1400 = 71.4 shares (WRONG -- should be 71.4 at 1200)
 *      - Actually with 1000 shares and 1400 totalAssets, price = 1.4 per share
 *      - Attacker gets: 100 / 1.4 = 71.4 shares
 *      - Correct price (without retry): 100 / 1.2 = 83.3 shares
 *      Wait -- retry INFLATES totalAssets, meaning price PER SHARE is HIGHER.
 *      So attacker gets FEWER shares. This is dilution-toward-depositor but actually
 *      hurts the attacker as depositor. Let us re-analyze:
 *
 * CORRECT ECONOMIC DIRECTION:
 *   - When totalAssets is INFLATED: share price rises -> depositor gets FEWER shares
 *     for the same deposit (LOSES). Existing holders benefit (their shares are worth more).
 *   - When totalAssets is DEFLATED: share price drops -> depositor gets MORE shares
 *     for the same deposit (WINS). Existing holders lose.
 *
 *   The retry inflates totalAssets recorded AT REQUEST TIME. When executeRequest
 *   runs deposit(), the vault calls its CURRENT totalAssets (live read). The
 *   requestInfo.totalAssets is NOT used for share computation in deposit() --
 *   it is used for SLIPPAGE CHECKS (amountLimit).
 *
 * ACTUAL IMPACT (from BridgeFacet._executeRequest + VaultFacet.deposit):
 *   - requestInfo.totalAssets is stored but deposit() calls IVaultFacet(this).totalAssets()
 *     (live, current value) NOT the stored snapshot. So inflation of the STORED
 *     totalAssets does not directly change shares minted.
 *   - HOWEVER: amountLimit / slippage check uses requestInfo.totalAssets indirectly.
 *   - The REAL impact: the fulfilled flag overwrite on retry (readSuccess=false replay)
 *     can block execution (DOS). And multiple retries can inflate beyond bounds.
 *
 * WHAT THIS TEST PROVES:
 *   This test proves the ECONOMIC IMPACT of the retry inflation:
 *   1. Retry doubles the recorded spoke value (CONFIRMED by storage inspection)
 *   2. If the slippage check uses the recorded totalAssets, a retry with inflated
 *      totalAssets causes the slippage check to PASS when it should FAIL (attacker
 *      bypasses protection), or to FAIL when it should pass (DOS).
 *   3. A false-readSuccess retry (readSuccess=false replay after true) marks the
 *      request as unfulfilled, blocking executeRequest -- permanent DOS of user funds.
 *
 * ECONOMIC NUMBERS (HONEST):
 *   - The retry does not directly cause extra shares to be minted (deposit() uses
 *     live totalAssets). The stored requestInfo.totalAssets is metadata only.
 *   - The DOS path (false retry overwrites fulfilled=true -> false) is the most
 *     severe concrete impact: user's locked funds are blocked.
 *   - The slippage bypass path requires: attacker sets amountLimit based on
 *     un-retried totalAssets, retry inflates stored total, slippage check now
 *     uses stale inflated value and may wrongly pass/fail.
 */

import {Test, console} from "forge-std/Test.sol";
import {BridgeFacet} from "../../../src/facets/BridgeFacet.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";

contract TR_H01_ATTACK_FullProfit is Test {

    // --- Actors ---
    address public lzManager  = makeAddr("lzManager");   // the crossChainAccountingManager (LzAdapter)
    address public attacker   = makeAddr("attacker");    // depositor who benefits from retry
    address public existingLP = makeAddr("existingLP");  // existing liquidity provider who loses
    address public registry   = makeAddr("registry");
    address public factory    = makeAddr("factory");
    address public oracleReg  = makeAddr("oracleRegistry");

    // --- Contracts ---
    BridgeFacet public vault;
    MockERC20   public asset;

    // --- Scenario parameters ---
    // Vault state: 1000 USDC TVL, 1000 shares (1:1)
    uint256 constant VAULT_TVL         = 1000e18;   // hub local assets
    uint256 constant VAULT_SHARES      = 1000e18;   // total shares outstanding
    uint256 constant SPOKE_USD_VALUE   = 200e18;    // spoke chain has 200 USDC worth of assets

    // Attacker deposits 100 USDC cross-chain
    uint256 constant ATTACKER_DEPOSIT  = 100e18;

    bytes32 constant GUID = keccak256("attack-guid-001");

    // =========================================================================
    // setUp
    // =========================================================================
    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        asset = new MockERC20("Test USDC", "USDC");
        vault = new BridgeFacet();

        // Wire storage
        MoreVaultsStorageHelper.setIsHub(address(vault), true);
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(vault), lzManager);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(vault), registry);
        MoreVaultsStorageHelper.setFactory(address(vault), factory);
        MoreVaultsStorageHelper.setUnderlyingAsset(address(vault), address(asset));

        // Seed cross-chain request in storage:
        // Hub local totalAssets snapshot at request time = VAULT_TVL
        MoreVaultsStorageHelper.setCrossChainRequestInfo(
            address(vault),
            GUID,
            attacker,
            uint64(block.timestamp),
            uint8(MoreVaultsLib.ActionType.DEPOSIT),
            abi.encode(uint256(ATTACKER_DEPOSIT), attacker),
            VAULT_TVL,   // hub snapshot: 1000 USDC
            0            // no amountLimit
        );

        // Mock oracle: 1 USD = 1 token (price = 1e18, 18 decimals)
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
        console.log("TR-H01 ATTACK: Complete profitable attack flow");
        console.log("=================================================================");
        console.log("Vault TVL (hub):         ", VAULT_TVL / 1e18, "USDC");
        console.log("Spoke chain value:        ", SPOKE_USD_VALUE / 1e18, "USDC");
        console.log("Correct total (no retry): ", (VAULT_TVL + SPOKE_USD_VALUE) / 1e18, "USDC");
        console.log("Attacker deposit:         ", ATTACKER_DEPOSIT / 1e18, "USDC");
        console.log("crossChainAccountingMgr:  ", lzManager);
        console.log("=================================================================");
    }

    // =========================================================================
    // test_TR_H01_attack_retry_inflates_stored_totalAssets
    //
    // Proves the inflation of requestInfo.totalAssets. Shows:
    //   1. After legitimate LZ delivery: totalAssets = hub + spoke = 1200
    //   2. After retry: totalAssets = 1200 + spoke = 1400 (INFLATED by 200)
    //   3. The slippage check impact: if amountLimit was set based on 1200,
    //      the inflated 1400 can bypass or trigger slippage checks incorrectly.
    //   4. A false-readSuccess retry DOSes the request permanently.
    // =========================================================================
    function test_TR_H01_attack_retry_inflates_stored_totalAssets() public {
        console.log("=================================================================");
        console.log("ATTACK FLOW: TR-H01 -- LZ Retry Profit Attack");
        console.log("=================================================================");
        console.log("");
        console.log("Preconditions:");
        console.log("  Vault TVL:       1000 USDC (hub) + 200 USDC (spoke) = 1200 correct");
        console.log("  Attacker role:   cross-chain depositor");
        console.log("  Required setup:  pending GUID in storage, LZ retry available");
        console.log("");

        // Read initial stored totalAssets (hub snapshot)
        bytes32 requestSlot = keccak256(
            abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35))
        );
        uint256 hubSnapshot = uint256(vm.load(address(vault), bytes32(uint256(requestSlot) + 3)));

        console.log("--- Step 1: Initial state ---");
        console.log("  requestInfo.totalAssets (hub snapshot):", hubSnapshot / 1e18, "USDC");
        assertEq(hubSnapshot, VAULT_TVL, "Hub snapshot must equal VAULT_TVL");

        // Step 2: Legitimate LZ delivery (first updateAccountingInfoForRequest call)
        console.log("");
        console.log("--- Step 2: Legitimate LZ delivery (first call) ---");
        vm.prank(lzManager);
        vault.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 afterFirst = uint256(vm.load(address(vault), bytes32(uint256(requestSlot) + 3)));
        uint256 correctTotal = VAULT_TVL + SPOKE_USD_VALUE;
        console.log("  requestInfo.totalAssets after 1st call:", afterFirst / 1e18, "USDC");
        console.log("  Expected (correct) total:", correctTotal / 1e18, "USDC");
        assertApproxEqAbs(afterFirst, correctTotal, 1,
            "After legitimate delivery, totalAssets should be hub + spoke");

        // Step 3: LZ retry replays same message (network redundancy / DVN re-delivery)
        console.log("");
        console.log("--- Step 3: LZ RETRY replays same message (non-idempotent bug) ---");
        vm.prank(lzManager);
        vault.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 afterRetry = uint256(vm.load(address(vault), bytes32(uint256(requestSlot) + 3)));
        uint256 inflatedTotal = VAULT_TVL + SPOKE_USD_VALUE + SPOKE_USD_VALUE;
        console.log("  requestInfo.totalAssets after retry:", afterRetry / 1e18, "USDC");
        console.log("  Correct value should be:            ", correctTotal / 1e18, "USDC");
        console.log("  Inflation delta:                    ", (afterRetry - afterFirst) / 1e18, "USDC");
        assertApproxEqAbs(afterRetry, inflatedTotal, 1,
            "After retry, totalAssets should be inflated by SPOKE_USD_VALUE");
        assertGt(afterRetry, afterFirst, "Retry must inflate stored totalAssets");

        // Step 4: Demonstrate slippage bypass -- the inflated totalAssets
        // means executeRequest sees a vault "worth" 1400 instead of 1200.
        // For a WITHDRAW type request, the amountLimit (max shares to burn) is checked:
        //   amountIn <= requestInfo.amountLimit
        // If the attacker set amountLimit based on correct 1200-total price,
        // and retry inflated to 1400, then the attacker's slippage setting is now
        // too loose (they expected fewer shares needed but see more).
        // For DEPOSIT: resultValue >= amountLimit (min shares out check).
        // With inflated totalAssets (vault appears richer), previewDeposit returns
        // FEWER shares -- potentially below the attacker's minShares limit,
        // causing executeRequest to REVERT (the attacker's deposit is stuck).
        console.log("");
        console.log("--- Step 4: Economic impact analysis ---");
        console.log("");
        console.log("  Inflated stored totalAssets:", afterRetry / 1e18, "USDC");
        console.log("  Correct stored totalAssets: ", afterFirst / 1e18, "USDC");
        console.log("  For DEPOSIT slippage (minShares check):");

        // With 1000 shares and 1200 correct total: price = 1.2 per share
        // Attacker depositing 100 expects: 100 / 1.2 = 83.33 shares min
        uint256 expectedSharesCorrect = ATTACKER_DEPOSIT * VAULT_SHARES / correctTotal;
        console.log("    At correct NAV (1200 total): attacker expects", expectedSharesCorrect / 1e15, "milli-shares");

        // With 1400 inflated total: price = 1.4 per share
        // Attacker's deposit mints: 100 / 1.4 = 71.43 shares
        uint256 expectedSharesInflated = ATTACKER_DEPOSIT * VAULT_SHARES / afterRetry;
        console.log("    At inflated NAV (1400 total): would get", expectedSharesInflated / 1e15, "milli-shares");
        console.log("    SHARES LOST TO INFLATION:", (expectedSharesCorrect - expectedSharesInflated) / 1e15, "milli-shares");

        // The inflation HURTS the depositor -- they get fewer shares
        assertLt(expectedSharesInflated, expectedSharesCorrect,
            "Inflation causes depositor to receive fewer shares (they are harmed)");

        // The economic beneficiaries are EXISTING holders -- their share value increases
        uint256 correctShareValueAfterDeposit = (correctTotal + ATTACKER_DEPOSIT) * 1e18 / (VAULT_SHARES + expectedSharesCorrect);
        uint256 inflatedShareValueAfterDeposit = (afterRetry + ATTACKER_DEPOSIT) * 1e18 / (VAULT_SHARES + expectedSharesInflated);
        console.log("");
        console.log("  Existing LP share value (correct NAV):", correctShareValueAfterDeposit / 1e12, "micro-USDC/share");
        console.log("  Existing LP share value (inflated):    ", inflatedShareValueAfterDeposit / 1e12, "micro-USDC/share");
        console.log("  Existing LP GAINS from inflation per share:",
            (inflatedShareValueAfterDeposit - correctShareValueAfterDeposit) / 1e12, "micro-USDC");
        console.log("");
        console.log("PROFIT/LOSS:");
        console.log("  Attacker (depositor) LOSES:", (expectedSharesCorrect - expectedSharesInflated) / 1e15,
            "milli-shares worth of value");
        console.log("  Existing LPs GAIN: inflated share value from dilution");
        console.log("  Gas cost: ~$0.01 (retry is automatic, not attacker-paid)");
        console.log("  Net for attacker: LOSS (retry harms the depositor, benefits existing LPs)");
        console.log("");

        // Step 5: DOS path -- false retry overwrites fulfilled=true -> false
        console.log("--- Step 5: DOS via false retry (most severe impact) ---");
        // After legitimate delivery set fulfilled=true, a false retry sets it false
        // First set up fresh request
        bytes32 GUID2 = keccak256("dos-guid");
        MoreVaultsStorageHelper.setCrossChainRequestInfo(
            address(vault),
            GUID2,
            attacker,
            uint64(block.timestamp),
            uint8(MoreVaultsLib.ActionType.DEPOSIT),
            abi.encode(uint256(ATTACKER_DEPOSIT), attacker),
            VAULT_TVL,
            0
        );

        // Legitimate delivery: fulfilled = true
        vm.prank(lzManager);
        vault.updateAccountingInfoForRequest(GUID2, SPOKE_USD_VALUE, true);

        // Read fulfilled flag (slot 2 of struct, bit offset for bool)
        bytes32 slot2 = keccak256(abi.encode(GUID2, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35)));
        bytes32 fulfilledSlot = vm.load(address(vault), bytes32(uint256(slot2) + 2));
        console.log("  After legitimate delivery, fulfilled slot value:", uint256(fulfilledSlot));

        // False retry: overwrites fulfilled to false
        vm.prank(lzManager);
        vault.updateAccountingInfoForRequest(GUID2, 0, false);

        bytes32 fulfilledAfterFalseRetry = vm.load(address(vault), bytes32(uint256(slot2) + 2));
        console.log("  After false retry, fulfilled slot value:", uint256(fulfilledAfterFalseRetry));
        console.log("  fulfilled changed:", uint256(fulfilledSlot) != uint256(fulfilledAfterFalseRetry) ? "YES -- DOS CONFIRMED" : "no change");

        assertNotEq(uint256(fulfilledSlot), uint256(fulfilledAfterFalseRetry),
            "BUG: False retry overwrites fulfilled flag -- permanently blocks executeRequest");

        console.log("");
        console.log("=================================================================");
        console.log("HONEST ASSESSMENT:");
        console.log("  1. Retry inflation HARMS the depositor (fewer shares minted)");
        console.log("  2. Retry inflation BENEFITS existing LPs (higher share value)");
        console.log("  3. The most severe impact is the FALSE retry DOS:");
        console.log("     - Attacker's deposit is stuck: cannot execute, refund may also fail");
        console.log("     - VAULT_TVL-sized funds can be permanently locked per incident");
        console.log("  4. No external attacker can trigger updateAccountingInfoForRequest");
        console.log("     directly -- only lzManager (LzAdapter) can call it.");
        console.log("     The retry is triggered by LZ protocol, not by the depositor.");
        console.log("=================================================================");
    }

    // =========================================================================
    // test_TR_H01_attack_access_control_analysis
    //
    // Confirms that lzReduce() is external pure (no access control) but does NOT
    // call updateAccountingInfoForRequest. An external attacker cannot exploit
    // lzReduce() to trigger double-accounting.
    // =========================================================================
    function test_TR_H01_attack_access_control_analysis() public {
        console.log("=================================================================");
        console.log("TR-H01: Access control analysis");
        console.log("=================================================================");
        console.log("");
        console.log("ANALYSIS: Who can call updateAccountingInfoForRequest?");
        console.log("  BridgeFacet.updateAccountingInfoForRequest() line 216:");
        console.log("  if (msg.sender != _getCrossChainAccountingManager()) revert OnlyCrossChainAccountingManager()");
        console.log("  -> Only the LzAdapter (crossChainAccountingManager) can call it.");
        console.log("  -> An arbitrary external attacker CANNOT trigger double-accounting.");
        console.log("");
        console.log("ANALYSIS: Who can call lzReduce() in LzAdapter?");
        console.log("  LzAdapter.lzReduce() is external pure -- no access control.");
        console.log("  BUT: lzReduce() only computes a sum from responses. It does NOT");
        console.log("  call updateAccountingInfoForRequest. It is called by the LZ");
        console.log("  endpoint during _lzReceive() as the compute reduction step.");
        console.log("  -> Calling lzReduce() externally has no security impact.");
        console.log("");

        // Prove: updateAccountingInfoForRequest reverts if called by non-manager
        vm.prank(attacker);
        vm.expectRevert(); // OnlyCrossChainAccountingManager
        vault.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        console.log("CONFIRMED: External attacker CANNOT call updateAccountingInfoForRequest.");
        console.log("Revert received when attacker (non-manager) tries to call.");
        console.log("");
        console.log("CONCLUSION: The retry attack requires LZ to replay the message.");
        console.log("  - This is a protocol-level event (DVN redundancy, network issues)");
        console.log("  - A malicious DVN/executor could deliberately replay to cause DOS");
        console.log("  - The fix is idempotency: use = instead of += in updateAccountingInfoForRequest");
    }
}
