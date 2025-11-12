// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {ITransparentUpgradeableProxy, ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// sepolia testnet deployment script
// forge script scripts/RequestRegisterSpoke.s.sol:RequestRegisterSpoke --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/RequestRegisterSpoke.s.sol:RequestRegisterSpoke --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract RequestRegisterSpoke is Script {
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
        address localVault = address(
            0x639c07EA78dFfC22eAf726F9d85380622b1187E8
        );
        address remoteVault = address(
            0x639c07EA78dFfC22eAf726F9d85380622b1187E8
        );
        uint32 remoteEid = uint32(40161);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        address endpointAddress = address(
            0x6EDCE65403992e310A62460808c4b910D972f10f
        );
        VaultsFactory newVaultsFactoryImpl = new VaultsFactory(endpointAddress);
        VaultsFactory factory = VaultsFactory(factoryAddress);
        ProxyAdmin(address(0x5B5F654b53782e7DAA736b788c178025Ad13Ca7E))
            .upgradeAndCall(
                ITransparentUpgradeableProxy(factoryAddress),
                address(newVaultsFactoryImpl),
                ""
            );

        // Get fee quote
        // vm.startPrank(address(0x0d28781A95959d515ed4F8283964876ce2605Dc2));
        // factory.requestRegisterSpoke{value: 90317624706559}(
        //     remoteEid,
        //     remoteVault,
        //     localVault,
        //     OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0)
        // );

        console.log("Requesting register spoke...");

        vm.stopBroadcast();
    }
}
