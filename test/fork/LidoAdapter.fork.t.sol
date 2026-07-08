// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {LidoAdapter} from "../../src/adapters/LST/LidoAdapter.sol";
import {IWithdrawalQueue} from "../../src/interfaces/external/lido/IWithdrawalQueue.sol";

/**
 * @notice Smoke fork tests for `LidoAdapter` against live Lido mainnet contracts.
 * @dev Uses a delegatecall harness as the vault — no full diamond deploy required.
 *      Does not cover finalize: Lido withdrawal finalization is async (days + oracle activity).
 *
 * Run:
 *   forge test --match-path test/fork/LidoAdapter.fork.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Env (optional if `--fork-url` is passed):
 *   ETH_RPC_URL | MAINNET_RPC_URL | FORK_URL | FOUNDRY_FORK_URL
 *   LIDO_FORK_BLOCK — pin fork block (optional)
 */
contract LidoAdapterForkTest is Test {
    error ForkRpcRequired();
    error MustForkEthereumMainnet();
    error OwnerOfCallFailed();

    uint256 internal constant ETH_CHAIN_ID = 1;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    uint256 internal constant STAKE_AMOUNT = 1 ether;
    uint256 internal constant UNSTAKE_AMOUNT = 0.4 ether;

    LidoAdapter internal adapter;
    LidoAdapterDelegateHarness internal harness;
    address internal vault;

    function setUp() public {
        if (block.chainid != ETH_CHAIN_ID) {
            string memory rpcUrl = _resolveRpcUrl();
            if (bytes(rpcUrl).length == 0) revert ForkRpcRequired();

            uint256 blockNumber = vm.envOr("LIDO_FORK_BLOCK", uint256(0));
            if (blockNumber == 0) vm.createSelectFork(rpcUrl);
            else vm.createSelectFork(rpcUrl, blockNumber);
        }

        if (block.chainid != ETH_CHAIN_ID) revert MustForkEthereumMainnet();

        adapter = new LidoAdapter(WSTETH, WITHDRAWAL_QUEUE, WETH);
        harness = new LidoAdapterDelegateHarness();
        vault = address(harness);

        deal(WETH, vault, 10 ether);
    }

    function test_fork_stake_shouldMintWstEthViaReceiveShortcut() public {
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(vault);
        uint256 wethBefore = IERC20(WETH).balanceOf(vault);

        uint256 receipts = harness.stake(address(adapter), STAKE_AMOUNT, bytes(""));

        assertGt(receipts, 0, "expected non-zero wstETH minted");
        assertEq(IERC20(WSTETH).balanceOf(vault), wstEthBefore + receipts);
        assertEq(IERC20(WETH).balanceOf(vault), wethBefore - STAKE_AMOUNT);
        assertEq(adapter.getStakedReceipts(vault), IERC20(WSTETH).balanceOf(vault));
    }

    function test_fork_requestUnstake_shouldQueueWithdrawalAndMintUnstEth() public {
        harness.stake(address(adapter), STAKE_AMOUNT, bytes(""));

        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(vault);
        uint256 pendingBefore = adapter.getPendingUnstake(vault);

        (bytes32 protocolRequestId, uint256 actualReceipts) =
            harness.requestUnstake(address(adapter), UNSTAKE_AMOUNT);

        uint256 requestId = uint256(protocolRequestId);
        assertGt(requestId, 0, "expected non-zero Lido request id");
        assertEq(actualReceipts, UNSTAKE_AMOUNT);
        assertEq(_ownerOfUnstEth(requestId), vault, "unstETH NFT should stay on vault");
        assertEq(IERC20(WSTETH).balanceOf(vault), wstEthBefore - UNSTAKE_AMOUNT);

        assertGt(adapter.getPendingUnstake(vault), pendingBefore, "pending unstake should increase");
        assertFalse(adapter.isWithdrawalClaimable(vault, protocolRequestId), "fresh request not claimable yet");
        assertFalse(adapter.isWithdrawalCompleted(vault, protocolRequestId));

        IWithdrawalQueue.WithdrawalRequestStatus memory status = _getRequestStatus(requestId);
        assertEq(status.owner, vault);
        assertFalse(status.isFinalized);
        assertFalse(status.isClaimed);
        assertGt(status.amountOfStETH, 0);
    }

    function test_fork_withdrawalQueue_viewsShouldBeReachable() public view {
        assertGt(IWithdrawalQueue(WITHDRAWAL_QUEUE).getLastCheckpointIndex(), 0);
        assertEq(adapter.getClaimHint(bytes32(0)), 0);
    }

    function _resolveRpcUrl() internal view returns (string memory rpcUrl) {
        rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length != 0) return rpcUrl;

        rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length != 0) return rpcUrl;

        rpcUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(rpcUrl).length != 0) return rpcUrl;

        return vm.envOr("FOUNDRY_FORK_URL", string(""));
    }

    function _ownerOfUnstEth(uint256 requestId) internal view returns (address owner) {
        (bool ok, bytes memory data) =
            WITHDRAWAL_QUEUE.staticcall(abi.encodeWithSignature("ownerOf(uint256)", requestId));
        if (!ok) revert OwnerOfCallFailed();
        owner = abi.decode(data, (address));
    }

    function _getRequestStatus(uint256 requestId)
        internal
        view
        returns (IWithdrawalQueue.WithdrawalRequestStatus memory status)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            IWithdrawalQueue(WITHDRAWAL_QUEUE).getWithdrawalStatus(ids);
        return statuses[0];
    }
}

/// @dev Mirrors unit-test harness: vault executes adapter logic via delegatecall.
contract LidoAdapterDelegateHarness {
    error StakeFailed();
    error RequestUnstakeFailed();

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
}
