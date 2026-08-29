// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AnkrFlowAdapter} from "../../../src/adapters/LST/AnkrFlowAdapter.sol";
import {MockAnkrFlowPool, MockAnkrCertificateToken} from "../../mocks/MockAnkrFlowPool.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IWrappedToken} from "../../../src/interfaces/IWrappedToken.sol";

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

contract AdapterDelegateHarness {
    error StakeFailed();
    error FinalizeUnstakeFailed();
    error RecoverStrandedWithdrawalsFailed();

    receive() external payable {}

    function stake(address adapter, uint256 amount) external returns (uint256 receipts) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(AnkrFlowAdapter.stake.selector, amount, bytes(""))
        );
        if (!success) revert StakeFailed();
        return abi.decode(data, (uint256));
    }

    function requestUnstake(address adapter, uint256 shares)
        external
        returns (bytes32 protocolRequestId, uint256 actualReceipts)
    {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(AnkrFlowAdapter.requestUnstake.selector, shares, bytes(""))
        );
        if (!success) {
            assembly {
                revert(add(32, data), mload(data))
            }
        }
        return abi.decode(data, (bytes32, uint256));
    }

    function isWithdrawalCompleted(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return AnkrFlowAdapter(adapter).isWithdrawalCompleted(vault, protocolRequestId);
    }

    function isWithdrawalClaimable(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return AnkrFlowAdapter(adapter).isWithdrawalClaimable(vault, protocolRequestId);
    }

    function finalizeUnstake(address adapter, bytes32 protocolRequestId, bytes calldata params)
        external
        returns (uint256 amount)
    {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(AnkrFlowAdapter.finalizeUnstake.selector, protocolRequestId, params)
        );
        if (!success) revert FinalizeUnstakeFailed();
        return abi.decode(data, (uint256));
    }

    function recoverStrandedWithdrawals(address adapter, bytes calldata params) external returns (uint256 amount) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(AnkrFlowAdapter.recoverStrandedWithdrawals.selector, params)
        );
        if (!success) revert RecoverStrandedWithdrawalsFailed();
        return abi.decode(data, (uint256));
    }
}

