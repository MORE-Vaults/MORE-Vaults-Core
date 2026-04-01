// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {StakingFacet} from "../src/facets/StakingFacet.sol";
import {IStakingFacet} from "../src/interfaces/facets/IStakingFacet.sol";
import {MoreVaultsLib} from "../src/libraries/MoreVaultsLib.sol";
import {StakingStorage} from "../src/storage/StakingStorage.sol";
import {MoreVaultsStorageHelper} from "./helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMoreVaultsEscrow} from "./mocks/MockMoreVaultsEscrow.sol";
import {IMoreVaultsRegistry} from "../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../src/interfaces/IOracleRegistry.sol";
import {IVaultsFactory} from "../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title StakingFacetAccounting
 * @notice Integration tests proving that StakingFacet hooks into totalAssets().
 *
 * How the test wires the accounting hook
 * ---------------------------------------
 * The real vault's `_accountFacets` loop:
 *   1. Reads `ds.facetsForAccounting[i]` — a bytes32 value whose top 4 bytes
 *      are the selector left-aligned (same encoding bytes32(bytes4)).
 *   2. Stores that word at `_freePtr` in memory.
 *   3. Issues `staticcall(gas(), address(), _freePtr, 4, retOffset, 0x40)`.
 *      — `address()` here is the vault/facet contract itself.
 *   4. Decodes `(uint256, bool)` from `retOffset`.
 *
 * So the vault calls itself with the 4-byte selector. The Diamond's fallback
 * routes that call to whatever facet registered that selector in
 * `ds.selectorToFacetAndPosition`. We therefore need two things:
 *
 *   A. `ds.facetsForAccounting` must contain `bytes32(IStakingFacet.stakingTotalAssets.selector)`.
 *   B. `ds.selectorToFacetAndPosition[stakingTotalAssets.selector]` must
 *      point to the StakingFacet address (so the Diamond routes the call).
 *
 * We set both via forge `vm.store` through MoreVaultsStorageHelper and a
 * small helper below.
 *
 * How the StakingFacet state is set
 * -----------------------------------
 * The StakingFacet uses its own Diamond storage slot (StakingStorage.POSITION).
 * We write `totalStakedInCadence` there directly with `vm.store`.
 *
 * The vault we use is the VaultFacet contract deployed directly (not through
 * a full Diamond proxy). The VaultFacet is itself a Diamond storage consumer —
 * its `totalAssets()` reads `ds.availableAssets` and `ds.facetsForAccounting`
 * directly from storage at the MORE_VAULTS_STORAGE_POSITION. When we deploy
 * it as a plain contract, `address(this)` in the `staticcall` inside
 * `_accountFacets` refers to the VaultFacet contract. The Diamond routing
 * fallback doesn't exist there, so we cannot use a real Diamond cut.
 *
 * Instead we deploy a `StakingFacetTestHarness` that:
 *   - Extends VaultFacet (inherits all storage + totalAssets logic).
 *   - Adds a fallback that routes unknown selectors to the StakingFacet.
 *   - This mimics what the Diamond proxy does.
 */
