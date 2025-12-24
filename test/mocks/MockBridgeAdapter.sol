// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {
    MessagingReceipt,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract MockBridgeAdapter is IBridgeAdapter {
    bool public _paused;
    address public lastCaller;
    bytes public lastParams;
    bytes32 private _guid;
    MessagingFee private fee;

    function setReceiptGuid(bytes32 guid) external {
        _guid = guid;
    }

    function setFee(uint256 nativeFee, uint256 lzTokenFee) external {
        fee = MessagingFee({nativeFee: nativeFee, lzTokenFee: lzTokenFee});
    }

    function quoteReadFee(address[] memory, uint32[] memory, bytes calldata)
        external
        view
        returns (MessagingFee memory)
    {
        return fee;
    }

    function executeBridging(bytes calldata bridgeSpecificParams) external payable {
        lastCaller = msg.sender;
        lastParams = bridgeSpecificParams;
    }

    function initiateCrossChainAccounting(address[] memory, uint32[] memory, bytes calldata, address)
        external
        payable
        returns (MessagingReceipt memory)
    {
        MessagingReceipt memory r;
        bytes32 g = _guid;
        assembly {
            mstore(r, g)
        }
        return r;
    }

    function setReadChannel(uint32, bool) external {}
    function rescueToken(address, address payable, uint256) external {}

    function quoteBridgeFee(bytes calldata) external view returns (uint256) {
        return fee.nativeFee;
    }

    function pause() external {
        _paused = true;
    }

    function unpause() external {
        _paused = false;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function setSlippage(uint256) external {}
    function setComposer(address) external {}
    function pauseEid(uint32) external {}
    function unpauseEid(uint32) external {}

    function isEidPaused(uint32) external pure returns (bool) {
        return false;
    }

    function setTrustedOFTs(address[] calldata, bool[] calldata) external {}

    function isTrustedOFT(address) external pure returns (bool) {
        return true;
    }

    function getTrustedOFTs() external pure returns (address[] memory) {
        address[] memory a;
        return a;
    }
}
