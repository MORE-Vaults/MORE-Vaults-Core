// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LidoAdapter} from "../../../src/adapters/LST/LidoAdapter.sol";
import {MockLido, MockWstETH, MockWithdrawalQueue} from "../../mocks/MockLido.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IWrappedToken} from "../../../src/interfaces/IWrappedToken.sol";

contract MockWrappedNative is MockERC20, IWrappedToken {
    error NativeTransferFailed();

    constructor() MockERC20("WETH", "WETH") {}

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

contract BadMockWstETH {
    function stETH() external pure returns (address) {
        return address(0);
    }
}

contract LidoAdapterDelegateHarness {
    error StakeFailed();
    error RequestUnstakeFailed();
    error FinalizeUnstakeFailed();
    error RecoverStrandedWithdrawalsFailed();

    receive() external payable {}

    function stake(address adapter, uint256 amount, bytes calldata params) external returns (uint256 receipts) {
        (bool success, bytes memory data) =
            adapter.delegatecall(abi.encodeWithSelector(LidoAdapter.stake.selector, amount, params));
        if (!success) revert StakeFailed();
        return abi.decode(data, (uint256));
    }

    function requestUnstake(address adapter, uint256 receipts)
        external
        returns (bytes32 protocolRequestId, uint256 actualReceipts)
    {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(LidoAdapter.requestUnstake.selector, receipts, bytes(""))
        );
        if (!success) revert RequestUnstakeFailed();
        return abi.decode(data, (bytes32, uint256));
    }

    function isWithdrawalCompleted(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return LidoAdapter(adapter).isWithdrawalCompleted(vault, protocolRequestId);
    }

    function isWithdrawalClaimable(address adapter, address vault, bytes32 protocolRequestId)
        external
        view
        returns (bool)
    {
        return LidoAdapter(adapter).isWithdrawalClaimable(vault, protocolRequestId);
    }

    function finalizeUnstake(address adapter, bytes32 protocolRequestId, bytes calldata params)
        external
        returns (uint256 amount)
    {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(LidoAdapter.finalizeUnstake.selector, protocolRequestId, params)
        );
        if (!success) revert FinalizeUnstakeFailed();
        return abi.decode(data, (uint256));
    }

    function recoverStrandedWithdrawals(address adapter, bytes calldata params) external returns (uint256 amount) {
        (bool success, bytes memory data) = adapter.delegatecall(
            abi.encodeWithSelector(LidoAdapter.recoverStrandedWithdrawals.selector, params)
        );
        if (!success) revert RecoverStrandedWithdrawalsFailed();
        return abi.decode(data, (uint256));
    }
}