contract StakingFacetAccounting is Test {
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Addresses
    // -------------------------------------------------------------------------
    address public owner     = address(0x1111);
    address public coa       = address(0x2222);  // authorizedCOA (bridge)
    address public feeRecip  = address(0x3333);
    address public registry  = address(0x4444);
    address public factory   = address(0x5555);
    address public oracleReg = address(0x6666);

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------
    StakingVaultHarness public vault;
    StakingFacet         public stakingFacet;
    MockERC20            public asset;
    MockMoreVaultsEscrow public escrow;

    // selector of stakingTotalAssets()
    bytes4  constant STAKING_ACCOUNTING_SELECTOR = IStakingFacet.stakingTotalAssets.selector;
    bytes32 constant STAKING_ACCOUNTING_SELECTOR_B32 = bytes32(IStakingFacet.stakingTotalAssets.selector);

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------
    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        // Deploy mock asset (the vault's underlying token, e.g. WFLOW)
        asset = new MockERC20("Wrapped Flow", "WFLOW");

        // Deploy mock escrow
        escrow = new MockMoreVaultsEscrow();

        // Deploy the harness (inherits VaultFacet + routes staking selector)
        stakingFacet = new StakingFacet();
        vault = new StakingVaultHarness(address(stakingFacet));

        escrow.setUnderlyingToken(address(vault), address(asset));

        // --- MoreVaultsStorage: access control ---
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(vault), registry);
        MoreVaultsStorageHelper.setOwner(address(vault), owner);
        MoreVaultsStorageHelper.setFactory(address(vault), factory);

        // --- Mock registry / oracle plumbing ---
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleReg));
        vm.mockCall(
            oracleReg,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(asset)),
            abi.encode(address(0x7000), uint96(1000))
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.escrow.selector), abi.encode(address(escrow)));
        vm.mockCall(
            factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), address(vault)),
            abi.encode(false)
        );

        // --- Initialize VaultFacet (sets ERC4626 storage, adds asset to availableAssets) ---
        bytes memory initData = abi.encode(
            "moreFLOW",
            "moreFLOW",
            address(asset),
            feeRecip,
            uint96(0),      // zero fee for simplicity
            type(uint256).max
        );
        VaultFacet(address(vault)).initialize(initData);

        // --- Mark vault as hub (needed by deposit path) ---
        MoreVaultsStorageHelper.setIsHub(address(vault), true);

        // --- Register StakingFacet's accounting selector ---
        // A. Push selector into facetsForAccounting array
        _pushFacetsForAccounting(address(vault), STAKING_ACCOUNTING_SELECTOR_B32);

        // B. Register selector → StakingFacet in selectorToFacetAndPosition
        //    (so the harness fallback can route it)
        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(
            address(vault),
            STAKING_ACCOUNTING_SELECTOR,
            address(stakingFacet),
            0
        );

        // --- Initialize StakingFacet state (set authorizedCOA) ---
        // StakingFacet.initialize writes to its own Diamond storage slot.
        // We call it directly on the vault harness (which delegates to stakingFacet).
        // But initialize uses initializerFacet — call it on the stakingFacet directly
        // against the vault's storage by making vault call stakingFacet.initialize.
        // Simplest: manually write StakingStorage via vm.store.
        _setStakingStorage(address(vault), 0, coa, 1e18);
    }

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    /**
     * @notice With no staked balance, totalAssets equals the ERC20 token balance.
     */
    function test_totalAssets_WithZeroStaked_ReturnsOnlyTokenBalance() public {
        // Mint 100 WFLOW to the vault (simulates a deposit)
        asset.mint(address(vault), 100 ether);

        uint256 ta = VaultFacet(address(vault)).totalAssets();
        // Should equal exactly 100 ether (the WFLOW balance)
        assertEq(ta, 100 ether, "totalAssets should equal token balance when nothing staked");
    }

    /**
     * @notice StakingFacet's accounting adds totalStakedInCadence to totalAssets.
     */
    function test_totalAssets_IncludesStakedBalance() public {
        // Give vault 50 WFLOW locally
        asset.mint(address(vault), 50 ether);

        // Simulate 200 FLOW staked in Cadence
        _setTotalStakedInCadence(address(vault), 200 ether);

        uint256 ta = VaultFacet(address(vault)).totalAssets();
        assertEq(ta, 250 ether, "totalAssets should be token balance + staked balance");
    }

    /**
     * @notice Epoch reward update: COA increases totalStakedInCadence.
     *         totalAssets must increase. Share price must increase.
     */
    function test_epochReward_IncreasesSharePrice() public {
        // Deposit 100 WFLOW → mint shares
        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), 100 ether);
        MoreVaultsStorageHelper.setDepositWhitelist(address(vault), address(this), type(uint256).max);

        // Mock factory spokes call needed by deposit
        uint32[] memory eids    = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(address(0)));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector, address(vault)),
            abi.encode(address(0), uint96(0))
        );

        VaultFacet(address(vault)).deposit(100 ether, address(this));

        uint256 sharesBefore  = IERC20(address(vault)).totalSupply();
        uint256 assetsBefore  = VaultFacet(address(vault)).totalAssets();
        uint256 pricePerShare = assetsBefore.mulDiv(1e18, sharesBefore);

        console.log("Before reward - totalAssets:", assetsBefore);
        console.log("Before reward - totalSupply:", sharesBefore);
        console.log("Before reward - price/share:", pricePerShare);

        // Simulate COA epoch reward: 100 FLOW → 110 FLOW (10% yield)
        _setTotalStakedInCadence(address(vault), 10 ether); // 10 FLOW staked
        // totalAssets was 100, now stake adds 10 → 110

        uint256 ta2 = VaultFacet(address(vault)).totalAssets();
        uint256 shares2 = IERC20(address(vault)).totalSupply();
        uint256 pricePerShare2 = ta2.mulDiv(1e18, shares2);

        console.log("After  reward - totalAssets:", ta2);
        console.log("After  reward - totalSupply:", shares2);
        console.log("After  reward - price/share:", pricePerShare2);

        assertGt(ta2, assetsBefore, "totalAssets should increase after reward");
        assertGt(pricePerShare2, pricePerShare, "share price should increase after reward");
        assertEq(shares2, sharesBefore, "totalSupply must not change");
    }

    /**
     * @notice pendingDeposits: native FLOW queued but not yet bridged.
     *         The FLOW sits as selfbalance(). stakingTotalAssets() does NOT
     *         include it. No double-counting occurs.
     *
     * For this test we do NOT set wrappedNative, so selfbalance() is not
     * counted by _accountAvailableAssets. We verify that pendingDepositsLocked
     * in StakingStorage changes, but totalAssets does not double-count.
     */
    function test_noPendingDeposit_NoDoubleCount() public {
        asset.mint(address(vault), 100 ether);

        // 50 FLOW staked in Cadence
        _setTotalStakedInCadence(address(vault), 50 ether);

        uint256 ta = VaultFacet(address(vault)).totalAssets();
        // 100 WFLOW + 50 staked = 150
        assertEq(ta, 150 ether, "should be 100 token + 50 staked");

        // Simulate enqueueDeposit of 30 FLOW (COA hasn't bridged yet)
        // totalStakedInCadence is still 50 — no double count
        _setPendingDepositsLocked(address(vault), 30 ether);

        uint256 ta2 = VaultFacet(address(vault)).totalAssets();
        // Still 150 — stakingTotalAssets only returns totalStakedInCadence (50)
        assertEq(ta2, 150 ether, "pending deposits must NOT appear in totalAssets twice");
    }

    /**
     * @notice bridgeDeposits: COA bridges queued FLOW. net totalAssets = 0 change.
     *         Before: 30 FLOW in selfbalance (counted by availableAssets), 50 staked.
     *         After:  30 FLOW gone from selfbalance, 80 staked.
     *         We use wrappedNative = asset address to make selfbalance count.
     */
    function test_bridgeDeposits_NetZeroEffect() public {
        // Set wrappedNative so selfbalance is included in accountAvailableAssets
        MoreVaultsStorageHelper.setWrappedNative(address(vault), address(asset));

        asset.mint(address(vault), 100 ether);       // 100 WFLOW ERC20 balance
        // Native FLOW on vault (selfbalance): give it 30 ether
        vm.deal(address(vault), 30 ether);

        // 50 FLOW staked in Cadence
        _setTotalStakedInCadence(address(vault), 50 ether);

        // Before bridge: 100 WFLOW + 30 native (selfbalance) + 50 staked = 180
        uint256 taBefore = VaultFacet(address(vault)).totalAssets();
        console.log("Before bridge totalAssets:", taBefore);

        // COA bridges the 30 FLOW: native FLOW leaves, staked increases by 30
        // Simulate: drain native balance, bump staked
        vm.deal(address(vault), 0);                  // FLOW left EVM
        _setTotalStakedInCadence(address(vault), 80 ether); // 50 + 30

        uint256 taAfter = VaultFacet(address(vault)).totalAssets();
        console.log("After  bridge totalAssets:", taAfter);

        assertEq(taBefore, taAfter, "bridging deposits should have zero net effect on totalAssets");
    }

    /**
     * @notice settleWithdrawal: staked FLOW returns to EVM after unbonding.
     *         totalStakedInCadence drops by amount; selfbalance rises by same.
     *         Net totalAssets = 0 change.
     */
    function test_settleWithdrawal_NetZeroEffect() public {
        MoreVaultsStorageHelper.setWrappedNative(address(vault), address(asset));

        asset.mint(address(vault), 100 ether);
        _setTotalStakedInCadence(address(vault), 80 ether);

        // totalAssets: 100 WFLOW + 80 staked = 180
        uint256 taBefore = VaultFacet(address(vault)).totalAssets();
        console.log("Before settle totalAssets:", taBefore);

        // Simulate: 20 FLOW returns from Cadence unbonding
        vm.deal(address(vault), 20 ether);           // FLOW arrives on EVM
        _setTotalStakedInCadence(address(vault), 60 ether); // 80 - 20

        uint256 taAfter = VaultFacet(address(vault)).totalAssets();
        console.log("After  settle totalAssets:", taAfter);

        assertEq(taBefore, taAfter, "settling withdrawal should have zero net effect on totalAssets");
    }

    /**
     * @notice stakingTotalAssets() always returns isPositive = true.
     */
    function test_stakingTotalAssets_AlwaysPositive() public {
        _setTotalStakedInCadence(address(vault), 999 ether);
        (uint256 amount, bool isPositive) = IStakingFacet(address(vault)).stakingTotalAssets();
        assertEq(amount, 999 ether);
        assertTrue(isPositive, "staked balance is always a positive asset");
    }

    // -------------------------------------------------------------------------
    // Storage manipulation helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Push one entry into ds.facetsForAccounting (a bytes32 dynamic array).
     *      MoreVaultsStorageHelper.setFacetsForAccounting expects address[] which
     *      is wrong for our bytes32 selectors, so we write directly.
     */
    function _pushFacetsForAccounting(address target, bytes32 selector) internal {
        uint256 offset = MoreVaultsStorageHelper.FACETS_FOR_ACCOUNTING;
        uint256 currentLen = MoreVaultsStorageHelper.getArrayLength(target, offset);
        // set new length
        MoreVaultsStorageHelper.setArrayLength(target, offset, currentLen + 1);
        // set element at index currentLen
        MoreVaultsStorageHelper.setArrayElement(target, offset, currentLen, selector);
    }

    /**
     * @dev Write StakingStorage.Layout.totalStakedInCadence and authorizedCOA.
     *      StakingStorage slot = keccak256("MoreVaults.storage.StakingFacet.v1").
     *      Layout offsets: slot+0 = totalStakedInCadence, slot+4 = authorizedCOA.
     *      (pendingRewards=1, exchangeRate=2, pendingDepositsLocked=3, withdrawalPending=4, authorizedCOA=5)
     */
    function _setStakingStorage(address target, uint256 totalStaked, address _coa, uint256 exchangeRate) internal {
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        vm.store(target, bytes32(uint256(baseSlot) + 0), bytes32(totalStaked));       // totalStakedInCadence
        vm.store(target, bytes32(uint256(baseSlot) + 2), bytes32(exchangeRate));      // exchangeRate
        vm.store(target, bytes32(uint256(baseSlot) + 5), bytes32(uint256(uint160(_coa)))); // authorizedCOA
    }

    function _setTotalStakedInCadence(address target, uint256 amount) internal {
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        vm.store(target, bytes32(uint256(baseSlot) + 0), bytes32(amount));
    }

    function _setPendingDepositsLocked(address target, uint256 amount) internal {
        bytes32 baseSlot = StakingStorage.STAKING_STORAGE_POSITION;
        vm.store(target, bytes32(uint256(baseSlot) + 3), bytes32(amount));
    }
}

