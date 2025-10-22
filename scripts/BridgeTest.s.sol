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
import {VaultFacet} from "../src/facets/VaultFacet.sol";
import {IVaultFacet} from "../src/interfaces/facets/IVaultFacet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IVaultFacet, IERC4626, IERC20, VaultFacet} from "../src/facets/VaultFacet.sol";
import {IOracleRegistry, IAggregatorV2V3Interface} from "../src/interfaces/IOracleRegistry.sol";

// sepolia testnet deployment script
// forge script scripts/BridgeTest.s.sol:BridgeTest --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/BridgeTest.s.sol:BridgeTest --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract BridgeTest is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        // address oftTokenAddress = address(0xC19419653441fEcc486B3F1f013f2392e01915D5);
        // address lzAdapterAddress = address(0x0d4b16Abba0C3bDE9266097328a61BD6D40E29E5);
        // uint32 lzEid = uint32(40231);
        // uint256 amount = 1e18;
        // address dstVaultAddress = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        // address mockUsdf = address(0xe17EeA6Df1A59A1b7745541A5D1B94e822D00766);

        address registry = address(0x1D490dF882151569E23bCe273aEa8FE2d9bab1A9);
        address oracleRegistry = address(0xFF53387bC0E1e4A731C52288b62036A199E5d885);
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

        // VaultFacet oldVaultFacet = VaultFacet(0xA43f555BbE6D2ab21275F0d6E7A7bAc0B298c82E);
        // VaultFacet vaultFacet = new VaultFacet();
        // // bytes4[] memory functionSelectorsBridgeFacet = new bytes4[](6);
        //  // selectors for vault
        // bytes4[] memory functionSelectorsVaultFacet = new bytes4[](35);
        // functionSelectorsVaultFacet[0] = IERC20Metadata.name.selector;
        // functionSelectorsVaultFacet[1] = IERC20Metadata.symbol.selector;
        // functionSelectorsVaultFacet[2] = IERC20Metadata.decimals.selector;
        // functionSelectorsVaultFacet[3] = IERC20.balanceOf.selector;
        // functionSelectorsVaultFacet[4] = IERC20.approve.selector;
        // functionSelectorsVaultFacet[5] = IERC20.transfer.selector;
        // functionSelectorsVaultFacet[6] = IERC20.transferFrom.selector;
        // functionSelectorsVaultFacet[7] = IERC20.allowance.selector;
        // functionSelectorsVaultFacet[8] = IERC20.totalSupply.selector;
        // functionSelectorsVaultFacet[9] = IERC4626.asset.selector;
        // functionSelectorsVaultFacet[10] = IERC4626.totalAssets.selector;
        // functionSelectorsVaultFacet[11] = IERC4626.convertToAssets.selector;
        // functionSelectorsVaultFacet[12] = IERC4626.convertToShares.selector;
        // functionSelectorsVaultFacet[13] = IERC4626.maxDeposit.selector;
        // functionSelectorsVaultFacet[14] = IERC4626.previewDeposit.selector;
        // functionSelectorsVaultFacet[15] = IERC4626.deposit.selector;
        // functionSelectorsVaultFacet[16] = IERC4626.maxMint.selector;
        // functionSelectorsVaultFacet[17] = IERC4626.previewMint.selector;
        // functionSelectorsVaultFacet[18] = IERC4626.mint.selector;
        // functionSelectorsVaultFacet[19] = IERC4626.maxWithdraw.selector;
        // functionSelectorsVaultFacet[20] = IERC4626.previewWithdraw.selector;
        // functionSelectorsVaultFacet[21] = IERC4626.withdraw.selector;
        // functionSelectorsVaultFacet[22] = IERC4626.maxRedeem.selector;
        // functionSelectorsVaultFacet[23] = IERC4626.previewRedeem.selector;
        // functionSelectorsVaultFacet[24] = IERC4626.redeem.selector;
        // functionSelectorsVaultFacet[25] = bytes4(
        //     keccak256("deposit(address[],uint256[],address)")
        // );
        // functionSelectorsVaultFacet[26] = IVaultFacet.paused.selector;
        // functionSelectorsVaultFacet[27] = IVaultFacet.pause.selector;
        // functionSelectorsVaultFacet[28] = IVaultFacet.unpause.selector;
        // functionSelectorsVaultFacet[29] = IVaultFacet.totalAssetsUsd.selector;
        // functionSelectorsVaultFacet[30] = IVaultFacet.setFee.selector;
        // functionSelectorsVaultFacet[31] = IVaultFacet.requestRedeem.selector;
        // functionSelectorsVaultFacet[32] = IVaultFacet.requestWithdraw.selector;
        // functionSelectorsVaultFacet[33] = IVaultFacet.clearRequest.selector;
        // functionSelectorsVaultFacet[34] = IVaultFacet
        //     .getWithdrawalRequest
        //     .selector;

        // bytes memory initDataVaultFacet = "";
        // IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        // cuts[0] = IDiamondCut.FacetCut({
        //     facetAddress: address(0),
        //     action: IDiamondCut.FacetCutAction.Remove,
        //     functionSelectors: functionSelectorsVaultFacet,
        //     initData: abi.encode(true)
        // });
        // cuts[1] = IDiamondCut.FacetCut({
        //     facetAddress: address(vaultFacet),
        //     action: IDiamondCut.FacetCutAction.Add,
        //     functionSelectors: functionSelectorsVaultFacet,
        //     initData: ""
        // });
        // IMoreVaultsRegistry(registry).removeFacet(address(oldVaultFacet));
        // IMoreVaultsRegistry(registry).addFacet(address(vaultFacet), functionSelectorsVaultFacet);

        //  bytes4[] memory oldFunctionSelectorsBridgeFacet = new bytes4[](6);
        //   oldFunctionSelectorsBridgeFacet[0] = IBridgeFacet.executeBridging.selector;
        // oldFunctionSelectorsBridgeFacet[1] = IBridgeFacet
        //     .initVaultActionRequest
        //     .selector;
        // oldFunctionSelectorsBridgeFacet[2] = IBridgeFacet
        //     .updateAccountingInfoForRequest
        //     .selector;
        // oldFunctionSelectorsBridgeFacet[3] = IBridgeFacet.finalizeRequest.selector;
        // oldFunctionSelectorsBridgeFacet[4] = IBridgeFacet.getRequestInfo.selector;
        // oldFunctionSelectorsBridgeFacet[5] = IBridgeFacet
        //     .setOraclesCrossChainAccounting
        //     .selector;

        bytes4[] memory functionSelectorsBridgeFacet = new bytes4[](8);
          functionSelectorsBridgeFacet[0] = IBridgeFacet.executeBridging.selector;
        functionSelectorsBridgeFacet[1] = IBridgeFacet
            .initVaultActionRequest
            .selector;
        functionSelectorsBridgeFacet[2] = IBridgeFacet
            .updateAccountingInfoForRequest
            .selector;
        functionSelectorsBridgeFacet[3] = IBridgeFacet.finalizeRequest.selector;
        functionSelectorsBridgeFacet[4] = IBridgeFacet.getRequestInfo.selector;
        functionSelectorsBridgeFacet[5] = IBridgeFacet
            .setOraclesCrossChainAccounting
            .selector;
        functionSelectorsBridgeFacet[6] = IBridgeFacet.accountingBridgeFacet.selector;
        functionSelectorsBridgeFacet[7] = IBridgeFacet.quoteAccountingFee.selector;

        BridgeFacet bridgeFacet = new BridgeFacet();

        address oldBridgeFacet= address(0x20D010947E2b5E5CB7f12E6bCF6107a56913D055);

        IMoreVaultsRegistry(registry).removeFacet(oldBridgeFacet);
        IMoreVaultsRegistry(registry).addFacet(address(bridgeFacet), functionSelectorsBridgeFacet);

         IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: functionSelectorsBridgeFacet,
            initData: abi.encode(true)
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(bridgeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsBridgeFacet,
            initData: ""
        });

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts);


        IMulticallFacet(localVault).submitActions(
            actions
        );

        // address[] memory assets = new address[](1);
        // assets[0] = address(0xe17EeA6Df1A59A1b7745541A5D1B94e822D00766); // USDF OFT
        // address[] memory sources = new address[](1);
        // sources[0] = address(0xeFa945739700803b8f10398Ed4f19168Be9bFC92); // USDC Aggregator
        // uint96[] memory confidence = new uint96[](1);
        // confidence[0] = uint96(1760470695);
        // IOracleRegistry.OracleInfo[]
        //     memory infos = new IOracleRegistry.OracleInfo[](1);
        // infos[0] = IOracleRegistry.OracleInfo({
        //     aggregator: IAggregatorV2V3Interface(sources[0]),
        //     stalenessThreshold: confidence[0]
        // });
        // IOracleRegistry(oracleRegistry).setOracleInfos(assets, infos);

        (uint256 totalAssets, bool success) = IVaultFacet(localVault).totalAssetsUsd();
        console.log("Total assets:", totalAssets);
        console.log("Success:", success);
        

        // address endpointAddress = address(
        //     0x6EDCE65403992e310A62460808c4b910D972f10f
        // );

        // bytes memory bridgeSpecificParams = abi.encode(oftTokenAddress, lzEid, amount, dstVaultAddress, address(0x0d28781A95959d515ed4F8283964876ce2605Dc2));
        // uint256 fee = IBridgeAdapter(lzAdapterAddress).quoteBridgeFee(bridgeSpecificParams);

        // // actions = new bytes[](1);
        // // actions[0] = abi.encodeWithSelector(IBridgeFacet.executeBridging.selector, lzAdapterAddress, mockUsdf, amount, bridgeSpecificParams);

        // // IMulticallFacet(localVault).submitActions(
        // //     actions
        // // );

        // IBridgeFacet(localVault).executeBridging{value: fee}(lzAdapterAddress, mockUsdf, amount, bridgeSpecificParams);
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
