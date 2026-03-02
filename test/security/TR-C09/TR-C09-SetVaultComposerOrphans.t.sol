// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

// ── C09-01/02: BridgeFacet infrastructure ────────────────────────────────
import {BridgeFacetHarness} from "../../mocks/BridgeFacetHarness.sol";
import {MockVaultsFactory} from "../../mocks/MockVaultsFactory.sol";
import {MockMoreVaultsRegistry} from "../../mocks/MockMoreVaultsRegistry.sol";
import {MockOracleRegistry} from "../../mocks/MockOracleRegistry.sol";
import {MockBridgeAdapter} from "../../mocks/MockBridgeAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockMoreVaultsComposer} from "../../mocks/MockMoreVaultsComposer.sol";
import {MockMoreVaultsEscrow} from "../../mocks/MockMoreVaultsEscrow.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IBridgeFacet} from "../../../src/interfaces/facets/IBridgeFacet.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";

// ── C09-03: LzAdapter infrastructure ─────────────────────────────────────
import {LzAdapter} from "../../../src/cross-chain/layerZero/LzAdapter.sol";

// ── C09-FIX: VaultsFactory infrastructure ────────────────────────────────
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";
import {VaultsFactory} from "../../../src/factory/VaultsFactory.sol";

// ==========================================================================
// Inline mocks for C09-03 (LzAdapter path)
// ==========================================================================

contract MockEndpointC09 {
    function setDelegate(address) external {}
    function eid() external pure returns (uint32) { return 1; }
}

contract MockVaultsFactoryC09 {
    mapping(address => address) public vaultComposer;
    mapping(address => bool) private _vaults;

    function setVaultComposer(address vault, address composer) external {
        vaultComposer[vault] = composer;
    }

    function setVault(address vault, bool isValid) external {
        _vaults[vault] = isValid;
    }

    function isFactoryVault(address vault) external view returns (bool) {
        return _vaults[vault];
    }
}

contract MockVaultC09 {
    function updateAccountingInfoForRequest(bytes32, uint256, bool) external {}
    function executeRequest(bytes32) external {}
    receive() external payable {}
}

contract MockLzComposerTrackerC09 {
    mapping(bytes32 => uint256) public sendDepositSharesCalls;
    mapping(bytes32 => uint256) public refundDepositCalls;

    function sendDepositShares(bytes32 guid) external {
        sendDepositSharesCalls[guid]++;
    }

    function refundDeposit(bytes32 guid) external payable {
        refundDepositCalls[guid]++;
    }
}