// =============================================================================
// Harness: VaultFacet + Diamond-routing for StakingFacet
// =============================================================================

/**
 * @title StakingVaultHarness
 * @notice Inherits VaultFacet so all its storage + totalAssets() are available.
 *         Overrides fallback to route `stakingTotalAssets` selector to the
 *         deployed StakingFacet — mimicking what a Diamond proxy does.
 *
 * The fallback is needed because `_accountFacets` calls
 *   `staticcall(gas(), address(), _freePtr, 4, retOffset, 0x40)`
 * where `address()` is `address(this)`. Without routing, the call would hit
 * VaultFacet's own fallback (from ERC4626Upgradeable) and revert.
 */
contract StakingVaultHarness is VaultFacet {
    address public immutable STAKING_FACET;

    bytes4 constant STAKING_SELECTOR = IStakingFacet.stakingTotalAssets.selector;

    constructor(address _stakingFacet) {
        STAKING_FACET = _stakingFacet;
    }

    fallback() external payable {
        bytes4 sel;
        assembly {
            sel := calldataload(0)
        }
        if (sel == STAKING_SELECTOR) {
            // Delegate to the StakingFacet — it reads from this contract's
            // storage via delegatecall, which is exactly what a Diamond does.
            address facet = STAKING_FACET;
            assembly {
                calldatacopy(0, 0, calldatasize())
                let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                switch result
                case 0 { revert(0, returndatasize()) }
                default { return(0, returndatasize()) }
            }
        }
        // For any other unknown selector, revert gracefully.
        revert("StakingVaultHarness: unknown selector");
    }

    receive() external payable {}
}
