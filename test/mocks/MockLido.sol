// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./MockERC20.sol";
import {ILido} from "../../src/interfaces/external/lido/ILido.sol";
import {IWstETH} from "../../src/interfaces/external/lido/IWstETH.sol";
import {IWithdrawalQueue} from "../../src/interfaces/external/lido/IWithdrawalQueue.sol";

contract MockStETH is MockERC20 {
    constructor() MockERC20("stETH", "stETH") {}
}

/// @dev Simplified wstETH: 1 share == 1 wstETH token unit; rate drifts via pooledEthPerShare.
contract MockWstETH is MockERC20, IWstETH {
    using SafeERC20 for IERC20;

    error ZeroWrap();
    error ZeroUnwrap();

    address public immutable stETHAddress;
    uint256 public pooledEthPerShare = 1e18;

    constructor(address _stETH) MockERC20("wstETH", "wstETH") {
        stETHAddress = _stETH;
    }

    function stETH() external view returns (address) {
        return stETHAddress;
    }

    function setRate(uint256 _pooledEthPerShare) external {
        pooledEthPerShare = _pooledEthPerShare;
    }

    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount) {
        if (stETHAmount == 0) revert ZeroWrap();
        wstETHAmount = (stETHAmount * 1e18) / pooledEthPerShare;
        IERC20(stETHAddress).transferFrom(msg.sender, address(this), stETHAmount);
        _mint(msg.sender, wstETHAmount);
    }

    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount) {
        if (wstETHAmount == 0) revert ZeroUnwrap();
        stETHAmount = getStETHByWstETH(wstETHAmount);
        _burn(msg.sender, wstETHAmount);
        IERC20(stETHAddress).transfer(msg.sender, stETHAmount);
    }

    function getStETHByWstETH(uint256 wstETHAmount) public view returns (uint256 stETHAmount) {
        return (wstETHAmount * pooledEthPerShare) / 1e18;
    }

    function getWstETHByStETH(uint256 stETHAmount) public view returns (uint256 wstETHAmount) {
        return (stETHAmount * 1e18) / pooledEthPerShare;
    }

    receive() external payable {
        uint256 stETHAmount = ILido(stETHAddress).submit{value: msg.value}(address(0));
        uint256 wstETHAmount = getWstETHByStETH(stETHAmount);
        _mint(msg.sender, wstETHAmount);
    }
}

contract MockLido is MockStETH, ILido {
    function submit(address) external payable returns (uint256 stETHAmount) {
        stETHAmount = msg.value;
        _mint(msg.sender, stETHAmount);
    }
}

contract MockWithdrawalQueue is IWithdrawalQueue {
    using SafeERC20 for IERC20;

    error LengthMismatch();
    error BadHint();
    error NotOwner();
    error NotFinalized();
    error AlreadyClaimed();
    error TransferFailed();

    IERC20 public immutable wstETH;
    uint256 public nextRequestId = 1;

    mapping(uint256 => WithdrawalRequestStatus) internal _requests;
    mapping(address => uint256[]) internal _ownerRequests;

    constructor(address _wstETH) {
        wstETH = IERC20(_wstETH);
    }

    function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner)
        external
        returns (uint256[] memory requestIds)
    {
        requestIds = new uint256[](amounts.length);
        for (uint256 i; i < amounts.length;) {
            uint256 amount = amounts[i];
            wstETH.safeTransferFrom(msg.sender, address(this), amount);

            uint256 requestId = nextRequestId++;
            uint256 stETHAmount = IWstETH(address(wstETH)).getStETHByWstETH(amount);

            _requests[requestId] = WithdrawalRequestStatus({
                amountOfStETH: stETHAmount,
                amountOfShares: amount,
                owner: owner,
                timestamp: block.timestamp,
                isFinalized: false,
                isClaimed: false
            });
            _ownerRequests[owner].push(requestId);
            requestIds[i] = requestId;

            unchecked {
                ++i;
            }
        }
    }

    function finalizeRequest(uint256 requestId) external {
        _requests[requestId].isFinalized = true;
    }

    function getLastCheckpointIndex() external pure returns (uint256) {
        return 1;
    }

    function findCheckpointHints(uint256[] calldata requestIds, uint256, uint256)
        external
        pure
        returns (uint256[] memory hintIds)
    {
        hintIds = new uint256[](requestIds.length);
        for (uint256 i; i < requestIds.length;) {
            hintIds[i] = 1;
            unchecked {
                ++i;
            }
        }
    }

    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external {
        if (requestIds.length != hints.length) revert LengthMismatch();
        for (uint256 i; i < requestIds.length;) {
            if (hints[i] == 0) revert BadHint();
            _claimTo(requestIds[i], msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    function claimWithdrawal(uint256 requestId) external {
        _claimTo(requestId, msg.sender);
    }

    function _claimTo(uint256 requestId, address recipient) private {
        WithdrawalRequestStatus storage status = _requests[requestId];
        if (status.owner != recipient) revert NotOwner();
        if (!status.isFinalized) revert NotFinalized();
        if (status.isClaimed) revert AlreadyClaimed();

        status.isClaimed = true;
        (bool success,) = recipient.call{value: status.amountOfStETH}("");
        if (!success) revert TransferFailed();
    }

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory requestIds) {
        return _ownerRequests[owner];
    }

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new WithdrawalRequestStatus[](requestIds.length);
        for (uint256 i; i < requestIds.length;) {
            statuses[i] = _requests[requestIds[i]];
            unchecked {
                ++i;
            }
        }
    }

    receive() external payable {}
}
