// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockLST} from "./MockLST.sol";

/**
 * @notice Thin stateless adapter for tests. Protocol logic lives in MockLST.
 * @dev Execution functions only forward to lstPool and are safe under StakingFacet delegatecall.
 */
contract MockProtocolAdapter is IProtocolAdapter {
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

    function requestUnstake(uint256 receipts, bytes calldata) external returns (bytes32 requestId, uint256 actualReceipts) {
        MockLST lst = MockLST(lstPool);
        address receipt = address(lst.receiptToken());
        IERC20(receipt).forceApprove(lstPool, receipts);
        requestId = lst.requestUnstake(receipts);
        IERC20(receipt).forceApprove(lstPool, 0);
        actualReceipts = receipts;
    }

    function finalizeUnstake(bytes32 requestId, bytes calldata params) external returns (uint256 amount) {
        MockLST lst = MockLST(lstPool);
        if (lst.isCompleted(requestId)) {
            return 0;
        }
        return lst.claim(requestId, address(this));
    }

    function recoverStrandedWithdrawals(bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest() external virtual {}

    function isWithdrawalClaimable(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isClaimable(requestId);
    }

    function isWithdrawalCompleted(address, bytes32 requestId) external view returns (bool) {
        return MockLST(lstPool).isCompleted(requestId);
    }

    function getWithdrawalClaimableAt(address, bytes32 requestId) external view returns (uint256) {
        return MockLST(lstPool).getWithdrawalClaimableAt(requestId);
    }

    function isUnstakeBlocked(address) external view virtual returns (bool) {
        return false;
    }

    function getProtocolName() external pure returns (string memory) {
        return "MockProtocol";
    }
}
