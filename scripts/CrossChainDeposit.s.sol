// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";

// sepolia testnet deployment script
// forge script scripts/CrossChainDeposit.s.sol:CrossChainDeposit --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/CrossChainDeposit.s.sol:CrossChainDeposit --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract CrossChainDeposit is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        address oftAddress = address(
            0xe17EeA6Df1A59A1b7745541A5D1B94e822D00766
        );
        address toAddress = address(0x0d28781A95959d515ed4F8283964876ce2605Dc2);
        address composer = address(0xFB196A373cc2Ef936E8928d99c4440D7073bA42f);
        uint256 tokensToSend = 1 ether;
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        OFT oft = OFT(oftAddress);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        uint32[] memory eids = new uint32[](1);
        eids[0] = dstEid;
        bytes memory extraOptions = "";

        SendParam memory sendParam = buildSendParam(
            composer,
            toAddress,
            tokensToSend,
            (tokensToSend * 95) / 100,
            dstEid,
            2000000,
            1e14
        );

        // Get fee quote
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("Sending tokens...");
        console.log("Fee amount:", fee.nativeFee);

        // Send tokens
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);

        vm.stopBroadcast();
    }

    function buildSendParam(
        address _composer,
        address _receiver,
        uint256 _tokenAmount,
        uint256 _minAmount,
        uint32 _dstEid,
        uint128 _lzComposeGas,
        uint128 _lzComposeValue
    ) public view returns (SendParam memory sendParam) {
        bytes memory options;
        bytes memory composeMsg = "";
        bytes32 to = addressToBytes32(_receiver);

        if (_lzComposeGas > 0) {
            options = OptionsBuilder
                .newOptions()
                .addExecutorLzReceiveOption(100000, 0)
                .addExecutorLzComposeOption(0, _lzComposeGas, _lzComposeValue);
            SendParam memory hopSendParam = SendParam({
                dstEid: srcEid,
                to: to,
                amountLD: _tokenAmount,
                minAmountLD: _minAmount,
                extraOptions: OptionsBuilder
                    .newOptions()
                    .addExecutorLzReceiveOption(100000, 0),
                composeMsg: composeMsg,
                oftCmd: hex""
            });
            // composeMsg = abi.encode(hopSendParam, _lzComposeValue);
            composeMsg = abi.encode(hopSendParam, _lzComposeValue);
            to = addressToBytes32(_composer);
        }

        sendParam = SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: _tokenAmount,
            minAmountLD: _tokenAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });
    }
}
