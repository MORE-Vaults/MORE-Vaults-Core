// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SFlowLSPAdapter} from "../../../src/adapters/LST/SFlowLSPAdapter.sol";
import {ILSPVault} from "../../../src/interfaces/external/sflow/ILSPVault.sol";
import {MockLSPVault, MockFlowReceipt, MockSFlow} from "../../mocks/MockLSPVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IWrappedToken} from "../../../src/interfaces/IWrappedToken.sol";

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

contract SFlowAdapterDelegateHarness {
    receive() external payable {}

    function stake(address adapter, uint256 amount) external returns (uint256 receipts) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(SFlowLSPAdapter.stake.selector, amount, bytes(""))
        );
        require(success, "stake failed");
        return abi.decode(data, (uint256));
    }

    function requestUnstake(address adapter, uint256 receipts)
        external
        returns (bytes32 protocolRequestId, uint256 actualReceipts)
    {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(SFlowLSPAdapter.requestUnstake.selector, receipts, bytes(""))
        );
        require(success, "requestUnstake failed");
        return abi.decode(data, (bytes32, uint256));
    }

    function isWithdrawalCompleted(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return SFlowLSPAdapter(adapter).isWithdrawalCompleted(vault, protocolRequestId);
    }

    function isWithdrawalClaimable(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return SFlowLSPAdapter(adapter).isWithdrawalClaimable(vault, protocolRequestId);
    }

    function finalizeUnstake(address adapter, bytes32 protocolRequestId) external returns (uint256 amount) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(SFlowLSPAdapter.finalizeUnstake.selector, protocolRequestId)
        );
        require(success, "finalizeUnstake failed");
        return abi.decode(data, (uint256));
    }

    function recoverStrandedWithdrawals(address adapter, bytes calldata params) external returns (uint256 amount) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(SFlowLSPAdapter.recoverStrandedWithdrawals.selector, params)
        );
        require(success, "recoverStrandedWithdrawals failed");
        return abi.decode(data, (uint256));
    }
}

