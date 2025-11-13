// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {PendleAdapter} from "../../../src/adapters/PendleAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockStandardizedYield} from "../../mocks/pendle/MockStandardizedYield.sol";
import {MockPrincipalToken} from "../../mocks/pendle/MockPrincipalToken.sol";
import {MockYieldToken} from "../../mocks/pendle/MockYieldToken.sol";
import {MockPendleMarket} from "../../mocks/pendle/MockPendleMarket.sol";
import {MockPendleRouter} from "../../mocks/pendle/MockPendleRouter.sol";

contract PendleAdapterTest is Test {
    PendleAdapter public adapter;
    MockERC20 public depositToken;
    MockStandardizedYield public sy;
    MockPrincipalToken public pt;
    MockYieldToken public yt;
    MockPendleMarket public market;
    MockPendleRouter public router;

    address public user = address(1);
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public expiry;

    function setUp() public {
        depositToken = new MockERC20("WETH", "WETH");

        expiry = block.timestamp + 365 days;

        sy = new MockStandardizedYield(address(depositToken));
        yt = new MockYieldToken(address(0), address(sy));
        pt = new MockPrincipalToken(address(sy), address(yt), expiry);
        yt.setPT(address(pt));
        market = new MockPendleMarket(address(sy), address(pt), address(yt), expiry);
        router = new MockPendleRouter(address(pt), address(sy));

        adapter = new PendleAdapter(address(depositToken), address(market), address(router));

        depositToken.mint(user, INITIAL_BALANCE);
        depositToken.mint(address(sy), INITIAL_BALANCE * 2);
        depositToken.mint(address(yt), INITIAL_BALANCE);
        depositToken.mint(address(router), INITIAL_BALANCE);
        depositToken.mint(address(this), INITIAL_BALANCE);

        pt.mint(address(router), INITIAL_BALANCE);

        depositToken.approve(address(sy), INITIAL_BALANCE);
        uint256 syAmount = sy.deposit(address(yt), address(depositToken), INITIAL_BALANCE / 2, 0, false);
    }

    function test_Constructor() public view {
        assertEq(adapter.depositToken(), address(depositToken));
        assertEq(adapter.receiptToken(), address(pt));
        assertEq(adapter.market(), address(market));
        assertEq(adapter.router(), address(router));
    }

    function test_GetProtocolName() public view {
        assertEq(adapter.getProtocolName(), "Pendle");
    }

    function test_Stake() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);

        uint256 receipts = adapter.stake(stakeAmount, "");
        vm.stopPrank();

        assertEq(pt.balanceOf(user), receipts);
        assertGt(receipts, 0);
    }

    function test_Stake_WithSlippage() public {
        router.setSlippageBps(50);

        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);

        uint256 receipts = adapter.stake(stakeAmount, "");
        vm.stopPrank();

        assertLt(receipts, stakeAmount);
        assertEq(receipts, stakeAmount - (stakeAmount * 50 / 10000));
    }

    function test_RequestUnstake_PreMaturity() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");

        pt.approve(address(adapter), receipts);
        bytes32 requestId = adapter.requestUnstake(receipts, "");
        vm.stopPrank();

        assertTrue(adapter.isWithdrawalClaimable(requestId));
        assertGt(adapter.withdrawalAmounts(requestId), 0);
    }

    function test_RequestUnstake_PostMaturity() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");
        vm.stopPrank();

        vm.warp(expiry + 1);

        vm.startPrank(user);
        pt.approve(address(adapter), receipts);
        bytes32 requestId = adapter.requestUnstake(receipts, "");
        vm.stopPrank();

        assertTrue(adapter.isWithdrawalClaimable(requestId));
        assertEq(adapter.withdrawalAmounts(requestId), receipts);
    }

    function test_FinalizeUnstake() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");

        pt.approve(address(adapter), receipts);
        bytes32 requestId = adapter.requestUnstake(receipts, "");

        uint256 balanceBefore = depositToken.balanceOf(user);
        uint256 amount = adapter.finalizeUnstake(requestId);
        uint256 balanceAfter = depositToken.balanceOf(user);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, amount);
        assertFalse(adapter.isWithdrawalClaimable(requestId));
    }

    function test_RevertWhen_FinalizeUnstake_NotFound() public {
        bytes32 fakeRequestId = keccak256("fake");

        vm.expectRevert(PendleAdapter.WithdrawalNotFound.selector);
        adapter.finalizeUnstake(fakeRequestId);
    }

    function test_GetDepositTokenForReceipts_PreMaturity() public {
        market.setPtToSyRate(0.95e18);

        uint256 ptAmount = 100 ether;
        uint256 expectedValue = (ptAmount * 0.95e18) / 1e18;

        uint256 value = adapter.getDepositTokenForReceipts(ptAmount);

        assertEq(value, expectedValue);
    }

    function test_GetDepositTokenForReceipts_PostMaturity() public {
        vm.warp(expiry + 1);

        uint256 ptAmount = 100 ether;
        uint256 value = adapter.getDepositTokenForReceipts(ptAmount);

        assertEq(value, ptAmount);
    }

    function test_GetDepositTokenForReceipts_PriceAppreciation() public {
        uint256 ptAmount = 100 ether;

        market.setPtToSyRate(0.90e18);
        uint256 value1 = adapter.getDepositTokenForReceipts(ptAmount);

        market.setPtToSyRate(0.95e18);
        uint256 value2 = adapter.getDepositTokenForReceipts(ptAmount);

        market.setPtToSyRate(0.99e18);
        uint256 value3 = adapter.getDepositTokenForReceipts(ptAmount);

        assertLt(value1, value2);
        assertLt(value2, value3);
    }

    function test_GetDepositTokenForReceipts_WithSYExchangeRate() public {
        sy.setExchangeRate(1.05e18);
        market.setPtToSyRate(0.95e18);

        uint256 ptAmount = 100 ether;
        uint256 value = adapter.getDepositTokenForReceipts(ptAmount);

        uint256 expectedSyAmount = (ptAmount * 0.95e18) / 1e18;
        uint256 expectedValue = (expectedSyAmount * 1.05e18) / 1e18;

        assertEq(value, expectedValue);
    }

    function test_Harvest() public view {
        (address[] memory tokens, uint256[] memory amounts) = adapter.harvest();

        assertEq(tokens.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_GetPendingRewards() public view {
        assertEq(adapter.getPendingRewards(), 0);
    }

    function test_FullCycle_PreMaturity() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");

        uint256 valueAfterStake = adapter.getDepositTokenForReceipts(receipts);
        assertApproxEqAbs(valueAfterStake, stakeAmount, 0.1 ether);

        pt.approve(address(adapter), receipts);
        bytes32 requestId = adapter.requestUnstake(receipts, "");

        uint256 balanceBefore = depositToken.balanceOf(user);
        adapter.finalizeUnstake(requestId);
        uint256 balanceAfter = depositToken.balanceOf(user);
        vm.stopPrank();

        assertApproxEqAbs(balanceAfter - balanceBefore, stakeAmount, 0.1 ether);
    }

    function test_FullCycle_PostMaturity() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");
        vm.stopPrank();

        vm.warp(expiry + 1);

        uint256 valueAtMaturity = adapter.getDepositTokenForReceipts(receipts);
        assertEq(valueAtMaturity, receipts);

        vm.startPrank(user);
        pt.approve(address(adapter), receipts);
        bytes32 requestId = adapter.requestUnstake(receipts, "");

        uint256 balanceBefore = depositToken.balanceOf(user);
        adapter.finalizeUnstake(requestId);
        uint256 balanceAfter = depositToken.balanceOf(user);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, stakeAmount);
    }

    function test_MaturityTransition() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount);
        uint256 receipts = adapter.stake(stakeAmount, "");
        vm.stopPrank();

        market.setPtToSyRate(0.98e18);
        uint256 valuePreMaturity = adapter.getDepositTokenForReceipts(receipts);

        vm.warp(expiry + 1);

        uint256 valuePostMaturity = adapter.getDepositTokenForReceipts(receipts);

        assertLt(valuePreMaturity, valuePostMaturity);
        assertEq(valuePostMaturity, receipts);
    }

    function test_MultipleUnstakeRequests() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(adapter), stakeAmount * 2);
        uint256 receipts1 = adapter.stake(stakeAmount, "");
        uint256 receipts2 = adapter.stake(stakeAmount, "");

        pt.approve(address(adapter), receipts1 + receipts2);
        bytes32 requestId1 = adapter.requestUnstake(receipts1, "");
        bytes32 requestId2 = adapter.requestUnstake(receipts2, "");

        assertTrue(adapter.isWithdrawalClaimable(requestId1));
        assertTrue(adapter.isWithdrawalClaimable(requestId2));

        adapter.finalizeUnstake(requestId1);
        assertFalse(adapter.isWithdrawalClaimable(requestId1));
        assertTrue(adapter.isWithdrawalClaimable(requestId2));

        adapter.finalizeUnstake(requestId2);
        assertFalse(adapter.isWithdrawalClaimable(requestId2));
        vm.stopPrank();
    }
}
