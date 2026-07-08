// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StakingFacet} from "../../../src/facets/StakingFacet.sol";
import {BaseFacetInitializer} from "../../../src/facets/BaseFacetInitializer.sol";
import {IStakingFacet} from "../../../src/interfaces/facets/IStakingFacet.sol";
import {IProtocolAdapter} from "../../../src/interfaces/IProtocolAdapter.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {StakingFacetStorage} from "../../../src/libraries/StakingFacetStorage.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {MockProtocolAdapter} from "../../mocks/MockProtocolAdapter.sol";
import {MockLST} from "../../mocks/MockLST.sol";
import {HarvestRevertAdapter} from "../../mocks/HarvestRevertAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockRegistry {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address protocol, bool status) external {
        whitelisted[protocol] = status;
    }

    function isWhitelisted(address protocol) external view returns (bool) {
        return whitelisted[protocol];
    }
}

contract StakeRevertAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    address public immutable depositToken;
    address public immutable receiptToken;

    constructor(address _depositToken, address _receiptToken) {
        depositToken = _depositToken;
        receiptToken = _receiptToken;
    }

    function getStakedReceipts(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getPendingUnstake(address) external pure returns (uint256) {
        return 0;
    }

    function getUnstakeableReceipts(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getAccountingDepositValue(address, bool) external pure returns (uint256) {
        return 0;
    }

    function stake(uint256, bytes calldata) external pure returns (uint256) {
        revert("stake failed");
    }

    function requestUnstake(uint256, bytes calldata) external pure returns (bytes32, uint256) {
        return (bytes32(0), 0);
    }

    function finalizeUnstake(bytes32, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address, bytes32) external pure returns (bool) {
        return false;
    }

    function isWithdrawalCompleted(address, bytes32) external pure returns (bool) {
        return false;
    }

    function getWithdrawalClaimableAt(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "StakeRevertAdapter";
    }
}

contract StakeEmptyRevertAdapter is IProtocolAdapter {
    address public immutable depositToken;
    address public immutable receiptToken;

    constructor(address _depositToken, address _receiptToken) {
        depositToken = _depositToken;
        receiptToken = _receiptToken;
    }

    function getStakedReceipts(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getPendingUnstake(address) external pure returns (uint256) {
        return 0;
    }

    function getUnstakeableReceipts(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getAccountingDepositValue(address, bool) external pure returns (uint256) {
        return 0;
    }

    function stake(uint256, bytes calldata) external pure returns (uint256) {
        revert();
    }

    function requestUnstake(uint256, bytes calldata) external pure returns (bytes32, uint256) {
        return (bytes32(0), 0);
    }

    function finalizeUnstake(bytes32, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address, bytes32) external pure returns (bool) {
        return false;
    }

    function isWithdrawalCompleted(address, bytes32) external pure returns (bool) {
        return false;
    }

    function getWithdrawalClaimableAt(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "StakeEmptyRevertAdapter";
    }
}

contract InvalidTokensAdapter is IProtocolAdapter {
    function depositToken() external pure returns (address) {
        return address(0);
    }

    function receiptToken() external pure returns (address) {
        return address(0);
    }

    function getStakedReceipts(address) external pure returns (uint256) {
        return 0;
    }

    function getPendingUnstake(address) external pure returns (uint256) {
        return 0;
    }

    function getUnstakeableReceipts(address) external pure returns (uint256) {
        return 0;
    }

    function getAccountingDepositValue(address, bool) external pure returns (uint256) {
        return 0;
    }

    function stake(uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function requestUnstake(uint256, bytes calldata) external pure returns (bytes32, uint256) {
        return (bytes32(0), 0);
    }

    function finalizeUnstake(bytes32, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address, bytes32) external pure returns (bool) {
        return false;
    }

    function isWithdrawalCompleted(address, bytes32) external pure returns (bool) {
        return false;
    }

    function getWithdrawalClaimableAt(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "InvalidTokensAdapter";
    }
}

contract UnstakeBlockingAdapter is MockProtocolAdapter {
    bool public blocked;

    constructor(address lstPool) MockProtocolAdapter(lstPool) {}

    function setBlocked(bool status) external {
        blocked = status;
    }

    function isUnstakeBlocked(address) external view override returns (bool) {
        return blocked;
    }
}

/// @dev Returns zero actualReceipts from requestUnstake.
contract ZeroUnstakeReceiptsAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    address public immutable lstPool;

    constructor(address _lstPool) {
        lstPool = _lstPool;
    }

    function depositToken() external view returns (address) {
        return address(MockLST(lstPool).depositToken());
    }

    function receiptToken() external view returns (address) {
        return address(MockLST(lstPool).receiptToken());
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return IERC20(address(MockLST(lstPool).receiptToken())).balanceOf(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        return MockLST(lstPool).pendingUnstakeByVault(vault);
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        return IERC20(address(MockLST(lstPool).receiptToken())).balanceOf(vault);
    }

    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        MockLST lst = MockLST(lstPool);
        uint256 pending = lst.pendingUnstakeByVault(vault);
        uint256 walletReceipts =
            receiptIsAvailableAsset ? 0 : IERC20(address(lst.receiptToken())).balanceOf(vault);
        return ((walletReceipts + pending) * lst.exchangeRate()) / 1e18;
    }

    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        MockLST lst = MockLST(lstPool);
        address deposit = address(lst.depositToken());
        IERC20(deposit).forceApprove(lstPool, amount);
        receipts = lst.stake(amount);
        IERC20(deposit).forceApprove(lstPool, 0);
    }

    function requestUnstake(uint256 receipts, bytes calldata)
        external
        returns (bytes32 requestId, uint256 actualReceipts)
    {
        MockLST lst = MockLST(lstPool);
        address receipt = address(lst.receiptToken());
        IERC20(receipt).forceApprove(lstPool, receipts);
        requestId = lst.requestUnstake(receipts);
        IERC20(receipt).forceApprove(lstPool, 0);
        actualReceipts = 0;
    }

    function finalizeUnstake(bytes32 requestId, bytes calldata) external returns (uint256 amount) {
        MockLST lst = MockLST(lstPool);
        if (lst.isCompleted(requestId)) {
            return 0;
        }
        return lst.claim(requestId, address(this));
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isClaimable(requestId);
    }

    function isWithdrawalCompleted(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isCompleted(requestId);
    }

    function getWithdrawalClaimableAt(address, bytes32 requestId) external view returns (uint256) {
        return MockLST(lstPool).getWithdrawalClaimableAt(requestId);
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "ZeroUnstakeReceiptsAdapter";
    }
}

/// @dev Returns more actualReceipts than requested from requestUnstake.
contract OverUnstakeReceiptsAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    address public immutable lstPool;

    constructor(address _lstPool) {
        lstPool = _lstPool;
    }

    function depositToken() external view returns (address) {
        return address(MockLST(lstPool).depositToken());
    }

    function receiptToken() external view returns (address) {
        return address(MockLST(lstPool).receiptToken());
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return IERC20(address(MockLST(lstPool).receiptToken())).balanceOf(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        return MockLST(lstPool).pendingUnstakeByVault(vault);
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        return IERC20(address(MockLST(lstPool).receiptToken())).balanceOf(vault);
    }

    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        MockLST lst = MockLST(lstPool);
        uint256 pending = lst.pendingUnstakeByVault(vault);
        uint256 walletReceipts =
            receiptIsAvailableAsset ? 0 : IERC20(address(lst.receiptToken())).balanceOf(vault);
        return ((walletReceipts + pending) * lst.exchangeRate()) / 1e18;
    }

    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        MockLST lst = MockLST(lstPool);
        address deposit = address(lst.depositToken());
        IERC20(deposit).forceApprove(lstPool, amount);
        receipts = lst.stake(amount);
        IERC20(deposit).forceApprove(lstPool, 0);
    }

    function requestUnstake(uint256 receipts, bytes calldata)
        external
        returns (bytes32 requestId, uint256 actualReceipts)
    {
        MockLST lst = MockLST(lstPool);
        address receipt = address(lst.receiptToken());
        IERC20(receipt).forceApprove(lstPool, receipts);
        requestId = lst.requestUnstake(receipts);
        IERC20(receipt).forceApprove(lstPool, 0);
        actualReceipts = receipts + 1;
    }

    function finalizeUnstake(bytes32 requestId, bytes calldata) external returns (uint256 amount) {
        MockLST lst = MockLST(lstPool);
        if (lst.isCompleted(requestId)) {
            return 0;
        }
        return lst.claim(requestId, address(this));
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isClaimable(requestId);
    }

    function isWithdrawalCompleted(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isCompleted(requestId);
    }

    function getWithdrawalClaimableAt(address, bytes32 requestId) external view returns (uint256) {
        return MockLST(lstPool).getWithdrawalClaimableAt(requestId);
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "OverUnstakeReceiptsAdapter";
    }
}