contract LidoAdapterTest is Test {
    MockWrappedNative public weth;
    MockLido public lido;
    MockWstETH public wstETH;
    MockWithdrawalQueue public withdrawalQueue;
    LidoAdapter public adapter;
    LidoAdapterDelegateHarness public harness;

    address public vault;
    address public referral = makeAddr("referral");

    function setUp() public {
        weth = new MockWrappedNative();
        lido = new MockLido();
        wstETH = new MockWstETH(address(lido));
        withdrawalQueue = new MockWithdrawalQueue(address(wstETH));
        adapter = new LidoAdapter(address(wstETH), address(withdrawalQueue), address(weth));
        harness = new LidoAdapterDelegateHarness();
        vault = address(harness);

        vm.deal(address(weth), 10_000 ether);
        vm.deal(address(withdrawalQueue), 10_000 ether);
        vm.deal(vault, 1_000 ether);
        weth.mint(vault, 1_000 ether);
        wstETH.mint(vault, 100 ether);
    }

    function test_requestUnstake_shouldEncodeQueueRequestId() public {
        (bytes32 protocolRequestId, uint256 actualReceipts) = harness.requestUnstake(address(adapter), 50 ether);

        assertEq(uint256(protocolRequestId), 1);
        assertEq(actualReceipts, 50 ether);
    }

    function test_isWithdrawalClaimable_shouldDetectFinalizedRequest() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertTrue(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
        assertFalse(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
    }

    function test_isWithdrawalCompleted_shouldTrackAfterClaim() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        vm.prank(vault);
        withdrawalQueue.claimWithdrawal(1);

        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, protocolRequestId));
        assertFalse(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
    }

    function test_isUnstakeBlocked_shouldAlwaysBeFalse() public {
        harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertFalse(adapter.isUnstakeBlocked(vault));
    }

    function test_getAccountingDepositValue_shouldCountOpenWithdrawals() public {
        harness.requestUnstake(address(adapter), 30 ether);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);
        assertEq(accounting, 30 ether + 70 ether);
    }

    function test_getWithdrawalClaimableAt_shouldReturnNowWhenFinalized() public {
        harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(1))), block.timestamp);
    }

    function test_getWithdrawalClaimableAt_shouldReturnEtaWhilePending() public {
        uint256 t0 = block.timestamp;
        harness.requestUnstake(address(adapter), 40 ether);

        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(1))), t0 + 5 days);
    }

    function test_getWithdrawalClaimableAt_shouldReturnZeroForMissingRequest() public {
        assertEq(adapter.getWithdrawalClaimableAt(vault, bytes32(uint256(0))), 0);
    }

    function test_finalizeUnstake_shouldReturnClaimDelta() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId, bytes(""));

        assertEq(amount, 40 ether);
        assertEq(vault.balance, 1_040 ether);
    }

    function test_finalizeUnstake_shouldReturnZeroOnSync() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        vm.prank(vault);
        withdrawalQueue.claimWithdrawal(1);

        uint256 balanceBefore = vault.balance;
        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId, bytes(""));

        assertEq(amount, 0);
        assertEq(vault.balance, balanceBefore);
    }

    function test_recoverStrandedWithdrawals_shouldReturnZero() public {
        assertEq(harness.recoverStrandedWithdrawals(address(adapter), bytes("")), 0);
    }

    function test_stake_shouldMintWstEthViaReceiveShortcut() public {
        uint256 amount = 100 ether;
        uint256 wethBefore = weth.balanceOf(vault);

        uint256 receipts = harness.stake(address(adapter), amount, bytes(""));

        assertEq(receipts, amount);
        assertEq(wstETH.balanceOf(vault), 100 ether + amount);
        assertEq(weth.balanceOf(vault), wethBefore - amount);
    }

    function test_stake_shouldSupportReferralPath() public {
        uint256 amount = 50 ether;

        uint256 receipts = harness.stake(address(adapter), amount, abi.encode(referral));

        assertEq(receipts, amount);
        assertEq(wstETH.balanceOf(vault), 150 ether);
    }

    function test_stake_shouldMintFewerReceiptsWhenRateAboveOne() public {
        wstETH.setRate(1.05e18);

        uint256 receipts = harness.stake(address(adapter), 105 ether, bytes(""));

        assertEq(receipts, 100 ether);
        assertEq(wstETH.balanceOf(vault), 200 ether);
    }

    function test_getStakedReceipts_shouldReturnWalletBalance() public {
        assertEq(adapter.getStakedReceipts(vault), 100 ether);
    }

    function test_getUnstakeableReceipts_shouldReturnWalletBalance() public {
        assertEq(adapter.getUnstakeableReceipts(vault), 100 ether);
    }

    function test_getPendingUnstake_shouldSumOpenRequests() public {
        harness.requestUnstake(address(adapter), 30 ether);
        harness.requestUnstake(address(adapter), 20 ether);

        assertEq(adapter.getPendingUnstake(vault), 50 ether);
    }

    function test_getPendingUnstake_shouldExcludeClaimedRequests() public {
        harness.requestUnstake(address(adapter), 30 ether);
        (bytes32 second,) = harness.requestUnstake(address(adapter), 20 ether);
        withdrawalQueue.finalizeRequest(2);

        vm.prank(vault);
        withdrawalQueue.claimWithdrawal(2);

        assertEq(adapter.getPendingUnstake(vault), 30 ether);
        assertTrue(harness.isWithdrawalCompleted(address(adapter), vault, second));
    }

    function test_getAccountingDepositValue_shouldExcludeWalletReceiptsWhenListed() public {
        harness.requestUnstake(address(adapter), 30 ether);

        uint256 withWallet = adapter.getAccountingDepositValue(vault, false);
        uint256 withoutWallet = adapter.getAccountingDepositValue(vault, true);

        assertEq(withWallet, 100 ether);
        assertEq(withoutWallet, 30 ether);
    }

    function test_getAccountingDepositValue_shouldUseStEthQuoteWhenRateAboveOne() public {
        wstETH.setRate(1.05e18);

        uint256 accounting = adapter.getAccountingDepositValue(vault, false);

        assertEq(accounting, (100 ether * 1.05e18) / 1e18);
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroId() public {
        assertFalse(adapter.isWithdrawalClaimable(vault, bytes32(0)));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseWhilePending() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);

        assertFalse(harness.isWithdrawalClaimable(address(adapter), vault, protocolRequestId));
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroId() public {
        assertFalse(adapter.isWithdrawalCompleted(vault, bytes32(0)));
    }

    function test_isWithdrawalCompleted_shouldReturnFalseForZeroVault() public {
        harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertFalse(adapter.isWithdrawalCompleted(address(0), bytes32(uint256(1))));
    }

    function test_isWithdrawalClaimable_shouldReturnFalseForZeroVault() public {
        harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertFalse(adapter.isWithdrawalClaimable(address(0), bytes32(uint256(1))));
    }


    function test_getProtocolName_shouldReturnLido() public view {
        assertEq(adapter.getProtocolName(), "Lido");
    }

    function test_constructor_shouldRevertZeroWstETH() public {
        vm.expectRevert(LidoAdapter.ZeroAddress.selector);
        new LidoAdapter(address(0), address(withdrawalQueue), address(weth));
    }

    function test_constructor_shouldRevertZeroWithdrawalQueue() public {
        vm.expectRevert(LidoAdapter.ZeroAddress.selector);
        new LidoAdapter(address(wstETH), address(0), address(weth));
    }

    function test_constructor_shouldRevertZeroWrappedNative() public {
        vm.expectRevert(LidoAdapter.ZeroAddress.selector);
        new LidoAdapter(address(wstETH), address(withdrawalQueue), address(0));
    }

    function test_constructor_shouldRevertInvalidStETH() public {
        BadMockWstETH badWstETH = new BadMockWstETH();

        vm.expectRevert(abi.encodeWithSelector(LidoAdapter.InvalidStETHAddress.selector, address(badWstETH)));
        new LidoAdapter(address(badWstETH), address(withdrawalQueue), address(weth));
    }

    function test_getClaimHint_shouldReturnCheckpointHint() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        assertEq(adapter.getClaimHint(protocolRequestId), 1);
    }

    function test_getClaimHint_shouldReturnZeroForMissingRequest() public {
        assertEq(adapter.getClaimHint(bytes32(0)), 0);
    }

    function test_finalizeUnstake_shouldClaimWithHintParam() public {
        (bytes32 protocolRequestId,) = harness.requestUnstake(address(adapter), 40 ether);
        withdrawalQueue.finalizeRequest(1);

        uint256 hint = adapter.getClaimHint(protocolRequestId);
        uint256 amount = harness.finalizeUnstake(address(adapter), protocolRequestId, abi.encode(hint));

        assertEq(amount, 40 ether);
        assertEq(vault.balance, 1_040 ether);
    }
}
