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
import {VaultFacet, IERC4626, IERC20, IVaultFacet} from "../src/facets/VaultFacet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {FixHelperFacet} from "../src/facets/FixHelperFacet.sol";

// sepolia testnet deployment script
// forge script scripts/DepositTest.s.sol:DepositTest --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/DepositTest.s.sol:DepositTest --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract DepositTest is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        uint256 blockNumber = 9452734;
        string memory MAINNET_RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE";
        uint256 mainnetFork = vm.createFork(MAINNET_RPC_URL, blockNumber);
        vm.selectFork(mainnetFork);

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

        VaultFacet oldVaultFacet = VaultFacet(0x7143607ec462bAc5C2624a2EAfa777895cb2D053);
        VaultFacet vaultFacet = new VaultFacet();
         // selectors for vault
        bytes4[] memory functionSelectorsVaultFacet = new bytes4[](35);
        functionSelectorsVaultFacet[0] = IERC20Metadata.name.selector;
        functionSelectorsVaultFacet[1] = IERC20Metadata.symbol.selector;
        functionSelectorsVaultFacet[2] = IERC20Metadata.decimals.selector;
        functionSelectorsVaultFacet[3] = IERC20.balanceOf.selector;
        functionSelectorsVaultFacet[4] = IERC20.approve.selector;
        functionSelectorsVaultFacet[5] = IERC20.transfer.selector;
        functionSelectorsVaultFacet[6] = IERC20.transferFrom.selector;
        functionSelectorsVaultFacet[7] = IERC20.allowance.selector;
        functionSelectorsVaultFacet[8] = IERC20.totalSupply.selector;
        functionSelectorsVaultFacet[9] = IERC4626.asset.selector;
        functionSelectorsVaultFacet[10] = IERC4626.totalAssets.selector;
        functionSelectorsVaultFacet[11] = IERC4626.convertToAssets.selector;
        functionSelectorsVaultFacet[12] = IERC4626.convertToShares.selector;
        functionSelectorsVaultFacet[13] = IERC4626.maxDeposit.selector;
        functionSelectorsVaultFacet[14] = IERC4626.previewDeposit.selector;
        functionSelectorsVaultFacet[15] = IERC4626.deposit.selector;
        functionSelectorsVaultFacet[16] = IERC4626.maxMint.selector;
        functionSelectorsVaultFacet[17] = IERC4626.previewMint.selector;
        functionSelectorsVaultFacet[18] = IERC4626.mint.selector;
        functionSelectorsVaultFacet[19] = IERC4626.maxWithdraw.selector;
        functionSelectorsVaultFacet[20] = IERC4626.previewWithdraw.selector;
        functionSelectorsVaultFacet[21] = IERC4626.withdraw.selector;
        functionSelectorsVaultFacet[22] = IERC4626.maxRedeem.selector;
        functionSelectorsVaultFacet[23] = IERC4626.previewRedeem.selector;
        functionSelectorsVaultFacet[24] = IERC4626.redeem.selector;
        functionSelectorsVaultFacet[25] = bytes4(
            keccak256("deposit(address[],uint256[],address)")
        );
        functionSelectorsVaultFacet[26] = IVaultFacet.paused.selector;
        functionSelectorsVaultFacet[27] = IVaultFacet.pause.selector;
        functionSelectorsVaultFacet[28] = IVaultFacet.unpause.selector;
        functionSelectorsVaultFacet[29] = IVaultFacet.totalAssetsUsd.selector;
        functionSelectorsVaultFacet[30] = IVaultFacet.setFee.selector;
        functionSelectorsVaultFacet[31] = IVaultFacet.requestRedeem.selector;
        functionSelectorsVaultFacet[32] = IVaultFacet.requestWithdraw.selector;
        functionSelectorsVaultFacet[33] = IVaultFacet.clearRequest.selector;
        functionSelectorsVaultFacet[34] = IVaultFacet
            .getWithdrawalRequest
            .selector;

        bytes memory initDataVaultFacet = "";

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

        address oldBridgeFacet= address(0xf33d57413A5428C0Dd48a4562cC6e2310E710962);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: functionSelectorsVaultFacet,
            initData: abi.encode(true)
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsVaultFacet,
            initData: ""
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: functionSelectorsBridgeFacet,
            initData: abi.encode(true)
        });
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(bridgeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsBridgeFacet,
            initData: ""
        });
        vm.startPrank(address(0x0d28781A95959d515ed4F8283964876ce2605Dc2));
        IMoreVaultsRegistry(registry).removeFacet(address(oldVaultFacet));
        IMoreVaultsRegistry(registry).addFacet(address(vaultFacet), functionSelectorsVaultFacet);
        IMoreVaultsRegistry(registry).removeFacet(oldBridgeFacet);
        IMoreVaultsRegistry(registry).addFacet(address(bridgeFacet), functionSelectorsBridgeFacet);

        // FixHelperFacet fixHelperFacet = new FixHelperFacet();

        // bytes4[] memory functionSelectorsFixHelperFacet = new bytes4[](1);
        // functionSelectorsFixHelperFacet[0] = fixHelperFacet.somePlaceHolderFunction.selector;

        // IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        // cuts[0] = IDiamondCut.FacetCut({
        //     facetAddress: address(fixHelperFacet),
        //     action: IDiamondCut.FacetCutAction.Add,
        //     functionSelectors: functionSelectorsFixHelperFacet,
        //     initData: ""
        // });
        // cuts[1] = IDiamondCut.FacetCut({
        //     facetAddress: address(0),
        //     action: IDiamondCut.FacetCutAction.Remove,
        //     functionSelectors: functionSelectorsFixHelperFacet,
        //     initData: ""
        // });

        // IMoreVaultsRegistry(registry).addFacet(address(fixHelperFacet), functionSelectorsFixHelperFacet);

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts);


        IMulticallFacet(localVault).submitActions(
            actions
        );
        // IMoreVaultsRegistry(registry).removeFacet(address(fixHelperFacet));

        bytes memory _message = hex"91d20fa1000000000000000000000000c19419653441fecc486b3f1f013f2392e01915d500000000000000000000000081a7e4cb371e123be99112bb3f38beceffbf6a6f85611d39b7bea181f6d34749bb4fecaec6f535bd32bc7f19e13630b3a905bc01000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000001ec000000000000000f00009d270000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000d28781a95959d515ed4f8283964876ce2605dc20000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000009d27000000000000000000000000b10c12547799688f2893530c80cf625f4a1938700000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000d2f13f7789f000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000016000301001101000000000000000000000000000186a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        // (uint256 sum, bool readSuccess) = abi.decode(_message, (uint256, bool));
        // console.log("Sum:", sum);
        // console.log("Read success:", readSuccess);

        address composer = address(0x81A7e4Cb371e123be99112Bb3F38BECeFFBF6a6f);
        // MoreVaultsComposer vaultComposer = new MoreVaultsComposer();
        // vm.etch(composer, address(vaultComposer).code);

        address enpointVerifiedUser = address(0xF5E8A439C599205C1aB06b535DE46681Aed1007a);
        vm.stopPrank();
        vm.prank(enpointVerifiedUser);
        address endpoint = address(0x718B92b5CB0a5552039B593faF724D182A881eDA);
        (success, ) = endpoint.call{value: 133220769027179}(hex"7cd44734000000000000000000000000c19419653441fecc486b3f1f013f2392e01915d5000000000000000000000000fb196a373cc2ef936e8928d99c4440d7073ba42fcde69e4c19df26638998594a9d32f14779e89a4fa0c2ad5425f38173610aa43e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000001ef9b000000000000000000000000000000000000000000000000000000000000001ec000000000000001b00009d270000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000d28781a95959d515ed4f8283964876ce2605dc2000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000005af3107a40000000000000000000000000000000000000000000000000000000000000009d270000000000000000000000000d28781a95959d515ed4f8283964876ce2605dc20000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000d2f13f7789f000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000016000301001101000000000000000000000000000186a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");
        if (!success) revert("Failed to call endpoint");
        // vm.stopBroadcast();
    }
}
