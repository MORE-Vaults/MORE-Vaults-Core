// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IOFT,
    SendParam,
    MessagingFee,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract MockOFTAdapter is IOFT {
    address public underlyingToken;
    bool public approvalRequiredFlag = true;
    address public endpointAddr;

    mapping(address => mapping(address => uint256)) public allowance;

    function setUnderlyingToken(address _token) external {
        underlyingToken = _token;
    }

    function setApprovalRequired(bool v) external {
        approvalRequiredFlag = v;
    }

    function setEndpoint(address e) external {
        endpointAddr = e;
    }

    // IOAppCore-compatible surface
    function endpoint() external view returns (address) {
        return endpointAddr;
    }

    // IOFT
    function oftVersion() external pure returns (bytes4, uint64) {
        return (bytes4(0x02e49c2c), 1);
    }

    function token() external view returns (address) {
        return underlyingToken;
    }

    function approvalRequired() external view returns (bool) {
        return approvalRequiredFlag;
    }

    function sharedDecimals() external pure returns (uint8) {
        return 18;
    }
    // Dummy to satisfy interface; we won't use directly in tests

    function quoteOFT(SendParam calldata)
        external
        pure
        returns (OFTLimit memory limit, OFTFeeDetail[] memory feeDetails, OFTReceipt memory receipt)
    {
        limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
        feeDetails = new OFTFeeDetail[](0);
        receipt = OFTReceipt({amountSentLD: 0, amountReceivedLD: 0});
    }

    function quoteSend(SendParam calldata, bool) external pure returns (MessagingFee memory) {
        return MessagingFee(0.01 ether, 0);
    }

    function send(SendParam calldata _sendParam, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        require(msg.value >= fee.nativeFee, "fee");
        return (MessagingReceipt(bytes32(uint256(1)), 1, fee), OFTReceipt(_sendParam.amountLD, _sendParam.amountLD));
    }

    // Minimal helper to satisfy forceApprove in tests
    function forceApprove(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}
