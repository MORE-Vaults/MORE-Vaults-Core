// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// sepolia testnet deployment script
// forge script scripts/LzReceiveTest.s.sol:LzReceiveTest --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/LzReceiveTest.s.sol:LzReceiveTest --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract LzReceiveTest is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        address factoryAddress = address(
            0x1b3c1BF5c8a772dF2db965817b904B8dAabc2B56
        );
        address endpointAddress = address(
            0x6EDCE65403992e310A62460808c4b910D972f10f
        );
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");

        VaultsFactory newVaultsFactoryImpl = new VaultsFactory(endpointAddress);


        VaultsFactory factory = VaultsFactory(factoryAddress);
        vm.startPrank(address(0x5B5F654b53782e7DAA736b788c178025Ad13Ca7E));
        ITransparentUpgradeableProxy(factoryAddress).upgradeToAndCall(address(newVaultsFactoryImpl), "");

        // Get fee quote
        vm.startPrank(address(0xF5E8A439C599205C1aB06b535DE46681Aed1007a));
        (bool success, ) = address(0x718B92b5CB0a5552039B593faF724D182A881eDA).call(hex"cfc3257000000000000000000000000000000000000000000000000000000000000000200000000000000000000000001b3c1bf5c8a772df2db965817b904b8daabc2b560000000000000000000000000000000000000000000000000000000000009d270000000000000000000000001b3c1bf5c8a772df2db965817b904b8daabc2b5600000000000000000000000000000000000000000000000000000000000000021797694ac18a597fbd0036ffcb03171b718a81c47833b4395ea3716e801c4450000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000230e300000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000060000000000000000000000000639c07ea78dffc22eaf726f9d85380622b1187e8000000000000000000000000639c07ea78dffc22eaf726f9d85380622b1187e80000000000000000000000000d28781a95959d515ed4f8283964876ce2605dc20000000000000000000000000000000000000000000000000000000000000000");

        if (!success) {
            revert("Failed to call factory");
        }
        console.log("Requesting register spoke...");

        // vm.stopBroadcast();
    }
}
