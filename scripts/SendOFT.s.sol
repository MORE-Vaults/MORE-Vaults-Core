// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { MoreVaultsComposer } from "../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import { IOracleRegistry, IAggregatorV2V3Interface } from "../src/interfaces/IOracleRegistry.sol";

// sepolia testnet deployment script
// forge script scripts/SendOFT.s.sol:SendOFT --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/SendOFT.s.sol:SendOFT --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1


contract SendOFT is Script {
    using OptionsBuilder for bytes;

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        address oftAddress = address(0xC1C555450d5e9ff507a8851e98E00798eB76F441);
        address toAddress = address(0x0d28781A95959d515ed4F8283964876ce2605Dc2);
        // uint32 dstEid = uint32(40231);
        uint32 dstEid = uint32(40161);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        address vault = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        address shareOFT = address(0x5fEA64D6b231211CD071Cbe2c7De634943B33Bcb);
        address lzAdapter = address(0xb659E4559766f0bBACA63dd2CBFe07e7fe674F97);
        address vaultFactory = address(0x1b3c1BF5c8a772dF2db965817b904B8dAabc2B56);
        address oracleRegistry = address(0xFF53387bC0E1e4A731C52288b62036A199E5d885);
        uint256 tokensToSend = OFT(oftAddress).balanceOf(0x0d28781A95959d515ed4F8283964876ce2605Dc2);

        OFT oft = OFT(oftAddress);

        // Build send parameters
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0);
        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: addressToBytes32(toAddress),
            amountLD: tokensToSend,
            minAmountLD: tokensToSend * 95 / 100, // 5% slippage tolerance
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        // Get fee quote
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("Sending tokens...");
        console.log("Fee amount:", fee.nativeFee);

        // Send tokens
        oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);

        vm.stopBroadcast();
    }
}