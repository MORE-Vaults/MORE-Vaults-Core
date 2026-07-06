// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingFacet} from "../../../src/facets/StakingFacet.sol";
import {SFlowLSPAdapter} from "../../../src/adapters/LST/SFlowLSPAdapter.sol";
import {IStakingFacet} from "../../../src/interfaces/facets/IStakingFacet.sol";
import {IProtocolAdapter} from "../../../src/interfaces/IProtocolAdapter.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {StakingFacetStorage} from "../../../src/libraries/StakingFacetStorage.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MockLSPVault, MockFlowReceipt, MockSFlow} from "../../mocks/MockLSPVault.sol";
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
    constructor() MockERC20("WFLOW", "WFLOW") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "native transfer failed");
    }

    receive() external payable {}
}

contract StakingFacetHarness is StakingFacet {
    receive() external payable {}
}

contract StakingFacetSFlowTest is Test {
    StakingFacetHarness public facet;
    MockRegistry public registry;
    MockWrappedNative public wflow;
    MockSFlow public sflow;
    MockFlowReceipt public flowReceipt;
    MockLSPVault public lspVault;
    SFlowLSPAdapter public adapter;

    address public owner = address(0x1);

    function setUp() public {
        facet = new StakingFacetHarness();
        registry = new MockRegistry();
        wflow = new MockWrappedNative();
        vm.deal(address(wflow), 10_000 ether);
        sflow = new MockSFlow();
        flowReceipt = new MockFlowReceipt();
        lspVault = new MockLSPVault(address(sflow), address(flowReceipt));
        adapter = new SFlowLSPAdapter(address(lspVault), address(wflow));

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

        vm.deal(address(lspVault), 1_000 ether);
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
        amount = facet.finalizeUnstake(requestId);
    }

    function test_stake_shouldQueueAsyncStakeWithoutWalletSFlow() public {
        uint256 amount = 100 ether;
        uint256 expectedReceipts = lspVault.getSFlowQuote(amount);

        uint256 receipts = _stake(amount);

        assertEq(receipts, expectedReceipts);
        assertEq(flowReceipt.balanceOf(address(facet)), amount);
        assertEq(sflow.balanceOf(address(facet)), 0);
        assertEq(adapter.getUnstakeableReceipts(address(facet)), 0);
        assertEq(facet.getAccountingDepositValue(address(adapter)), amount);
    }

    function test_requestUnstake_shouldRevertWhileAsyncStakePending() public {
        _stake(100 ether);

        vm.prank(address(facet));
        vm.expectRevert(
            abi.encodeWithSelector(StakingFacetStorage.InsufficientStakedBalance.selector, 1 ether, uint256(0))
        );
        facet.requestUnstake(address(adapter), 1 ether, bytes(""));
    }

    function test_stakeAndUnstakeLifecycle_shouldFinalizeNativeRefund() public {
        uint256 amount = 100 ether;
        uint256 expectedSFlow = _stake(amount);
        lspVault.fulfillStake(address(facet), expectedSFlow);

        bytes32 requestId = _requestUnstake(expectedSFlow);
        StakingFacetStorage.WithdrawalRequest memory request = facet.getWithdrawalRequest(requestId);

        lspVault.fulfillUnstake(uint256(request.protocolRequestId), amount, 0);

        uint256 balanceBefore = address(facet).balance;
        uint256 nativeAmount = _finalizeUnstake(requestId);

        assertEq(nativeAmount, amount);
        assertEq(address(facet).balance, balanceBefore + amount);
        assertTrue(facet.getWithdrawalRequest(requestId).finalized);
    }

    function test_stake_shouldReflectNonUnityRateInAccounting() public {
        lspVault.setRate(1.05e18);

        _stake(105 ether);

        assertEq(facet.getAccountingDepositValue(address(adapter)), 105 ether);
        (uint256 sum,) = facet.accountingStakingFacet();
        assertEq(sum, 105 ether);
    }

    function test_recoverStrandedWithdrawals_shouldClaimOrphanRefund() public {
        uint256 refund = 25 ether;
        lspVault.creditPendingWithdrawal{value: refund}(address(facet), refund);

        assertEq(adapter.getAccountingDepositValue(address(facet), false), refund);

        vm.expectEmit(true, false, false, true);
        emit IStakingFacet.StrandedWithdrawalsRecovered(address(adapter), refund);

        vm.prank(address(facet));
        uint256 amount = facet.recoverStrandedWithdrawals(address(adapter), bytes(""));

        assertEq(amount, refund);
        assertEq(address(facet).balance, 1_000 ether + refund);
        assertFalse(adapter.isUnstakeBlocked(address(facet)));
        assertEq(adapter.getAccountingDepositValue(address(facet), false), 0);
    }

    function test_recoverStrandedWithdrawals_shouldRevertWhenNothingStranded() public {
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.NoStrandedWithdrawals.selector, address(adapter)));
        facet.recoverStrandedWithdrawals(address(adapter), bytes(""));
    }

    function test_recoverStrandedWithdrawals_shouldRevertWhenUnauthorized() public {
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.recoverStrandedWithdrawals(address(adapter), bytes(""));
    }
}
