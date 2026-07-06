// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockProtocolAdapter} from "./MockProtocolAdapter.sol";

contract HarvestRevertAdapter is MockProtocolAdapter {
    constructor(address lstPool) MockProtocolAdapter(lstPool) {}

    function harvest() external pure override {
        revert("harvest failed");
    }
}