contract SFlowLSPAdapterTest is Test {
    MockWrappedNative public wflow;
    MockSFlow public sflow;
    MockFlowReceipt public flowReceipt;
    MockLSPVault public lspVault;
    SFlowLSPAdapter public adapter;
    SFlowAdapterDelegateHarness public harness;

    address public vault;

    function setUp() public {
        wflow = new MockWrappedNative();
        vm.deal(address(wflow), 10_000 ether);
        sflow = new MockSFlow();
        flowReceipt = new MockFlowReceipt();
        lspVault = new MockLSPVault(address(sflow), address(flowReceipt));
        adapter = new SFlowLSPAdapter(address(lspVault), address(wflow));
        harness = new SFlowAdapterDelegateHarness();
        vault = address(harness);

        vm.deal(vault, 1_000 ether);
        vm.deal(address(lspVault), 1_000 ether);
        wflow.mint(vault, 1_000 ether);
        sflow.mint(vault, 100 ether);
    }

    function test_requestUnstake_shouldEncodeLspRequestId() public {
        (bytes32 protocolRequestId, uint256 actualReceipts) = harness.requestUnstake(address(adapter), 50 ether);

        assertEq(uint256(protocolRequestId), 1);
        assertEq(actualReceipts, 50 ether);
    }

    function test_isWithdrawalClaimable_shouldDetectPendingWithdrawals() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);

        lspVault.fulfillUnstake(1, 40 ether, 100);

        assertTrue(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
        assertFalse(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_isWithdrawalCompleted_shouldTrackAfterClaim() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 100);

        vm.prank(vault);
        lspVault.claimPendingWithdrawal();

        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
        assertFalse(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
    }

    function test_isUnstakeBlocked_shouldAlwaysBeFalse() public {
        harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 100);

        assertFalse(adapter.isUnstakeBlocked(vault));
    }

    function test_isUnstakeBlocked_shouldBeFalseWithPendingWithdrawals() public {
        lspVault.creditPendingWithdrawal{value: 25 ether}(vault, 25 ether);
        assertFalse(adapter.isUnstakeBlocked(vault));
    }

    function test_getAccountingDepositValue_shouldCountFlowReceiptAndPendingWithdrawals() public {
        harness.requestUnstake(address(adapter), 30 ether);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);
        assertEq(accounting, 30 ether + 70 ether);
    }

    function test_getWithdrawalClaimableAt_shouldReturnInformationalEta() public {
        uint256 t0 = block.timestamp;
        harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 12345);

        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(1))), t0 + 14 days);
    }

    function test_getWithdrawalClaimableAt_shouldReturnZeroForMissingRequest() public {
        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(0))), 0);
    }

    function test_finalizeUnstake_shouldReturnClaimDelta() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 100);

        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId);

        assertEq(amount, 40 ether);
        assertEq(vault.balance, 1_040 ether);
    }

    function test_finalizeUnstake_shouldReturnZeroOnSync() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 100);

        vm.prank(vault);
        lspVault.claimPendingWithdrawal();

        uint256 balanceBefore = vault.balance;
        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId);

        assertEq(amount, 0);
        assertEq(vault.balance, balanceBefore);
    }

    function test_recoverStrandedWithdrawals_shouldReturnRefundDelta() public {
        lspVault.creditPendingWithdrawal{value: 25 ether}(vault, 25 ether);

        uint256 balanceBefore = vault.balance;
        uint256 amount = harness.recoverStrandedWithdrawals(address(adapter), bytes(""));

        assertEq(amount, 25 ether);
        assertEq(vault.balance, balanceBefore + 25 ether);
        assertFalse(adapter.isUnstakeBlocked(vault));
    }

    function test_recoverStrandedWithdrawals_shouldReturnZeroWhenEmpty() public {
        assertEq(adapter.recoverStrandedWithdrawals(bytes("")), 0);
    }

    function test_stake_shouldMintFlowReceiptAndReturnQuote() public {
        uint256 amount = 100 ether;
        uint256 wflowBefore = wflow.balanceOf(vault);

        uint256 receipts = harness.stake(address(adapter), amount);

        assertEq(receipts, lspVault.getSFlowQuote(amount));
        assertEq(wflow.balanceOf(vault), wflowBefore - amount);
        assertEq(flowReceipt.balanceOf(vault), amount);
        assertEq(sflow.balanceOf(vault), 100 ether, "wallet sFlow unchanged until fulfillment");
    }

    function test_stake_shouldReturnFewerReceiptsWhenRateAboveOne() public {
        lspVault.setRate(1.05e18);

        uint256 receipts = harness.stake(address(adapter), 105 ether);

        assertEq(receipts, 100 ether);
        assertEq(flowReceipt.balanceOf(vault), 105 ether);
    }

    function test_getStakedReceipts_shouldReturnWalletBalance() public {
        assertEq(adapter.getStakedReceipts(vault), 100 ether);
    }

    function test_getUnstakeableReceipts_shouldReturnWalletBalance() public {
        assertEq(adapter.getUnstakeableReceipts(vault), 100 ether);
    }

    function test_getPendingUnstake_shouldSumActiveRequests() public {
        harness.requestUnstake(address(adapter), 30 ether);
        harness.requestUnstake(address(adapter), 20 ether);

        assertEq(adapter.getPendingUnstake(vault), 50 ether);
    }

    function test_getPendingUnstake_shouldExcludeFulfilledRequests() public {
        harness.requestUnstake(address(adapter), 30 ether);
        (bytes32 second,) = harness.requestUnstake(address(adapter), 20 ether);
        lspVault.fulfillUnstake(uint256(second), 20 ether, 0);

        assertEq(adapter.getPendingUnstake(vault), 30 ether);
    }

    function test_getAccountingDepositValue_shouldExcludeWalletReceiptsWhenListed() public {
        harness.requestUnstake(address(adapter), 30 ether);

        uint256 withWallet = adapter.getAccountingDepositValue(vault, false);
        uint256 withoutWallet = adapter.getAccountingDepositValue(vault, true);

        assertEq(withWallet, 100 ether);
        assertEq(withoutWallet, 30 ether);
    }

    function test_getAccountingDepositValue_shouldUseFlowQuoteWhenRateAboveOne() public {
        lspVault.setRate(1.05e18);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);

        assertEq(accounting, (100 ether * 1.05e18) / 1e18);
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroId() public {
        assertFalse(adapter.isWithdrawalClaimable(vault, bytes32(0)));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseWhileQueued() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);

        assertFalse(adapter.isWithdrawalClaimable(vault, protocolRequestId));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseAfterCompleted() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 0);
        vm.prank(vault);
        lspVault.claimPendingWithdrawal();

        assertFalse(adapter.isWithdrawalClaimable(vault, protocolRequestId));
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroId() public {
        assertFalse(adapter.isWithdrawalCompleted(vault, bytes32(0)));
    }

    function test_getWithdrawalClaimableAt_shouldReturnZeroForCancelledRequest() public {
        harness.requestUnstake(address(adapter), 40 ether);
        lspVault.setRequestStatus(1, ILSPVault.RequestStatus.CANCELLED);

        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(1))), 0);
    }

    function test_getWithdrawalClaimableAt_shouldReturnZeroForNoneStatus() public {
        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(999))), 0);
    }

    function test_getPendingUnstake_shouldIncludeAwaitingFulfillmentStatus() public {
        harness.requestUnstake(address(adapter), 20 ether);
        lspVault.setRequestStatus(1, ILSPVault.RequestStatus.AWAITING_FULFILLMENT);

        assertEq(adapter.getPendingUnstake(vault), 20 ether);
    }

    function test_getPendingUnstake_shouldIncludeUnstakeConfirmedStatus() public {
        harness.requestUnstake(address(adapter), 15 ether);
        lspVault.setRequestStatus(1, ILSPVault.RequestStatus.UNSTAKE_CONFIRMED);

        assertEq(adapter.getPendingUnstake(vault), 15 ether);
    }

    function test_getPendingUnstake_shouldExcludeOtherVaultRequests() public {
        address other = address(0xBEEF);
        sflow.mint(other, 10 ether);
        vm.prank(other);
        sflow.approve(address(lspVault), 10 ether);
        vm.prank(other);
        lspVault.requestUnstake(10 ether);

        harness.requestUnstake(address(adapter), 25 ether);

        assertEq(adapter.getPendingUnstake(vault), 25 ether);
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroVault() public {
        harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 0);

        assertFalse(adapter.isWithdrawalCompleted(address(0), bytes32(uint256(1))));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroVault() public {
        harness.requestUnstake(address(adapter), 40 ether);
        lspVault.fulfillUnstake(1, 40 ether, 0);

        assertFalse(adapter.isWithdrawalClaimable(address(0), bytes32(uint256(1))));
    }

    function test_harvest_shouldBeNoOp() public {
        adapter.harvest();
    }

    function test_getProtocolName_shouldReturnSFlowLSP() public view {
        assertEq(adapter.getProtocolName(), "sFlowLSP");
    }
}
