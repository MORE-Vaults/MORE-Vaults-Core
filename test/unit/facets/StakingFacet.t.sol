// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StakingFacet} from "../../../src/facets/StakingFacet.sol";
import {StakingFacetStorage} from "../../../src/libraries/StakingFacetStorage.sol";
import {IStakingFacet} from "../../../src/interfaces/facets/IStakingFacet.sol";
import {IProtocolAdapter} from "../../../src/interfaces/IProtocolAdapter.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockProtocolAdapter} from "../../mocks/MockProtocolAdapter.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StakingFacetTest is Test {
    using Math for uint256;

    StakingFacet public stakingFacet;
    MockProtocolAdapter public mockAdapter;
    MockERC20 public depositToken;
    MockERC20 public receiptToken;

    address public owner = address(9999);
    address public curator = address(7);
    address public registry = address(1000);
    address public protocol = address(2000);
    address public user = address(1);
    address public oracleRegistry = address(1001);
    address public oracle = address(1002);

    uint256 constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        stakingFacet = new StakingFacet();

        depositToken = new MockERC20("Deposit Token", "DT");
        receiptToken = new MockERC20("Receipt Token", "RT");

        mockAdapter = new MockProtocolAdapter(address(depositToken), address(receiptToken));

        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(stakingFacet), registry);
        MoreVaultsStorageHelper.setOwner(address(stakingFacet), owner);
        MoreVaultsStorageHelper.setCurator(address(stakingFacet), curator);

        vm.mockCall(
            address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleRegistry)
        );

        vm.mockCall(
            address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector), abi.encode(true)
        );

        bytes memory initData = abi.encode(bytes4(keccak256("accountingStakingFacet()")));
        stakingFacet.initialize(initData);

        depositToken.mint(address(mockAdapter), INITIAL_BALANCE);
        receiptToken.mint(address(mockAdapter), INITIAL_BALANCE);
        depositToken.mint(user, INITIAL_BALANCE);
    }

    function test_Initialize() public {
        assertEq(stakingFacet.facetName(), "StakingFacet");
        assertEq(stakingFacet.facetVersion(), "1.0.0");
    }

    function test_AddProtocol() public {
        StakingFacetStorage.ProtocolConfig memory config = StakingFacetStorage.ProtocolConfig({
            protocolAddress: protocol,
            protocolType: StakingFacetStorage.ProtocolType.LIQUID_STAKING,
            depositToken: address(depositToken),
            receiptToken: address(receiptToken),
            adapter: address(mockAdapter),
            isActive: true,
            stakedBalance: 0
        });

        vm.prank(owner);
        stakingFacet.addProtocol(protocol, config);

        address[] memory activeProtocols = stakingFacet.getActiveProtocols();
        assertEq(activeProtocols.length, 1);
        assertEq(activeProtocols[0], protocol);

        StakingFacetStorage.ProtocolConfig memory storedConfig = stakingFacet.getProtocolConfig(protocol);
        assertEq(storedConfig.adapter, address(mockAdapter));
        assertTrue(storedConfig.isActive);
    }

    function test_RevertWhen_AddProtocol_NotOwner() public {
        StakingFacetStorage.ProtocolConfig memory config = StakingFacetStorage.ProtocolConfig({
            protocolAddress: protocol,
            protocolType: StakingFacetStorage.ProtocolType.LIQUID_STAKING,
            depositToken: address(depositToken),
            receiptToken: address(receiptToken),
            adapter: address(mockAdapter),
            isActive: true,
            stakedBalance: 0
        });

        vm.prank(user);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        stakingFacet.addProtocol(protocol, config);
    }

    function test_RevertWhen_AddProtocol_AlreadyExists() public {
        StakingFacetStorage.ProtocolConfig memory config = StakingFacetStorage.ProtocolConfig({
            protocolAddress: protocol,
            protocolType: StakingFacetStorage.ProtocolType.LIQUID_STAKING,
            depositToken: address(depositToken),
            receiptToken: address(receiptToken),
            adapter: address(mockAdapter),
            isActive: true,
            stakedBalance: 0
        });

        vm.prank(owner);
        stakingFacet.addProtocol(protocol, config);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.ProtocolAlreadyExists.selector, protocol));
        stakingFacet.addProtocol(protocol, config);
    }

    function test_Stake() public {
        _addProtocol();

        uint256 stakeAmount = 100 ether;

        vm.startPrank(curator);
        depositToken.mint(curator, stakeAmount);
        depositToken.approve(address(stakingFacet), stakeAmount);

        uint256 receipts = stakingFacet.stake(protocol, address(depositToken), stakeAmount, "");
        vm.stopPrank();

        assertEq(receipts, stakeAmount);
        assertEq(stakingFacet.getStakedBalance(protocol), stakeAmount);
        assertEq(receiptToken.balanceOf(address(stakingFacet)), stakeAmount);
    }

    function test_RevertWhen_Stake_ProtocolNotActive() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(curator);
        depositToken.approve(address(stakingFacet), stakeAmount);

        vm.expectRevert(abi.encodeWithSelector(StakingFacetStorage.ProtocolNotActive.selector, protocol));
        stakingFacet.stake(protocol, address(depositToken), stakeAmount, "");
        vm.stopPrank();
    }

    function test_RevertWhen_Stake_NotCurator() public {
        _addProtocol();

        uint256 stakeAmount = 100 ether;

        vm.startPrank(user);
        depositToken.approve(address(stakingFacet), stakeAmount);

        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        stakingFacet.stake(protocol, address(depositToken), stakeAmount, "");
        vm.stopPrank();
    }

    function test_RequestUnstake() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        vm.startPrank(curator);
        receiptToken.approve(address(stakingFacet), stakeAmount);

        bytes32 requestId = stakingFacet.requestUnstake(protocol, stakeAmount, "");
        vm.stopPrank();

        assertTrue(requestId != bytes32(0));
        assertEq(stakingFacet.getStakedBalance(protocol), 0);

        StakingFacetStorage.WithdrawalRequest memory request = stakingFacet.getWithdrawalRequest(requestId);
        assertEq(request.amount, stakeAmount);
        assertEq(request.user, curator);
        assertFalse(request.finalized);
    }

    function test_RevertWhen_RequestUnstake_InsufficientBalance() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        uint256 unstakeAmount = 200 ether;

        vm.startPrank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFacetStorage.InsufficientStakedBalance.selector, unstakeAmount, stakeAmount
            )
        );
        stakingFacet.requestUnstake(protocol, unstakeAmount, "");
        vm.stopPrank();
    }

    function test_FinalizeUnstake() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        vm.startPrank(curator);
        receiptToken.approve(address(stakingFacet), stakeAmount);
        bytes32 requestId = stakingFacet.requestUnstake(protocol, stakeAmount, "");
        vm.stopPrank();

        StakingFacetStorage.WithdrawalRequest memory request = stakingFacet.getWithdrawalRequest(requestId);
        mockAdapter.setWithdrawalClaimable(request.protocolRequestId, true);

        vm.warp(block.timestamp + 8 days);

        vm.prank(curator);
        uint256 amount = stakingFacet.finalizeUnstake(requestId);

        assertEq(amount, stakeAmount);

        StakingFacetStorage.WithdrawalRequest memory finalRequest = stakingFacet.getWithdrawalRequest(requestId);
        assertTrue(finalRequest.finalized);
    }

    function test_RevertWhen_FinalizeUnstake_BeforeTimelock() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        vm.startPrank(curator);
        receiptToken.approve(address(stakingFacet), stakeAmount);
        bytes32 requestId = stakingFacet.requestUnstake(protocol, stakeAmount, "");
        vm.stopPrank();

        mockAdapter.setWithdrawalClaimable(requestId, true);

        vm.warp(block.timestamp + 1 days);

        vm.prank(curator);
        vm.expectRevert();
        stakingFacet.finalizeUnstake(requestId);
    }

    function test_AccountingStakingFacet() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        mockAdapter.setValueInETH(1.1e18);

        (uint256 sum, bool isPositive) = stakingFacet.accountingStakingFacet();

        assertTrue(isPositive);
        assertEq(sum, 110 ether);
    }

    function test_CircuitBreaker_Triggers() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        mockAdapter.setValueInETH(1e18);
        stakingFacet.accountingStakingFacet();

        vm.warp(block.timestamp + 30 minutes);

        mockAdapter.setValueInETH(0.96e18);

        stakingFacet.accountingStakingFacet();

        vm.expectRevert(StakingFacetStorage.CircuitBreakerActive.selector);
        stakingFacet.accountingStakingFacet();
    }

    function test_CircuitBreaker_DoesNotTrigger_SlowDrop() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        mockAdapter.setValueInETH(1e18);
        stakingFacet.accountingStakingFacet();

        vm.warp(block.timestamp + 2 hours);

        mockAdapter.setValueInETH(0.96e18);

        (uint256 sum, bool isPositive) = stakingFacet.accountingStakingFacet();
        assertTrue(isPositive);
        assertGt(sum, 0);
    }

    function test_RemoveProtocol() public {
        _addProtocol();

        vm.prank(owner);
        stakingFacet.removeProtocol(protocol);

        address[] memory activeProtocols = stakingFacet.getActiveProtocols();
        assertEq(activeProtocols.length, 0);
    }

    function test_RevertWhen_RemoveProtocol_HasBalance() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StakingFacetStorage.ProtocolHasBalance.selector, protocol, stakeAmount)
        );
        stakingFacet.removeProtocol(protocol);
    }

    function test_GetTotalStakedValue() public {
        _addProtocol();
        uint256 stakeAmount = 100 ether;
        _stakeTokens(stakeAmount);

        mockAdapter.setValueInETH(1.05e18);

        uint256 totalValue = stakingFacet.getTotalStakedValue();
        assertEq(totalValue, 105 ether);
    }

    function _addProtocol() internal {
        StakingFacetStorage.ProtocolConfig memory config = StakingFacetStorage.ProtocolConfig({
            protocolAddress: protocol,
            protocolType: StakingFacetStorage.ProtocolType.LIQUID_STAKING,
            depositToken: address(depositToken),
            receiptToken: address(receiptToken),
            adapter: address(mockAdapter),
            isActive: true,
            stakedBalance: 0
        });

        vm.prank(owner);
        stakingFacet.addProtocol(protocol, config);
    }

    function _stakeTokens(uint256 amount) internal {
        vm.startPrank(curator);
        depositToken.mint(curator, amount);
        depositToken.approve(address(stakingFacet), amount);
        stakingFacet.stake(protocol, address(depositToken), amount, "");
        vm.stopPrank();
    }
}
