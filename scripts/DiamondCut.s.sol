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
import {IERC7540Facet, ERC7540Facet} from "../src/facets/ERC7540Facet.sol";
import {IDiamondCut} from "../src/interfaces/facets/IDiamondCut.sol";

//  ethereum mainnet update script
//  forge script scripts/DiamondCut.s.sol:DiamondCut --chain-id 1 --rpc-url https://eth-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract DiamondCut is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        address erc7540Facet = address(0xC24634647F546E833AA50d21a91B9361FB04c1e1);
        address localVault = address(0xe23031919D23d51059079761Acfef5B9016c935D);

        bytes4[] memory functionSelectorsERC7540Facet = new bytes4[](7);
        functionSelectorsERC7540Facet[0] = IERC7540Facet
            .erc7540Deposit
            .selector;
        functionSelectorsERC7540Facet[1] = IERC7540Facet.erc7540Mint.selector;
        functionSelectorsERC7540Facet[2] = IERC7540Facet
            .erc7540Withdraw
            .selector;
        functionSelectorsERC7540Facet[3] = IERC7540Facet.erc7540Redeem.selector;
        functionSelectorsERC7540Facet[4] = IERC7540Facet
            .erc7540RequestDeposit
            .selector;
        functionSelectorsERC7540Facet[5] = IERC7540Facet
            .erc7540RequestRedeem
            .selector;
        functionSelectorsERC7540Facet[6] = IERC7540Facet
            .accountingERC7540Facet
            .selector;
        bytes[] memory actions = new bytes[](1);
        
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(erc7540Facet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: functionSelectorsERC7540Facet,
            initData: ""
        });
        actions[0] = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts);

        IMulticallFacet(localVault).submitActions(
            actions
        );

        vm.stopBroadcast();
    }
}
