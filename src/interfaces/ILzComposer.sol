// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILzComposer {
    function completeDeposit(bytes32 guid) external;

    function refundDeposit(bytes32 guid) external;
}
