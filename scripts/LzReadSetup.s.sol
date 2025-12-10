// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { ExecutorOptions } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { ReadLibConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/readlib/ReadLibBase.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { LzAdapter } from "../src/cross-chain/layerZero/LzAdapter.sol";
import { MoreVaultsComposer } from "../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import { VaultsFactory } from "../src/factory/VaultsFactory.sol";
import { IMulticallFacet } from "../src/interfaces/facets/IMulticallFacet.sol";
import { IConfigurationFacet } from "../src/interfaces/facets/IConfigurationFacet.sol";
import { IMoreVaultsRegistry } from "../src/interfaces/IMoreVaultsRegistry.sol";

// sepolia testnet deployment script
// forge script scripts/LzReadSetup.s.sol:LzReadSetup --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract LzReadSetup is Script {
    using OptionsBuilder for bytes;

    uint32 public constant READ_CHANNEL = 4294967295; // LayerZero Read Channel ID
    address public constant ENDPOINT_ADDRESS = 0x6EDCE65403992e310A62460808c4b910D972f10f; // LayerZero V2 Endpoint
    address public constant READ_LIB_ADDRESS = 0x908E86e9cb3F16CC94AE7569Bf64Ce2CE04bbcBE; // ReadLib1002 address for your chain - UPDATE THIS
    address public constant READ_COMPATIBLE_DVN = 0x530fBe405189204EF459Fa4B767167e4d41E3a37; // DVN that supports read operations - UPDATE THIS
    address public constant EXECUTOR_ADDRESS = 0x718B92b5CB0a5552039B593faF724D182A881eDA; // Executor address - UPDATE THIS

    // Contract addresses to configure - SET THESE AFTER DEPLOYMENT
    address public lzAdapterAddress;

    function setUp() public {
        // Set your deployed ReadPublic contract address here
        // lzAdapterAddress = address(0x0d4b16Abba0C3bDE9266097328a61BD6D40E29E5);
    }

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(privateKey);

        address registry = address(0x1D490dF882151569E23bCe273aEa8FE2d9bab1A9);
        VaultsFactory factory = VaultsFactory(0x1b3c1BF5c8a772dF2db965817b904B8dAabc2B56);
        LzAdapter lzAdapter = new LzAdapter(
            ENDPOINT_ADDRESS,
            address(0x0d28781A95959d515ed4F8283964876ce2605Dc2),
            READ_CHANNEL,
            address(factory),
            address(registry)
        );
        lzAdapterAddress = address(lzAdapter);
        address[] memory ofts = new address[](1);
        bool[] memory trustedOFTs = new bool[](1);
        ofts[0] = address(0xC19419653441fEcc486B3F1f013f2392e01915D5);
        trustedOFTs[0] = true;
        lzAdapter.setTrustedOFTs(ofts, trustedOFTs);
        factory.setLzAdapter(lzAdapterAddress);

        MoreVaultsComposer vaultComposer = new MoreVaultsComposer();

        address vault = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        address shareOftAddress = address(
            0x5fEA64D6b231211CD071Cbe2c7De634943B33Bcb
        );
        vaultComposer.initialize(vault, shareOftAddress, address(factory));
        factory.setVaultComposer(vault, address(vaultComposer));

        IMoreVaultsRegistry(registry).setIsCrossChainAccountingManager(lzAdapterAddress, true);

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IConfigurationFacet.setCrossChainAccountingManager.selector, lzAdapterAddress);

        IMulticallFacet(vault).submitActions(
            actions
        );

        console.log("Configuring ReadPublic contract at:", lzAdapterAddress);

        // Get contract instances
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);

        // 1. Set Read Library (only on source chain)
        console.log("Step 1: Setting Read Library...");
        endpoint.setSendLibrary(lzAdapterAddress, READ_CHANNEL, READ_LIB_ADDRESS);
        endpoint.setReceiveLibrary(lzAdapterAddress, READ_CHANNEL, READ_LIB_ADDRESS, 0);

        // 2. Configure DVNs (must support target chains you want to read from)
        console.log("Step 2: Configuring DVNs...");
        SetConfigParam[] memory params = new SetConfigParam[](1);

        address[] memory requiredDVNs = new address[](1);
        requiredDVNs[0] = READ_COMPATIBLE_DVN;

        address[] memory optionalDVNs = new address[](0);

        params[0] = SetConfigParam({
            eid: READ_CHANNEL,
            configType: 1, // LZ_READ_LID_CONFIG_TYPE
            config: abi.encode(ReadLibConfig({
                executor: EXECUTOR_ADDRESS, // Executor address - UPDATE THIS
                requiredDVNCount: 1,
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: requiredDVNs,
                optionalDVNs: optionalDVNs
            }))
        });
        endpoint.setConfig(lzAdapterAddress, READ_LIB_ADDRESS, params);

        // 3. Activate Read Channel (enables receiving responses)
        console.log("Step 3: Activating Read Channel...");
        lzAdapter.setReadChannel(READ_CHANNEL, true);

        // 4. Set Enforced Options (with lzRead-specific options)
        console.log("Step 4: Setting Enforced Options...");
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: READ_CHANNEL,
            msgType: 1, // READ_MSG_TYPE
            options: OptionsBuilder.newOptions().addExecutorLzReadOption(2000000, 64, 0)
        });
        lzAdapter.setEnforcedOptions(enforcedOptions);

        // EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        // enforcedOptions[0] = EnforcedOptionParam({
        //     eid: 40231,
        //     msgType: 1, // SEND_MSG_TYPE
        //     options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(100000, 0)
        // });
        // LzAdapter(0xC19419653441fEcc486B3F1f013f2392e01915D5).setEnforcedOptions(enforcedOptions);

        console.log("Configuration complete!");

        vm.stopBroadcast();
    }
}