contract AnkrFlowAdapterTest is Test {
    MockWrappedNative public wflow;
    MockAnkrCertificateToken public cert;
    MockAnkrFlowPool public pool;
    AnkrFlowAdapter public adapter;
    AdapterDelegateHarness public harness;

    address public vault;

    function setUp() public {
        wflow = new MockWrappedNative();
        vm.deal(address(wflow), 10_000 ether);
        cert = new MockAnkrCertificateToken();
        pool = new MockAnkrFlowPool(address(wflow), address(cert));
        adapter = new AnkrFlowAdapter(address(pool), address(wflow));
        harness = new AdapterDelegateHarness();
        vault = address(harness);

        vm.deal(vault, 1_000 ether);
        vm.deal(address(pool), 1_000 ether);
        wflow.mint(vault, 1_000 ether);
        cert.mint(vault, 100 ether);
    }

    function test_requestUnstake_shouldEncodeUnstakeTimeBondAmount() public {
        (bytes32 protocolRequestId, uint256 actualReceipts) = harness.requestUnstake(address(adapter), 50 ether);

        assertEq(uint256(protocolRequestId), 50 ether);
        assertEq(actualReceipts, 50 ether);
    }

    function test_requestUnstake_shouldAvoidDuplicateBondAmountsInQueue() public {
        (bytes32 first,) = harness.requestUnstake(address(adapter), 50 ether);
        (bytes32 second, uint256 actualSecondShares) = harness.requestUnstake(address(adapter), 50 ether);

        assertEq(uint256(first), 50 ether);
        assertTrue(actualSecondShares < 50 ether, "second unstake should reduce shares to avoid bond collision");
        assertTrue(uint256(second) < 50 ether, "second bond amount should be reduced to stay unique");
        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, first) == false);
    }

    function test_isWithdrawalCompleted_shouldUseUnstakeTimeBondDespiteRatioDrift() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 50 ether);

        cert.setRatio(2e18);

        pool.settlePending(vault, 50 ether, false);

        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_isWithdrawalCompleted_shouldTrackRequestsIndependentlyAfterDedup() public {
        (bytes32 first,) = harness.requestUnstake(address(adapter), 50 ether);
        (bytes32 second,) = harness.requestUnstake(address(adapter), 50 ether);

        pool.settlePending(vault, uint256(first), false);

        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, first));
        assertFalse(harness.isWithdrawalCompleted(address(adapter), vault, second));

        pool.settlePending(vault, uint256(second), false);

        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, second));
    }

    function test_isWithdrawalClaimable_shouldDetectManualClaimBucket() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);

        pool.settlePending(vault, 40 ether, true);

        assertTrue(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
        assertFalse(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_isUnstakeBlocked_shouldBeTrueWhenManualClaimPending() public {
        harness.requestUnstake(address(adapter), 40 ether);
        pool.settlePending(vault, 40 ether, true);

        assertTrue(adapter.isUnstakeBlocked(vault));
    }

    function test_isUnstakeBlocked_shouldBeFalseWithoutManualClaim() public {
        assertFalse(adapter.isUnstakeBlocked(vault));
    }

    function test_getWithdrawalClaimableAt_shouldReturnNowPlus15Days() public {
        uint256 claimableAt = adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(1)));
        assertEq(claimableAt, block.timestamp + 15 days);
    }

    function test_stake_shouldMintSharesFromNativeDeposit() public {
        uint256 amount = 100 ether;
        uint256 wflowBefore = wflow.balanceOf(vault);

        uint256 receipts = harness.stake(address(adapter), amount);

        assertEq(receipts, amount);
        assertEq(cert.balanceOf(vault), 100 ether + amount);
        assertEq(wflow.balanceOf(vault), wflowBefore - amount);
    }

    function test_stake_shouldMintFewerSharesWhenRatioAboveOne() public {
        cert.setRatio(1.1e18);

        uint256 receipts = harness.stake(address(adapter), 110 ether);

        assertEq(receipts, 100 ether);
        assertEq(cert.balanceOf(vault), 200 ether);
    }

    function test_getPendingUnstake_shouldConvertBondsToShares() public {
        harness.requestUnstake(address(adapter), 50 ether);

        assertEq(adapter.getPendingUnstake(vault), 50 ether);
    }

    function test_getPendingUnstake_shouldReflectRatioDrift() public {
        harness.requestUnstake(address(adapter), 50 ether);
        cert.setRatio(2e18);

        assertEq(adapter.getPendingUnstake(vault), 25 ether);
    }

    function test_getAccountingDepositValue_shouldIncludeWalletAndQueues() public {
        harness.requestUnstake(address(adapter), 40 ether);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);
        assertEq(accounting, 100 ether);
    }

    function test_getAccountingDepositValue_shouldExcludeWalletWhenListed() public {
        harness.requestUnstake(address(adapter), 40 ether);

        assertEq(adapter.getAccountingDepositValue(vault, true), 40 ether);
    }

    function test_getAccountingDepositValue_shouldUseBondConversionWhenRatioAboveOne() public {
        cert.setRatio(1.1e18);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);

        assertEq(accounting, (100 ether * 1.1e18) / 1e18);
    }

    function test_finalizeUnstake_shouldClaimManualBucket() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        pool.settlePending(vault, 40 ether, true);

        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId, bytes(""));

        assertEq(amount, 40 ether);
        assertEq(vault.balance, 1_040 ether);
        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_finalizeUnstake_shouldReturnZeroOnAutoSettleSync() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        pool.settlePending(vault, 40 ether, false);

        uint256 balanceBefore = vault.balance;
        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId, bytes(""));

        assertEq(amount, 0);
        assertEq(vault.balance, balanceBefore);
        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_finalizeUnstake_secondRequestSyncsAfterSharedManualClaim() public {
        (bytes32 first,) = harness.requestUnstake(address(adapter), 40 ether);
        (bytes32 second,) = harness.requestUnstake(address(adapter), 30 ether);

        pool.settlePending(vault, 40 ether, true);
        pool.settlePending(vault, uint256(second), true);

        uint256 firstAmount = harness.finalizeUnstake(address(adapter), first, bytes(""));
        uint256 secondAmount = harness.finalizeUnstake(address(adapter), second, bytes(""));

        assertEq(firstAmount, 70 ether, "first finalize drains shared manual bucket");
        assertEq(secondAmount, 0, "second finalize syncs after bucket drained");
        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, second));
    }

    function test_recoverStrandedWithdrawals_shouldReturnManualClaimDelta() public {
        harness.requestUnstake(address(adapter), 25 ether);
        pool.settlePending(vault, 25 ether, true);

        uint256 balanceBefore = vault.balance;
        uint256 amount = harness.recoverStrandedWithdrawals(address(adapter), bytes(""));

        assertEq(amount, 25 ether);
        assertEq(vault.balance, balanceBefore + 25 ether);
    }

    function test_recoverStrandedWithdrawals_shouldReturnZeroWhenEmpty() public {
        assertEq(adapter.recoverStrandedWithdrawals(bytes("")), 0);
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroBond() public {
        assertFalse(adapter.isWithdrawalClaimable(vault, bytes32(0)));
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroBond() public {
        assertFalse(adapter.isWithdrawalCompleted(vault, bytes32(0)));
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroVault() public {
        assertFalse(adapter.isWithdrawalCompleted(address(0), bytes32(uint256(50 ether))));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroVault() public {
        harness.requestUnstake(address(adapter), 40 ether);
        pool.settlePending(vault, 40 ether, true);

        assertFalse(adapter.isWithdrawalClaimable(address(0), bytes32(uint256(40 ether))));
    }


    function test_requestUnstake_shouldRevertDuplicateBondAmount() public {
        harness.requestUnstake(address(adapter), 1);
        vm.expectRevert(AnkrFlowAdapter.DuplicateBondAmount.selector);
        harness.requestUnstake(address(adapter), 1);
    }

    function test_getProtocolName_shouldReturnAnkrFlow() public view {
        assertEq(adapter.getProtocolName(), "AnkrFlow");
    }
}
