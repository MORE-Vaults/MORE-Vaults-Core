// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILSPVault} from "../../src/interfaces/external/sflow/ILSPVault.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFlowReceipt is ERC20 {
    constructor() ERC20("FlowReceipt", "FLOW-R") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockSFlow is ERC20 {
    constructor() ERC20("sFlow", "sFLOW") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockLSPVault is ILSPVault {
    error NothingToClaim();
    error TransferFailed();

    address public immutable S_FLOW_ADDRESS;
    address public immutable FLOW_RECEIPT;

    uint256 private rate = 1e18;
    uint256 public unstakeRequestCount = 1;

    mapping(uint256 => UnstakeRequest) internal unstakeRequestsById;
    mapping(address => uint256) public pendingWithdrawals;

    constructor(address sFlow, address flowReceipt) {
        S_FLOW_ADDRESS = sFlow;
        FLOW_RECEIPT = flowReceipt;
    }

    receive() external payable {}

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function creditPendingWithdrawal(address user, uint256 amount) external payable {
        pendingWithdrawals[user] += amount;
    }

    function requestStake() external payable returns (uint256 requestId) {
        requestId = 0;
        MockFlowReceipt(FLOW_RECEIPT).mint(msg.sender, msg.value);
    }

    function requestUnstake(uint256 amount) external returns (uint256 requestId) {
        IERC20(S_FLOW_ADDRESS).transferFrom(msg.sender, address(this), amount);

        uint256 flowEquivalent = (amount * rate) / 1e18;
        MockFlowReceipt(FLOW_RECEIPT).mint(msg.sender, flowEquivalent);

        requestId = unstakeRequestCount;
        unstakeRequestsById[requestId] = UnstakeRequest({
            status: RequestStatus.QUEUED,
            user: msg.sender,
            amount: amount,
            flowAmount: 0,
            unlockEpoch: 0
        });

        unchecked {
            ++unstakeRequestCount;
        }
    }

    function fulfillStake(address user, uint256 sFlowAmount) external {
        uint256 flowReceiptBal = IERC20(FLOW_RECEIPT).balanceOf(user);
        if (flowReceiptBal > 0) {
            MockFlowReceipt(FLOW_RECEIPT).burn(user, flowReceiptBal);
        }
        MockSFlow(S_FLOW_ADDRESS).mint(user, sFlowAmount);
    }

    function setRequestStatus(uint256 id, RequestStatus status) external {
        unstakeRequestsById[id].status = status;
    }

    function fulfillUnstake(uint256 id, uint256 flowAmount, uint256 unlockEpoch) external {
        UnstakeRequest storage req = unstakeRequestsById[id];
        req.status = RequestStatus.FULFILLED;
        req.flowAmount = flowAmount;
        req.unlockEpoch = unlockEpoch;

        MockFlowReceipt(FLOW_RECEIPT).burn(req.user, (req.amount * rate) / 1e18);
        pendingWithdrawals[req.user] += flowAmount;
    }

    function claimPendingWithdrawal() external {
        uint256 pending = pendingWithdrawals[msg.sender];
        if (pending == 0) revert NothingToClaim();
        pendingWithdrawals[msg.sender] = 0;
        (bool success,) = msg.sender.call{value: pending}("");
        if (!success) revert TransferFailed();
    }

    function getSFlowQuote(uint256 flowWei) external view returns (uint256 sFlowWei) {
        return (flowWei * 1e18) / rate;
    }

    function getFlowQuote(uint256 sFlowWei) external view returns (uint256 flowWei) {
        return (sFlowWei * rate) / 1e18;
    }

    function unstakeRequests(uint256 id)
        external
        view
        returns (RequestStatus status, address user, uint256 amount, uint256 flowAmount, uint256 unlockEpoch)
    {
        UnstakeRequest memory req = unstakeRequestsById[id];
        return (req.status, req.user, req.amount, req.flowAmount, req.unlockEpoch);
    }
}
