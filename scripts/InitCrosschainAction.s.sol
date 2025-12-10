// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {ITransparentUpgradeableProxy, ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBridgeFacet} from "../src/interfaces/facets/IBridgeFacet.sol";
import {MoreVaultsLib} from "../src/libraries/MoreVaultsLib.sol";
import {IMulticallFacet} from "../src/interfaces/facets/IMulticallFacet.sol";
import {IConfigurationFacet} from "../src/interfaces/facets/IConfigurationFacet.sol";
import {LzAdapter} from "../src/cross-chain/layerZero/LzAdapter.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";

// sepolia testnet deployment script
// forge script scripts/InitCrosschainAction.s.sol:InitCrosschainAction --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/InitCrosschainAction.s.sol:InitCrosschainAction --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract InitCrosschainAction is Script {
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
        address lzAdapterAddress = address(0xe46944039DEc7dD4C28a4Dd6aAB0271d0c257076);

        vm.startBroadcast(privateKey);

        address endpointAddress = address(
            0x6EDCE65403992e310A62460808c4b910D972f10f
        );

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IConfigurationFacet.setCrossChainAccountingManager.selector, lzAdapterAddress);

        IMulticallFacet(localVault).submitActions(
            actions
        );

        // // Get fee quote
        // address[] memory vaults = new address[](1);
        // vaults[0] = localVault;
        // uint32[] memory eids = new uint32[](1);
        // eids[0] = remoteEid;
        // bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReadOption(200000, 64, 0);
        // MessagingFee memory fee = IBridgeAdapter(lzAdapterAddress).quoteReadFee(vaults, eids, extraOptions);
        // console.log("Fee:", fee.nativeFee);

        // IBridgeFacet(localVault).initVaultActionRequest{value: fee.nativeFee}(
        //     MoreVaultsLib.ActionType.DEPOSIT,
        //     abi.encode(1e18, address(0xb10C12547799688F2893530c80Cf625f4A193870)),
        //     extraOptions
        // );

        // IBridgeFacet(localVault).finalizeRequest(bytes32(0xeb4a510f89cbe575d1e9396fe1fc15dbc648cf679ab174b8f0afcd61cb2a5499));
        // LzAdapter lzAdapter = LzAdapter(
        //     CREATE3.deployDeterministic(
        //         abi.encodePacked(
        //             type(LzAdapter).creationCode,
        //             abi.encode(
        //                 endpointAddress,
        //                 address(0x0d28781A95959d515ed4F8283964876ce2605Dc2),
        //                 uint32(1),
        //                 address(0x1b3c1BF5c8a772dF2db965817b904B8dAabc2B56),
        //                 address(0x1D490dF882151569E23bCe273aEa8FE2d9bab1A9)
        //             )
        //         ),
        //         keccak256(abi.encode("lzAdapterCrossChainTest555"))
        //     )
        // );
        // console.log("Lz adapter deployed at:", address(lzAdapter));

        console.log("Requesting init vault action...");

        vm.stopBroadcast();
    }
}
