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
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {IBridgeAdapter} from "../src/interfaces/IBridgeAdapter.sol";
import {IDiamondCut} from "../src/interfaces/facets/IDiamondCut.sol";
import {BridgeFacet} from "../src/facets/BridgeFacet.sol";
import {IMoreVaultsRegistry} from "../src/interfaces/IMoreVaultsRegistry.sol";
import {IVaultFacet} from "../src/interfaces/facets/IVaultFacet.sol";
import {MoreVaultsComposer} from "../src/cross-chain/layerZero/MoreVaultsComposer.sol";

// sepolia testnet deployment script
// forge script scripts/TotalAssetsUSD.s.sol:TotalAssetsUSD --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/TotalAssetsUSD.s.sol:TotalAssetsUSD --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract TotalAssetsUSD is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        address oftTokenAddress = address(0xC19419653441fEcc486B3F1f013f2392e01915D5);
        address lzAdapterAddress = address(0x0d4b16Abba0C3bDE9266097328a61BD6D40E29E5);
        uint32 lzEid = uint32(40231);
        uint256 amount = 1e18;
        address dstVaultAddress = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        address mockUsdf = address(0xe17EeA6Df1A59A1b7745541A5D1B94e822D00766);

        address registry = address(0x1D490dF882151569E23bCe273aEa8FE2d9bab1A9);
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

        // vm.startBroadcast(privateKey);

        (uint256 totalAssets, bool success) = IVaultFacet(localVault).totalAssetsUsd();
        console.log("Local vault total assets:", totalAssets);
        console.log("Success:", success);
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = IBridgeFacet(localVault).getRequestInfo(hex"e06b573899a419a35ab9fdd6f93cde105dea98b1e63f112d57d0a24c2e7f95bd");
        console.log("Request info:");
        console.log("Initiator:", requestInfo.initiator);
        console.log("Timestamp:", requestInfo.timestamp);
        console.log("Action type:", uint8(requestInfo.actionType));
        console.log("Action call data:");
        console.logBytes(requestInfo.actionCallData);
        console.log("Fulfilled:", requestInfo.fulfilled);
        console.log("Total assets:", requestInfo.totalAssets);



        bytes memory _message = hex"91d20fa1000000000000000000000000c19419653441fecc486b3f1f013f2392e01915d500000000000000000000000081a7e4cb371e123be99112bb3f38beceffbf6a6f85611d39b7bea181f6d34749bb4fecaec6f535bd32bc7f19e13630b3a905bc01000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000001ec000000000000000f00009d270000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000d28781a95959d515ed4f8283964876ce2605dc20000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000009d27000000000000000000000000b10c12547799688f2893530c80cf625f4a1938700000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000d2f13f7789f000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000016000301001101000000000000000000000000000186a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        // (uint256 sum, bool readSuccess) = abi.decode(_message, (uint256, bool));
        // console.log("Sum:", sum);
        // console.log("Read success:", readSuccess);

        address composer = address(0x81A7e4Cb371e123be99112Bb3F38BECeFFBF6a6f);
        // MoreVaultsComposer vaultComposer = new MoreVaultsComposer();
        // vm.etch(composer, address(vaultComposer).code);

        address enpointVerifiedUser = address(0xF5E8A439C599205C1aB06b535DE46681Aed1007a);
        vm.prank(enpointVerifiedUser);
        address endpoint = address(0x718B92b5CB0a5552039B593faF724D182A881eDA);
        (success, ) = endpoint.call{value: 133220769027179}(hex"cfc325700000000000000000000000000000000000000000000000000000000000000020000000000000000000000000166e8415c8aa9f9e2274146f72b7782d2488fb0800000000000000000000000000000000000000000000000000000000ffffffff000000000000000000000000166e8415c8aa9f9e2274146f72b7782d2488fb080000000000000000000000000000000000000000000000000000000000000004c0da5cd5504323a6bd7e5693b9d0267d397503855bb8bdc7900d9121e9314436000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000087ba000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000005f5d0d900000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000");
        if (!success) revert("Failed to call endpoint");
        // vm.stopBroadcast();
    }
}
