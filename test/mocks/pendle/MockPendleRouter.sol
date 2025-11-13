// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPendleRouter} from "../../../src/interfaces/external/pendle/IPendleRouter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockPendleRouter is IPendleRouter {
    address public immutable pt;
    address public immutable sy;
    uint256 public slippageBps = 0;

    constructor(address _pt, address _sy) {
        pt = _pt;
        sy = _sy;
    }

    function swapExactSyForPt(address receiver, address, uint256 exactSyIn, uint256, ApproxParams calldata, LimitOrderData calldata)
        external
        returns (uint256 netPtOut, uint256 netSyFee)
    {
        IERC20(sy).transferFrom(msg.sender, address(this), exactSyIn);

        netSyFee = 0;
        netPtOut = exactSyIn - (exactSyIn * slippageBps / 10000);

        IERC20(pt).transfer(receiver, netPtOut);

        return (netPtOut, netSyFee);
    }

    function swapExactPtForSy(address receiver, address, uint256 exactPtIn, uint256, LimitOrderData calldata)
        external
        returns (uint256 netSyOut, uint256 netSyFee)
    {
        IERC20(pt).transferFrom(msg.sender, address(this), exactPtIn);

        netSyFee = 0;
        netSyOut = exactPtIn - (exactPtIn * slippageBps / 10000);

        IERC20(sy).transfer(receiver, netSyOut);

        return (netSyOut, netSyFee);
    }

    function setSlippageBps(uint256 _slippageBps) external {
        slippageBps = _slippageBps;
    }

    function fundRouter(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
