// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IStandardizedYield} from "../interfaces/external/pendle/IStandardizedYield.sol";
import {IPrincipalToken} from "../interfaces/external/pendle/IPrincipalToken.sol";
import {IPYieldToken} from "../interfaces/external/pendle/IPYieldToken.sol";
import {IPMarket} from "../interfaces/external/pendle/IPMarket.sol";
import {IPendleRouter} from "../interfaces/external/pendle/IPendleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PendleAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    address public immutable depositToken;
    address public immutable receiptToken;
    address public immutable market;
    address public immutable router;

    IStandardizedYield public immutable sy;
    IPrincipalToken public immutable pt;
    IPYieldToken public immutable yt;

    mapping(bytes32 => uint256) public withdrawalAmounts;
    uint256 private requestCounter;

    error InvalidMarket();
    error InvalidDepositToken();
    error WithdrawalNotFound();

    constructor(address _depositToken, address _market, address _router) {
        depositToken = _depositToken;
        market = _market;
        router = _router;

        (address _sy, address _pt,) = IPMarket(_market).readTokens();
        if (_sy == address(0) || _pt == address(0)) revert InvalidMarket();

        sy = IStandardizedYield(_sy);
        pt = IPrincipalToken(_pt);
        yt = IPYieldToken(pt.YT());
        receiptToken = _pt;

        address[] memory tokensIn = sy.getTokensIn();
        bool validToken = false;
        for (uint256 i = 0; i < tokensIn.length; i++) {
            if (tokensIn[i] == _depositToken) {
                validToken = true;
                break;
            }
        }
        if (!validToken) revert InvalidDepositToken();
    }

    function stake(uint256 amount, bytes calldata) external returns (uint256 receipts) {
        IERC20(depositToken).safeTransferFrom(msg.sender, address(this), amount);

        IERC20(depositToken).forceApprove(address(sy), amount);
        uint256 syAmount = sy.deposit(address(this), depositToken, amount, 0, false);

        IERC20(address(sy)).forceApprove(router, syAmount);

        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14
        });

        IPendleRouter.LimitOrderData memory limit = IPendleRouter.LimitOrderData({
            limitRouter: address(0),
            epsSkipMarket: 0,
            normalFills: new IPendleRouter.FillOrderParams[](0),
            flashFills: new IPendleRouter.FillOrderParams[](0),
            optData: ""
        });

        (receipts,) = IPendleRouter(router).swapExactSyForPt(msg.sender, market, syAmount, 0, approx, limit);

        return receipts;
    }

    function requestUnstake(uint256 receipts, bytes calldata) external returns (bytes32 requestId) {
        IERC20(receiptToken).safeTransferFrom(msg.sender, address(this), receipts);

        requestId = keccak256(abi.encodePacked(msg.sender, block.timestamp, requestCounter++));
        uint256 syAmount;

        if (pt.isExpired()) {
            IERC20(receiptToken).safeTransfer(address(yt), receipts);
            syAmount = yt.redeemPY(address(this));
        } else {
            IERC20(receiptToken).forceApprove(router, receipts);

            IPendleRouter.LimitOrderData memory limit = IPendleRouter.LimitOrderData({
                limitRouter: address(0),
                epsSkipMarket: 0,
                normalFills: new IPendleRouter.FillOrderParams[](0),
                flashFills: new IPendleRouter.FillOrderParams[](0),
                optData: ""
            });

            (syAmount,) = IPendleRouter(router).swapExactPtForSy(address(this), market, receipts, 0, limit);
        }

        withdrawalAmounts[requestId] = syAmount;

        return requestId;
    }

    function finalizeUnstake(bytes32 requestId) external returns (uint256 amount) {
        uint256 syAmount = withdrawalAmounts[requestId];
        if (syAmount == 0) revert WithdrawalNotFound();

        delete withdrawalAmounts[requestId];

        amount = sy.redeem(msg.sender, syAmount, depositToken, 0, false);

        return amount;
    }

    function harvest() external pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](0);
        amounts = new uint256[](0);
        return (tokens, amounts);
    }

    function getPendingRewards() external pure returns (uint256) {
        return 0;
    }

    function getDepositTokenForReceipts(uint256 receiptAmount) external view returns (uint256) {
        if (pt.isExpired()) {
            return sy.previewRedeem(depositToken, receiptAmount);
        }

        uint256 ptToSyRate = IPMarket(market).getPtToSyRate(900);
        uint256 syAmount = (receiptAmount * ptToSyRate) / 1e18;

        return sy.previewRedeem(depositToken, syAmount);
    }

    function isWithdrawalClaimable(bytes32 requestId) external view returns (bool) {
        return withdrawalAmounts[requestId] > 0;
    }

    function getProtocolName() external pure returns (string memory) {
        return "Pendle";
    }
}