// LzAdapter harness that exposes _lzReceive and _guidToCallInfo internals
contract LzAdapterHarnessC09 is LzAdapter {
    constructor(
        address _endpoint,
        address _delegate,
        uint32 _readChannel,
        address _vaultsFactory,
        address _vaultsRegistry
    ) LzAdapter(_endpoint, _delegate, _readChannel, _vaultsFactory, _vaultsRegistry) {}

    function exposed_lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external {
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    function setCallInfo(bytes32 guid, address vault, address initiator) external {
        _guidToCallInfo[guid] = CallInfo({vault: vault, initiator: initiator});
    }
}

// ==========================================================================
// Inline mock for C09-FIX: a composer that reports non-zero totalNativePending
// ==========================================================================

contract MockComposerWithPendingC09 {
    uint256 private _pending;

    function setTotalNativePending(uint256 amount) external {
        _pending = amount;
    }

    function totalNativePending() external view returns (uint256) {
        return _pending;
    }
}

// ==========================================================================
// Main test contract
// ==========================================================================

contract TR_C09_SetVaultComposerOrphansTest is Test {

    // ── C09-01/02 shared state ─────────────────────────────────────────────
    BridgeFacetHarness  public facet;
    MockVaultsFactory   public factory;
    MockMoreVaultsRegistry public registry;
    MockOracleRegistry  public oracle;
    MockBridgeAdapter   public adapter;
    MockERC20           public underlying;
    MockMoreVaultsComposer public composer;
    MockMoreVaultsEscrow   public escrow;

    address public owner   = address(1);
    address public curator = address(2);

    function setUp() public {
        facet      = new BridgeFacetHarness();
        factory    = new MockVaultsFactory();
        registry   = new MockMoreVaultsRegistry();
        oracle     = new MockOracleRegistry();
        adapter    = new MockBridgeAdapter();
        underlying = new MockERC20("Underlying", "UND");
        composer   = new MockMoreVaultsComposer();
        escrow     = new MockMoreVaultsEscrow();

        MoreVaultsStorageHelper.setOwner(address(facet), owner);
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(registry));
        registry.setOracle(address(oracle));
        registry.setEscrow(address(escrow));
        MoreVaultsStorageHelper.setFactory(address(facet), address(factory));
        MoreVaultsStorageHelper.setCrossChainAccountingManager(address(facet), address(adapter));
        factory.setVaultComposer(address(facet), address(composer));

        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(underlying));
        oracle.setAssetPrice(address(underlying), 1e8);
        escrow.setUnderlyingToken(address(facet), address(underlying));

        // Wire hub→spokes so initVaultActionRequest doesn't revert NotCrossChainVault
        uint32[] memory eids   = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        factory.setLocalEid(100);
        factory.setHubToSpokes(100, address(facet), eids, spokes);
    }

    // ======================================================================
    // C09-01  refundStuckDepositInComposer succeeds before any composer upgrade
    // ======================================================================
    /**
     * Baseline: composer initiates a DEPOSIT cross-chain request, the request
     * times out without an LZ response.  refundStuckDepositInComposer should
     * succeed and call refundDeposit on the (still-current) composer.
     */
    function test_C09_01_refundStuckDeposit_succeeds_before_upgrade() public {
        bytes32 depositGuid = keccak256("guid-c09-01");
        adapter.setReceiptGuid(depositGuid);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        // Composer initiates the deposit request (so initiator = composer)
        vm.startPrank(address(composer));
        underlying.mint(address(composer), 100e18);
        underlying.approve(address(escrow), 100e18);
        bytes memory callData = abi.encode(uint256(10e18), address(0xCAFE01));
        bytes32 guid = facet.initVaultActionRequest{value: 0}(
            MoreVaultsLib.ActionType.DEPOSIT, callData, 0, bytes("")
        );
        vm.stopPrank();

        assertEq(guid, depositGuid, "guid mismatch");

        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertEq(info.initiator, address(composer), "initiator should be composer");

        // Advance past MAX_DELAY so the request is considered stuck
        vm.warp(info.timestamp + facet.MAX_DELAY() + 1);

        uint256 refundValue = 0.05 ether;
        vm.deal(address(adapter), refundValue);

        vm.prank(address(adapter));
        facet.refundStuckDepositInComposer{value: refundValue}(guid);

        assertEq(composer.refundDepositCalls(guid), 1,
            "BUG: refundDeposit should have been called on composer once");
    }

    // ======================================================================
    // C09-02  refundStuckDepositInComposer is blocked after composer upgrade
    // ======================================================================
    /**
     * BUG: After setVaultComposer(vault, newComposer) is called, any stuck
     * request whose initiator is the OLD composer can no longer be refunded.
     * refundStuckDepositInComposer compares requestInfo.initiator against
     * factory.vaultComposer(vault), which now returns newComposer.  The
     * check fails and the transaction reverts InitiatorIsNotVaultComposer,
     * leaving the old composer's pendingDeposit permanently orphaned.
     */
    function test_C09_02_refundStuckDeposit_reverts_InitiatorIsNotVaultComposer_after_upgrade() public {
        bytes32 depositGuid = keccak256("guid-c09-02");
        adapter.setReceiptGuid(depositGuid);
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(address(facet), false);

        // Composer initiates the deposit request (initiator = oldComposer)
        vm.startPrank(address(composer));
        underlying.mint(address(composer), 100e18);
        underlying.approve(address(escrow), 100e18);
        bytes memory callData = abi.encode(uint256(10e18), address(0xCAFE02));
        bytes32 guid = facet.initVaultActionRequest{value: 0}(
            MoreVaultsLib.ActionType.DEPOSIT, callData, 0, bytes("")
        );
        vm.stopPrank();

        MoreVaultsLib.CrossChainRequestInfo memory info = facet.getRequestInfo(guid);
        assertEq(info.initiator, address(composer), "initiator should be old composer");

        // -- Owner upgrades the composer --
        MockMoreVaultsComposer newComposer = new MockMoreVaultsComposer();
        factory.setVaultComposer(address(facet), address(newComposer));
        assertEq(factory.vaultComposer(address(facet)), address(newComposer),
            "factory should now point to newComposer");

        // Advance past MAX_DELAY so the request is considered stuck
        vm.warp(info.timestamp + facet.MAX_DELAY() + 1);

        uint256 refundValue = 0.05 ether;
        vm.deal(address(adapter), refundValue);

        // BUG: refund is now blocked -- initiator=oldComposer != vaultComposer=newComposer
        vm.prank(address(adapter));
        vm.expectRevert(IBridgeFacet.InitiatorIsNotVaultComposer.selector);
        facet.refundStuckDepositInComposer{value: refundValue}(guid);

        assertEq(composer.refundDepositCalls(guid), 0,
            "BUG: refundDeposit should NOT have been called; deposit is orphaned");
    }

    // ======================================================================
    // C09-03  LzAdapter._lzReceive skips callback to old composer after upgrade
    // ======================================================================
    /**
     * BUG: _lzReceive fires the sendDepositShares/refundDeposit callback ONLY
     * when info.initiator == factory.vaultComposer(info.vault).  After an
     * upgrade, this guard fails silently for any GUID whose CallInfo.initiator
     * is the old composer.  The GUID entry is deleted but the old composer's
     * _pendingDeposits[guid] is never cleaned up.
     */
    function test_C09_03_lzReceive_skips_sendDepositShares_after_composer_upgrade() public {
        // ── Deploy standalone LzAdapter infrastructure ──────────────────
        MockEndpointC09         endpoint   = new MockEndpointC09();
        MockVaultsFactoryC09    lzFactory  = new MockVaultsFactoryC09();
        MockVaultC09            mockVault  = new MockVaultC09();
        MockLzComposerTrackerC09 oldComposer = new MockLzComposerTrackerC09();
        MockLzComposerTrackerC09 newComposer = new MockLzComposerTrackerC09();

        address owner_ = address(0xA0);
        vm.prank(owner_);
        LzAdapterHarnessC09 lzAdapter = new LzAdapterHarnessC09(
            address(endpoint),
            owner_,
            uint32(1),          // readChannel
            address(lzFactory),
            address(0xDEAD)     // vaultsRegistry (unused in this path)
        );

        lzFactory.setVault(address(mockVault), true);
        lzFactory.setVaultComposer(address(mockVault), address(oldComposer));

        bytes32 guid = keccak256("guid-c09-03");

        // Plant CallInfo: this GUID was initiated by the OLD composer
        lzAdapter.setCallInfo(guid, address(mockVault), address(oldComposer));

        // ── Owner upgrades to newComposer ────────────────────────────────
        lzFactory.setVaultComposer(address(mockVault), address(newComposer));
        assertEq(lzFactory.vaultComposer(address(mockVault)), address(newComposer),
            "factory should now point to newComposer");

        // ── LZ response arrives for the in-flight GUID ───────────────────
        Origin memory origin = Origin({
            srcEid: 1,
            sender: bytes32(uint256(uint160(address(lzAdapter)))),
            nonce: 1
        });
        // readSuccess=true, sum=0 -- executeRequest on MockVaultC09 is a no-op
        bytes memory message = abi.encode(uint256(0), true);
        lzAdapter.exposed_lzReceive(origin, guid, message, address(0), "");

        // BUG: neither oldComposer nor newComposer received a callback
        assertEq(oldComposer.sendDepositSharesCalls(guid), 0,
            "BUG: oldComposer.sendDepositShares was not called (correct -- it's now stale)");
        assertEq(newComposer.sendDepositSharesCalls(guid), 0,
            "BUG: newComposer.sendDepositShares was also not called -- callback was skipped entirely");
        assertEq(oldComposer.refundDepositCalls(guid), 0,
            "BUG: oldComposer.refundDeposit was not called -- _pendingDeposits[guid] is orphaned");
    }

    // ======================================================================
    // C09-FIX  setVaultComposer reverts when old composer has pending native
    // ======================================================================
    /**
     * FIX verification: _setVaultComposer should check
     * IMoreVaultsComposer(oldComposer).totalNativePending() > 0 and revert
     * before overwriting the pointer.
     *
     * Without the fix applied: setVaultComposer silently overwrites the
     * pointer → factoryHarness.vaultComposer(vaultAddr) == newComposer_
     * → assertTrue(reverted) FAILS.
     *
     * With the fix applied: the call reverts → reverted == true
     * → pointer stays at oldComposer → both assertions PASS.
     */
    function test_C09_FIX_setVaultComposer_reverts_when_old_composer_has_pending_native() public {
        // Deploy a minimal mock endpoint.  VaultsFactory inherits OAppUpgradeable
        // which calls endpoint.setDelegate during initialize().
        MockEndpointC09 endpoint = new MockEndpointC09();

        address admin = address(0xAD);
        vm.prank(admin);
        VaultsFactoryHarness factoryHarness = new VaultsFactoryHarness(address(endpoint));

        // initialize() sets the Ownable owner and wires OApp.
        // All non-zero placeholder addresses satisfy ZeroAddress checks.
        address dummyAddr = address(0xD001);
        vm.prank(admin);
        factoryHarness.initialize(
            admin,         // _owner
            dummyAddr,     // _registry
            dummyAddr,     // _diamondCutFacet
            dummyAddr,     // _accessControlFacet
            dummyAddr,     // _wrappedNative
            uint32(1),     // _localEid (must be non-zero)
            0,             // _maxFinalizationTime
            address(0),    // _lzAdapter  (not checked for zero in initialize)
            dummyAddr,     // _composerImplementation
            dummyAddr      // _oftAdapterFactory
        );

        // Deploy old composer with non-zero pending ETH
        MockComposerWithPendingC09 oldComposerPending = new MockComposerWithPendingC09();
        oldComposerPending.setTotalNativePending(0.5 ether);

        MockMoreVaultsComposer newComposer_ = new MockMoreVaultsComposer();

        address vaultAddr = address(0xBEEF09);

        // First set: no existing composer → should succeed unconditionally
        vm.prank(admin);
        factoryHarness.setVaultComposer(vaultAddr, address(oldComposerPending));
        assertEq(factoryHarness.vaultComposer(vaultAddr), address(oldComposerPending),
            "old composer should be set");

        // Upgrade attempt: old composer has pending native
        // FIX: this must revert before overwriting the pointer.
        // Without fix: the call silently succeeds → pointer moves to newComposer_
        bool reverted = false;
        vm.prank(admin);
        try factoryHarness.setVaultComposer(vaultAddr, address(newComposer_)) {
            // Upgrade succeeded -- BUG: pointer moved while deposits are pending
        } catch {
            reverted = true;
        }

        assertTrue(reverted,
            "FIX: setVaultComposer must revert when old composer has pending native");
        assertEq(factoryHarness.vaultComposer(vaultAddr), address(oldComposerPending),
            "FIX: pointer must NOT advance while old composer has pending deposits");
    }
}
