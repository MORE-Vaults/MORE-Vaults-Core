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
// forge script scripts/FixVault.s.sol:FixVault --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast

// arbitrum sepolia testnet deployment script
// forge script scripts/FixVault.s.sol:FixVault --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast

contract FixVault is Script {
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

        vm.startBroadcast(privateKey);
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

        FixHelperFacet fixHelperFacet = new FixHelperFacet();

        bytes4[] memory functionSelectorsFixHelperFacet = new bytes4[](1);
        functionSelectorsFixHelperFacet[0] = fixHelperFacet.somePlaceHolderFunction.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(fixHelperFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsFixHelperFacet,
            initData: ""
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: functionSelectorsFixHelperFacet,
            initData: ""
        });

        IMoreVaultsRegistry(registry).addFacet(address(fixHelperFacet), functionSelectorsFixHelperFacet);

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts);


        IMulticallFacet(localVault).submitActions(
            actions
        );
        IMoreVaultsRegistry(registry).removeFacet(address(fixHelperFacet));

        vm.stopBroadcast();
    }
}
