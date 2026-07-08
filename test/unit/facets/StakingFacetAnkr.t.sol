// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingFacet} from "../../../src/facets/StakingFacet.sol";
import {AnkrFlowAdapter} from "../../../src/adapters/LST/AnkrFlowAdapter.sol";
import {IStakingFacet} from "../../../src/interfaces/facets/IStakingFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {StakingFacetStorage} from "../../../src/libraries/StakingFacetStorage.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MockAnkrFlowPool, MockAnkrCertificateToken} from "../../mocks/MockAnkrFlowPool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IWrappedToken} from "../../../src/interfaces/IWrappedToken.sol";

contract MockRegistry {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address protocol, bool status) external {
        whitelisted[protocol] = status;
    }

    function isWhitelisted(address protocol) external view returns (bool) {
        return whitelisted[protocol];
    }
}

contract MockWrappedNative is MockERC20, IWrappedToken {
    error NativeTransferFailed();

    constructor() MockERC20("WFLOW", "WFLOW") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    receive() external payable {}
}

contract StakingFacetHarness is StakingFacet {
    receive() external payable {}
}

contract StakingFacetAnkrTest is Test {
    StakingFacetHarness public facet;
    MockRegistry public registry;
    MockWrappedNative public wflow;
    MockAnkrCertificateToken public cert;
    MockAnkrFlowPool public pool;
    AnkrFlowAdapter public adapter;

    address public owner = address(0x1);

    function setUp() public {
        facet = new StakingFacetHarness();
        registry = new MockRegistry();
        wflow = new MockWrappedNative();
        vm.deal(address(wflow), 10_000 ether);
        cert = new MockAnkrCertificateToken();
        pool = new MockAnkrFlowPool(address(wflow), address(cert));
        adapter = new AnkrFlowAdapter(address(pool), address(wflow));

        MoreVaultsStorageHelper.setOwner(address(facet), owner);
        MoreVaultsStorageHelper.setCurator(address(facet), owner);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), address(registry));
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(wflow));

        address[] memory availableAssets = new address[](1);
        availableAssets[0] = address(wflow);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);

        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(
            address(facet), IStakingFacet.stake.selector, address(facet), 0
        );

        registry.setWhitelisted(address(adapter), true);

        vm.deal(address(pool), 1_000 ether);
        vm.deal(address(facet), 1_000 ether);
        wflow.mint(address(facet), 1_000 ether);

        bytes32 facetSelector = bytes32(bytes4(IStakingFacet.accountingStakingFacet.selector));
        facet.initialize(abi.encode(facetSelector));
    }

    function _stake(uint256 amount) internal returns (uint256 receipts) {
        vm.prank(address(facet));
        receipts = facet.stake(address(adapter), amount, bytes(""));
    }

    function _requestUnstake(uint256 receipts) internal returns (bytes32 requestId) {
        vm.prank(address(facet));
        requestId = facet.requestUnstake(address(adapter), receipts, bytes(""));
    }

    function _finalizeUnstake(bytes32 requestId) internal returns (uint256 amount) {
        vm.prank(address(facet));
        amount = facet.finalizeUnstake(requestId, bytes(""));
    }

    function test_stake_shouldMintAnkrShares() public {
        uint256 receipts = _stake(100 ether);

        assertEq(receipts, 100 ether);
        assertEq(cert.balanceOf(address(facet)), 100 ether);
        assertEq(facet.getAccountingDepositValue(address(adapter)), 100 ether);
    }

    function test_stake_shouldReflectNonUnityRatioInAccounting() public {
        cert.setRatio(1.1e18);

        _stake(110 ether);

        assertEq(cert.balanceOf(address(facet)), 100 ether);
        assertEq(facet.getAccountingDepositValue(address(adapter)), 110 ether);
        (uint256 sum,) = facet.accountingStakingFacet();
        assertEq(sum, 110 ether);
    }

    function test_requestUnstake_shouldStoreReducedReceiptsAfterDedup() public {
        _stake(100 ether);
        _requestUnstake(50 ether);

        bytes32 requestId = _requestUnstake(50 ether);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        assertLt(request.amount, 50 ether, "facet should snapshot actual shares unstaked");
        assertEq(uint256(request.protocolRequestId), request.amount);
    }

    function test_requestUnstake_shouldRevertWhenManualClaimBlocksNewUnstake() public {
        _stake(100 ether);
        bytes32 firstRequestId = _requestUnstake(40 ether);
        StakingFacetStorage.WithdrawalRequest memory firstRequest = facet.getWithdrawalRequest(firstRequestId);
        pool.settlePending(address(facet), uint256(firstRequest.protocolRequestId), true);

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.UnstakeBlocked.selector, address(adapter)));
        facet.requestUnstake(address(adapter), 10 ether, bytes(""));
    }

    function test_finalizeUnstake_shouldClaimManualBucket() public {
        _stake(100 ether);
        bytes32 requestId = _requestUnstake(40 ether);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        pool.settlePending(address(facet), uint256(request.protocolRequestId), true);

        uint256 balanceBefore = address(facet).balance;
        uint256 amount = _finalizeUnstake(requestId);

        assertEq(amount, 40 ether);
        assertEq(address(facet).balance, balanceBefore + 40 ether);
        assertTrue(facet.getWithdrawalRequest(requestId).finalized);
    }

    function test_finalizeUnstake_shouldSyncAfterAutoSettle() public {
        _stake(100 ether);
        bytes32 requestId = _requestUnstake(40 ether);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        pool.settlePending(address(facet), uint256(request.protocolRequestId), false);

        uint256 balanceBefore = address(facet).balance;
        uint256 amount = _finalizeUnstake(requestId);

        assertEq(amount, 0);
        assertEq(address(facet).balance, balanceBefore);
        assertTrue(facet.getWithdrawalRequest(requestId).finalized);
    }

    function test_recoverStrandedWithdrawals_shouldClaimManualBucket() public {
        _stake(100 ether);
        bytes32 requestId = _requestUnstake(25 ether);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);
        pool.settlePending(address(facet), uint256(request.protocolRequestId), true);

        vm.expectEmit(true, false, false, true);
        emit IStakingFacet.StrandedWithdrawalsRecovered(address(adapter), 25 ether);

        vm.prank(address(facet));
        uint256 amount = facet.recoverStrandedWithdrawals(address(adapter), bytes(""));

        assertEq(amount, 25 ether);
        assertEq(address(facet).balance, 1_025 ether);
    }

    function test_recoverStrandedWithdrawals_shouldRevertWhenUnauthorized() public {
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.recoverStrandedWithdrawals(address(adapter), bytes(""));
    }
}
