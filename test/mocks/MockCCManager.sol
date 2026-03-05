// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    MessagingReceipt,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Mock cross-chain accounting manager for local E2E tests.
/// Returns zero fees and generates deterministic guids. The vault's
/// updateAccountingInfoForRequest + executeRequest must be called
/// manually (impersonating this contract) to finalize async requests.
/// NOTE: Does NOT inherit IBridgeAdapter to avoid implementing irrelevant functions.
contract MockCCManager {
    uint64 public nonceCounter;

    function quoteReadFee(address[] memory, uint32[] memory, bytes calldata)
        external
        pure
        returns (MessagingFee memory fee)
    {
        fee = MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function initiateCrossChainAccounting(
        address[] memory,
        uint32[] memory,
        bytes calldata,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt) {
        nonceCounter++;
        bytes32 guid = keccak256(abi.encode(_initiator, nonceCounter, block.timestamp));
        receipt = MessagingReceipt({
            guid: guid,
            nonce: nonceCounter,
            fee: MessagingFee({nativeFee: 0, lzTokenFee: 0})
        });
    }

    function defaultCrossChainAccountingManager() external view returns (address) {
        return address(this);
    }

    receive() external payable {}
}