/// @dev Simulates async stake pending in deposit-token accounting (e.g. FLOW_RECEIPT) with no wallet receipts left.
contract MockAsyncStakePool {
    mapping(address => uint256) public walletReceipts;
    mapping(address => uint256) public pendingUnstakeReceipts;
    mapping(address => uint256) public pendingStakeAccounting;

    function configure(address vault, uint256 wallet, uint256 pendingStakeAccounting_) external {
        walletReceipts[vault] = wallet;
        pendingStakeAccounting[vault] = pendingStakeAccounting_;
    }

    function requestUnstake(address vault, uint256 receipts) external {
        walletReceipts[vault] -= receipts;
        pendingUnstakeReceipts[vault] += receipts;
    }

    function finalize(address vault) external returns (uint256 amount) {
        amount = pendingUnstakeReceipts[vault];
        pendingUnstakeReceipts[vault] = 0;
    }
}

contract AsyncPendingStakeAdapter is IProtocolAdapter {
    address public immutable pool;
    address public immutable depositToken;
    address public immutable receiptToken;

    constructor(address _pool, address _depositToken, address _receiptToken) {
        pool = _pool;
        depositToken = _depositToken;
        receiptToken = _receiptToken;
    }

    function getStakedReceipts(address vault) external view returns (uint256) {
        return MockAsyncStakePool(pool).walletReceipts(vault);
    }

    function getPendingUnstake(address vault) external view returns (uint256) {
        return MockAsyncStakePool(pool).pendingUnstakeReceipts(vault);
    }

    function getUnstakeableReceipts(address vault) external view returns (uint256) {
        return MockAsyncStakePool(pool).walletReceipts(vault);
    }

    function getAccountingDepositValue(address vault, bool receiptIsAvailableAsset)
        external
        view
        returns (uint256 depositTokenAmount)
    {
        MockAsyncStakePool stakePool = MockAsyncStakePool(pool);
        depositTokenAmount = stakePool.pendingStakeAccounting(vault);
        if (!receiptIsAvailableAsset) {
            depositTokenAmount += stakePool.walletReceipts(vault);
        }
    }

    function stake(uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function requestUnstake(uint256 receipts, bytes calldata) external returns (bytes32, uint256) {
        MockAsyncStakePool(pool).requestUnstake(address(this), receipts);
        return (bytes32(uint256(1)), receipts);
    }

    function finalizeUnstake(bytes32, bytes calldata) external returns (uint256 amount) {
        return MockAsyncStakePool(pool).finalize(address(this));
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure {}

    function isWithdrawalClaimable(address vault, bytes32) external view returns (bool) {
        return MockAsyncStakePool(pool).pendingUnstakeReceipts(vault) > 0;
    }

    function isWithdrawalCompleted(address vault, bytes32) external view returns (bool) {
        return MockAsyncStakePool(pool).pendingUnstakeReceipts(vault) == 0;
    }

    function getWithdrawalClaimableAt(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function isUnstakeBlocked(address) external pure returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "AsyncPendingStakeAdapter";
    }
}

contract StakingFacetTest is Test {
    StakingFacet public facet;
    MockRegistry public registry;
    MockERC20 public depositToken;
    MockERC20 public receiptToken;
    MockLST public lst;
    MockProtocolAdapter public adapter;
    HarvestRevertAdapter public harvestRevertAdapter;
    StakeRevertAdapter public stakeRevertAdapter;
    StakeEmptyRevertAdapter public stakeEmptyRevertAdapter;
    InvalidTokensAdapter public invalidTokensAdapter;
    UnstakeBlockingAdapter public blockingAdapter;
    ZeroUnstakeReceiptsAdapter public zeroUnstakeReceiptsAdapter;
    OverUnstakeReceiptsAdapter public overUnstakeReceiptsAdapter;
    MockAsyncStakePool public asyncStakePool;
    AsyncPendingStakeAdapter public asyncPendingStakeAdapter;

    address public owner = address(0x1);
    address public curator = address(0x2);
    address public unauthorized = address(0x4);

    bytes32 internal constant STAKING_FACET_ID = keccak256("StakingFacet");
    uint256 internal constant EXCHANGE_RATE = 1e18;
    uint256 internal constant WITHDRAWAL_DELAY = 1 days;
    uint256 internal constant STAKE_AMOUNT = 100e18;

    function setUp() public {
        facet = new StakingFacet();
        registry = new MockRegistry();
        depositToken = new MockERC20("Deposit", "DEP");
        receiptToken = new MockERC20("Receipt", "REC");
        lst = new MockLST(address(depositToken), address(receiptToken), EXCHANGE_RATE, WITHDRAWAL_DELAY);
        adapter = new MockProtocolAdapter(address(lst));
        harvestRevertAdapter = new HarvestRevertAdapter(address(lst));
        stakeRevertAdapter = new StakeRevertAdapter(address(depositToken), address(receiptToken));
        stakeEmptyRevertAdapter = new StakeEmptyRevertAdapter(address(depositToken), address(receiptToken));
        invalidTokensAdapter = new InvalidTokensAdapter();
        blockingAdapter = new UnstakeBlockingAdapter(address(lst));
        zeroUnstakeReceiptsAdapter = new ZeroUnstakeReceiptsAdapter(address(lst));
        overUnstakeReceiptsAdapter = new OverUnstakeReceiptsAdapter(address(lst));
        asyncStakePool = new MockAsyncStakePool();
        asyncPendingStakeAdapter = new AsyncPendingStakeAdapter(
            address(asyncStakePool), address(depositToken), address(receiptToken)
        );
        asyncStakePool.configure(address(facet), 11_000, 100e18);

        MoreVaultsStorageHelper.setOwner(address(facet), owner);
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(registry));
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(depositToken));

        address[] memory availableAssets = new address[](1);
        availableAssets[0] = address(depositToken);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);

        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(
            address(facet), IStakingFacet.stake.selector, address(facet), 0
        );

        _whitelistAdapter(address(adapter));
        _whitelistAdapter(address(harvestRevertAdapter));
        _whitelistAdapter(address(stakeRevertAdapter));
        _whitelistAdapter(address(stakeEmptyRevertAdapter));
        _whitelistAdapter(address(invalidTokensAdapter));
        _whitelistAdapter(address(blockingAdapter));
        _whitelistAdapter(address(zeroUnstakeReceiptsAdapter));
        _whitelistAdapter(address(overUnstakeReceiptsAdapter));
        _whitelistAdapter(address(asyncPendingStakeAdapter));

        depositToken.mint(address(facet), 1_000e18);
        depositToken.mint(address(lst), 1_000e18);
        receiptToken.mint(address(lst), 1_000e18);

        bytes32 facetSelector = bytes32(bytes4(IStakingFacet.accountingStakingFacet.selector));
        facet.initialize(abi.encode(facetSelector));
    }

    function _whitelistAdapter(address adapterAddress) internal {
        registry.setWhitelisted(adapterAddress, true);
    }

    function _stake(address adapterAddress, uint256 amount) internal returns (uint256 receipts) {
        vm.prank(address(facet));
        receipts = facet.stake(adapterAddress, amount, bytes(""));
    }

    function _requestUnstake(address adapterAddress, uint256 receipts) internal returns (bytes32 requestId) {
        vm.prank(address(facet));
        requestId = facet.requestUnstake(adapterAddress, receipts, bytes(""));
    }

    function _finalizeUnstake(bytes32 requestId) internal returns (uint256 amount) {
        vm.prank(address(facet));
        amount = facet.finalizeUnstake(requestId, bytes(""));
    }

    function _vaultExternalAssetCount(uint8 tokenType) internal view returns (uint256) {
        bytes32 mappingSlot = keccak256(
            abi.encode(
                uint256(tokenType),
                bytes32(uint256(MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION) + MoreVaultsStorageHelper.VAULT_EXTERNAL_ASSETS)
            )
        );
        return uint256(vm.load(address(facet), mappingSlot));
    }

    function test_facetName_shouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "StakingFacet");
    }

    function test_facetVersion_shouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0");
    }

    function test_initialize_shouldConfigureStorage() public view {
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IStakingFacet).interfaceId),
            "Interface should be supported"
        );

        bytes32[] memory facetsForAccounting = MoreVaultsStorageHelper.getFacetsForAccounting(address(facet));
        assertEq(facetsForAccounting.length, 1);
        assertEq(
            facetsForAccounting[0],
            bytes32(bytes4(IStakingFacet.accountingStakingFacet.selector)),
            "Accounting selector should be registered"
        );

        assertEq(_vaultExternalAssetCount(uint8(MoreVaultsLib.TokenType.StakingToken)), 1);
    }

    function test_onFacetRemoval_shouldCleanupWhenNotReplacing() public {
        facet.onFacetRemoval(false);

        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IStakingFacet).interfaceId),
            "Interface should be disabled"
        );
        assertEq(MoreVaultsStorageHelper.getFacetsForAccounting(address(facet)).length, 0);
        assertEq(_vaultExternalAssetCount(uint8(MoreVaultsLib.TokenType.StakingToken)), 0);
    }

    function test_onFacetRemoval_shouldKeepExternalAssetWhenReplacing() public {
        facet.onFacetRemoval(true);

        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IStakingFacet).interfaceId),
            "Interface should be disabled"
        );
        assertEq(MoreVaultsStorageHelper.getFacetsForAccounting(address(facet)).length, 0);
        assertEq(_vaultExternalAssetCount(uint8(MoreVaultsLib.TokenType.StakingToken)), 1);
    }

    function test_stake_shouldStakeAndTrackAdapter() public {
        vm.expectEmit(true, true, false, true);
        emit IStakingFacet.Staked(address(adapter), address(depositToken), STAKE_AMOUNT, STAKE_AMOUNT);

        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);

        assertEq(receipts, STAKE_AMOUNT);
        assertEq(receiptToken.balanceOf(address(facet)), STAKE_AMOUNT);
        assertEq(depositToken.balanceOf(address(lst)), 1_000e18 + STAKE_AMOUNT);

        address[] memory activeAdapters = facet.getActiveAdapters();
        assertEq(activeAdapters.length, 1);
        assertEq(activeAdapters[0], address(adapter));
    }

    function test_stake_shouldRevertOnZeroAmount() public {
        vm.prank(address(facet));
        vm.expectRevert(StakingFacetStorage.ZeroAmount.selector);
        facet.stake(address(adapter), 0, bytes(""));
    }

    function test_stake_shouldRevertWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.stake(address(adapter), STAKE_AMOUNT, bytes(""));
    }

    function test_stake_shouldRevertWhenAdapterNotWhitelisted() public {
        address notWhitelisted = address(0x999);
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, notWhitelisted));
        facet.stake(notWhitelisted, STAKE_AMOUNT, bytes(""));
    }

    function test_stake_shouldRevertOnInvalidAdapterTokens() public {
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.InvalidAdapter.selector, address(invalidTokensAdapter)));
        facet.stake(address(invalidTokensAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_stake_shouldRevertOnZeroAddressAdapter() public {
        registry.setWhitelisted(address(0), true);

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.InvalidAdapter.selector, address(0)));
        facet.stake(address(0), STAKE_AMOUNT, bytes(""));
    }

    function test_initialize_shouldRevertWhenCalledTwice() public {
        vm.expectRevert(BaseFacetInitializer.AlreadyInitialized.selector);
        facet.initialize(abi.encode(bytes32(bytes4(IStakingFacet.accountingStakingFacet.selector))));
    }

    function test_requestUnstake_shouldRevertWhenAdapterNotWhitelisted() public {
        _stake(address(adapter), STAKE_AMOUNT);

        address notWhitelisted = address(0x999);
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, notWhitelisted));
        facet.requestUnstake(notWhitelisted, STAKE_AMOUNT, bytes(""));
    }

    function test_removeAdapterIfEmpty_shouldKeepAdapterWithPendingUnstake() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        _requestUnstake(address(adapter), receipts / 2);

        address[] memory activeAdapters = facet.getActiveAdapters();
        assertEq(activeAdapters.length, 1);
        assertEq(activeAdapters[0], address(adapter));
    }

    function test_removeAdapterIfEmpty_shouldRemoveAdapterBelowDustThreshold() public {
        uint256 dustStake = 20_000;
        uint256 receipts = _stake(address(adapter), dustStake);
        bytes32 requestId = _requestUnstake(address(adapter), receipts - 9_000);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);
        lst.autoSettle(request.protocolRequestId, address(facet));

        _finalizeUnstake(requestId);

        assertEq(facet.getStakedBalance(address(adapter)), 9_000);
        assertEq(facet.getActiveAdapters().length, 0, "Adapter below dust threshold should be removed");
    }

    function test_removeAdapterIfEmpty_shouldKeepAdapterWithPendingStakeAccounting() public {
        _stake(address(asyncPendingStakeAdapter), 1);
        bytes32 requestId = _requestUnstake(address(asyncPendingStakeAdapter), 11_000);

        _finalizeUnstake(requestId);

        assertEq(facet.getStakedBalance(address(asyncPendingStakeAdapter)), 0);
        assertEq(facet.getPendingUnstake(address(asyncPendingStakeAdapter)), 0);
        assertEq(facet.getAccountingDepositValue(address(asyncPendingStakeAdapter)), 100e18);

        address[] memory activeAdapters = facet.getActiveAdapters();
        assertEq(activeAdapters.length, 1);
        assertEq(activeAdapters[0], address(asyncPendingStakeAdapter));
    }

    function test_requestUnstake_shouldRevertWhenUnstakeBlocked() public {
        _stake(address(blockingAdapter), STAKE_AMOUNT);
        blockingAdapter.setBlocked(true);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(StakingFacetStorage.UnstakeBlocked.selector, address(blockingAdapter))
        );
        facet.requestUnstake(address(blockingAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_requestUnstake_shouldStoreExpectedClaimableAtFromAdapter() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        uint256 expectedAt = block.timestamp + WITHDRAWAL_DELAY;

        bytes32 requestId = _requestUnstake(address(adapter), receipts);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        assertEq(request.expectedClaimableAt, expectedAt);
    }

    function test_stake_shouldBubbleAdapterRevertData() public {
        vm.prank(address(facet));
        vm.expectRevert("stake failed");
        facet.stake(address(stakeRevertAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_stake_shouldRevertWhenAdapterReturnsEmptyRevert() public {
        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.AdapterExecutionFailed.selector, address(stakeEmptyRevertAdapter), bytes("")
            )
        );
        facet.stake(address(stakeEmptyRevertAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_requestUnstake_shouldCreateWithdrawalRequest() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        bytes32 requestId = _requestUnstake(address(adapter), receipts);

        bytes32 protocolRequestId = keccak256(abi.encodePacked(address(facet), receipts, block.timestamp));
        bytes32 expectedRequestId = keccak256(abi.encode(address(adapter), uint256(1), protocolRequestId));

        assertEq(requestId, expectedRequestId);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        assertEq(request.adapter, address(adapter));
        assertEq(request.amount, receipts);
        assertEq(request.protocolRequestId, protocolRequestId);
        assertEq(request.expectedClaimableAt, block.timestamp + WITHDRAWAL_DELAY);
        assertFalse(request.finalized);
        assertEq(facet.getPendingUnstake(address(adapter)), receipts);
        assertEq(facet.getUnstakeableReceipts(address(adapter)), 0);
    }

    function test_requestUnstake_shouldRevertOnZeroReceipts() public {
        vm.prank(address(facet));
        vm.expectRevert(StakingFacetStorage.ZeroAmount.selector);
        facet.requestUnstake(address(adapter), 0, bytes(""));
    }

    function test_requestUnstake_shouldRevertWhenInsufficientBalance() public {
        _stake(address(adapter), STAKE_AMOUNT);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.InsufficientStakedBalance.selector, STAKE_AMOUNT + 1, STAKE_AMOUNT
            )
        );
        facet.requestUnstake(address(adapter), STAKE_AMOUNT + 1, bytes(""));
    }

    function test_requestUnstake_shouldRevertWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.requestUnstake(address(adapter), STAKE_AMOUNT, bytes(""));
    }

    function test_finalizeUnstake_shouldClaimDepositTokens() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        bytes32 requestId = _requestUnstake(address(adapter), receipts);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        lst.setClaimable(request.protocolRequestId, true);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);

        uint256 depositBalanceBefore = depositToken.balanceOf(address(facet));

        vm.expectEmit(true, false, false, true);
        emit IStakingFacet.UnstakeFinalized(requestId, STAKE_AMOUNT, false, STAKE_AMOUNT);

        uint256 amount = _finalizeUnstake(requestId);

        assertEq(amount, STAKE_AMOUNT);
        assertEq(depositToken.balanceOf(address(facet)), depositBalanceBefore + STAKE_AMOUNT);
        assertTrue(facet.getWithdrawalRequest(requestId).finalized);
        assertEq(facet.getStakedBalance(address(adapter)), 0);
        assertEq(facet.getActiveAdapters().length, 0);
    }

    function test_finalizeUnstake_shouldRevertWhenAlreadyFinalized() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        bytes32 requestId = _requestUnstake(address(adapter), receipts);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        lst.setClaimable(request.protocolRequestId, true);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);
        _finalizeUnstake(requestId);

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.WithdrawalAlreadyFinalized.selector, requestId));
        facet.finalizeUnstake(requestId, bytes(""));
    }

    function test_finalizeUnstake_shouldRevertWhenWithdrawalNotReady() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        bytes32 requestId = _requestUnstake(address(adapter), receipts);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.WithdrawalNotReady.selector,
                requestId,
                request.expectedClaimableAt
            )
        );
        facet.finalizeUnstake(requestId, bytes(""));
    }

    function test_finalizeUnstake_shouldRevertWhenUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.finalizeUnstake(bytes32(uint256(1)), bytes(""));
    }

    function test_finalizeUnstake_shouldSyncAfterAutoSettle() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        bytes32 requestId = _requestUnstake(address(adapter), receipts);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);
        lst.autoSettle(request.protocolRequestId, address(facet));

        assertFalse(IProtocolAdapter(address(adapter)).isWithdrawalClaimable(address(facet), request.protocolRequestId));
        assertTrue(IProtocolAdapter(address(adapter)).isWithdrawalCompleted(address(facet), request.protocolRequestId));
        assertEq(facet.getPendingUnstake(address(adapter)), 0);

        uint256 depositBalanceBeforeFinalize = depositToken.balanceOf(address(facet));

        vm.expectEmit(true, false, false, true);
        emit IStakingFacet.UnstakeFinalized(requestId, 0, true, STAKE_AMOUNT);

        uint256 amount = _finalizeUnstake(requestId);

        assertEq(amount, 0);
        assertEq(depositToken.balanceOf(address(facet)), depositBalanceBeforeFinalize);
        assertTrue(facet.getWithdrawalRequest(requestId).finalized);
        assertEq(facet.getActiveAdapters().length, 0);
    }

    function test_finalizeUnstake_shouldRevertWhenRequestNotFound() public {
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.WithdrawalRequestNotFound.selector, bytes32(0)));
        facet.finalizeUnstake(bytes32(0), bytes(""));
    }

    function test_beforeAccounting_shouldIgnoreFailingHarvest() public {
        _stake(address(harvestRevertAdapter), STAKE_AMOUNT);

        vm.expectEmit(true, false, false, true, address(facet));
        emit IStakingFacet.RewardsHarvested(address(harvestRevertAdapter), false);

        vm.prank(address(facet));
        facet.beforeAccounting();
    }

    function test_beforeAccounting_shouldHarvestActiveAdapters() public {
        _stake(address(adapter), STAKE_AMOUNT);

        vm.expectEmit(true, false, false, true, address(facet));
        emit IStakingFacet.RewardsHarvested(address(adapter), true);

        vm.prank(address(facet));
        facet.beforeAccounting();
    }

    function test_accountingStakingFacet_shouldReturnStakedValue() public {
        _stake(address(adapter), STAKE_AMOUNT);

        (uint256 sum, bool isPositive) = facet.accountingStakingFacet();

        assertEq(sum, STAKE_AMOUNT);
        assertTrue(isPositive);
    }

    function test_accountingStakingFacet_shouldSkipWalletReceiptsListedAsAvailableAssets() public {
        MoreVaultsStorageHelper.setAssetAvailable(address(facet), address(receiptToken), true);

        _stake(address(adapter), STAKE_AMOUNT);

        (uint256 sum,) = facet.accountingStakingFacet();
        assertEq(sum, 0, "Wallet receipts in availableAssets should be excluded from accounting");
        assertEq(facet.getAccountingDepositValue(address(adapter)), 0);
        assertEq(facet.getActiveAdapters().length, 1, "Adapter should remain tracked while staked");
    }

    function test_accountingStakingFacet_shouldIncludePendingUnstakeValue() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);
        _requestUnstake(address(adapter), receipts);

        (uint256 sum,) = facet.accountingStakingFacet();
        assertEq(sum, STAKE_AMOUNT);
        assertEq(facet.getAccountingDepositValue(address(adapter)), STAKE_AMOUNT);
    }

    function test_getters_shouldReturnAdapterState() public {
        uint256 receipts = _stake(address(adapter), STAKE_AMOUNT);

        assertEq(facet.getStakedBalance(address(adapter)), receipts);
        assertEq(facet.getUnstakeableReceipts(address(adapter)), receipts);
        assertEq(facet.getPendingUnstake(address(adapter)), 0);
        assertEq(facet.getAccountingDepositValue(address(adapter)), STAKE_AMOUNT);
    }

    function test_requestUnstake_shouldAssignUniqueRequestIdsForSameProtocolRequest() public {
        uint256 totalReceipts = _stake(address(adapter), STAKE_AMOUNT * 2);
        uint256 halfReceipts = totalReceipts / 2;

        bytes32 firstRequestId = _requestUnstake(address(adapter), halfReceipts);
        bytes32 secondRequestId = _requestUnstake(address(adapter), halfReceipts);

        assertTrue(firstRequestId != secondRequestId, "Request ids should be unique");
        assertTrue(facet.getWithdrawalRequest(firstRequestId).amount > 0);
        assertTrue(facet.getWithdrawalRequest(secondRequestId).amount > 0);
        assertEq(
            facet.getWithdrawalRequest(firstRequestId).protocolRequestId,
            facet.getWithdrawalRequest(secondRequestId).protocolRequestId
        );
    }

    function test_requestUnstake_shouldRevertWhenAdapterReturnsZeroReceipts() public {
        _stake(address(zeroUnstakeReceiptsAdapter), STAKE_AMOUNT);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.InvalidUnstakeReceipts.selector, STAKE_AMOUNT, uint256(0)
            )
        );
        facet.requestUnstake(address(zeroUnstakeReceiptsAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_requestUnstake_shouldRevertWhenAdapterReturnsTooManyReceipts() public {
        _stake(address(overUnstakeReceiptsAdapter), STAKE_AMOUNT);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.InvalidUnstakeReceipts.selector, STAKE_AMOUNT, STAKE_AMOUNT + 1
            )
        );
        facet.requestUnstake(address(overUnstakeReceiptsAdapter), STAKE_AMOUNT, bytes(""));
    }

    function test_stake_shouldReturnFewerReceiptsWhenExchangeRateAboveOne() public {
        MockLST rateLst = new MockLST(address(depositToken), address(receiptToken), 1.1e18, WITHDRAWAL_DELAY);
        MockProtocolAdapter rateAdapter = new MockProtocolAdapter(address(rateLst));
        _whitelistAdapter(address(rateAdapter));

        depositToken.mint(address(rateLst), 1_000e18);
        receiptToken.mint(address(rateLst), 1_000e18);

        uint256 stakeAmount = 110e18;
        uint256 receipts = _stake(address(rateAdapter), stakeAmount);

        assertEq(receipts, 100e18);
        assertEq(facet.getStakedBalance(address(rateAdapter)), 100e18);
    }

    function test_accountingStakingFacet_shouldReflectNonUnityExchangeRate() public {
        MockLST rateLst = new MockLST(address(depositToken), address(receiptToken), 1.1e18, WITHDRAWAL_DELAY);
        MockProtocolAdapter rateAdapter = new MockProtocolAdapter(address(rateLst));
        _whitelistAdapter(address(rateAdapter));

        depositToken.mint(address(rateLst), 1_000e18);
        receiptToken.mint(address(rateLst), 1_000e18);

        _stake(address(rateAdapter), 110e18);

        (uint256 sum,) = facet.accountingStakingFacet();
        assertEq(sum, 110e18);
        assertEq(facet.getAccountingDepositValue(address(rateAdapter)), 110e18);
    }

    function test_finalizeUnstake_shouldReturnDepositAtExchangeRate() public {
        MockLST rateLst = new MockLST(address(depositToken), address(receiptToken), 1.1e18, WITHDRAWAL_DELAY);
        MockProtocolAdapter rateAdapter = new MockProtocolAdapter(address(rateLst));
        _whitelistAdapter(address(rateAdapter));

        depositToken.mint(address(rateLst), 1_000e18);
        receiptToken.mint(address(rateLst), 1_000e18);

        uint256 receipts = _stake(address(rateAdapter), 110e18);
        bytes32 requestId = _requestUnstake(address(rateAdapter), receipts);

        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        rateLst.setClaimable(request.protocolRequestId, true);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);

        uint256 depositBefore = depositToken.balanceOf(address(facet));
        uint256 amount = _finalizeUnstake(requestId);

        assertEq(amount, 110e18);
        assertEq(depositToken.balanceOf(address(facet)), depositBefore + 110e18);
    }

    function test_beforeAccounting_shouldNoOpWhenNoActiveAdapters() public {
        vm.prank(address(facet));
        facet.beforeAccounting();
    }
}
