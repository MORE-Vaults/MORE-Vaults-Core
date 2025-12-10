// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {MoreVaultsComposer} from "../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import {IVaultsFactory} from "../src/interfaces/IVaultsFactory.sol";

// sepolia testnet deployment script
// forge script scripts/ReconfigureComposerLzAdapter.s.sol:ReconfigureComposerLzAdapter --chain-id 11155111 --rpc-url https://eth-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

// arbitrum sepolia testnet deployment script
// forge script scripts/ReconfigureComposerLzAdapter.s.sol:ReconfigureComposerLzAdapter --chain-id 42161 --rpc-url https://arb-sepolia.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract ReconfigureComposerLzAdapter is Script {
    using OptionsBuilder for bytes;
    uint32 public srcEid = uint32(40231);
    uint32 public dstEid = uint32(40161);

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function run() external {
        // Load environment variables
        address oftAddress = address(
            0xC19419653441fEcc486B3F1f013f2392e01915D5
        );

        address shareOftAddress = address(
            0x5fEA64D6b231211CD071Cbe2c7De634943B33Bcb
        );
        address toAddress = address(0xb10C12547799688F2893530c80Cf625f4A193870);
        address composer = address(0x96904Bec84e9fD9ca05cb78FfA34a5c8A9eB8B20);
        address vault = address(0x639c07EA78dFfC22eAf726F9d85380622b1187E8);
        IVaultsFactory vaultsFactory = IVaultsFactory(address(0x1b3c1BF5c8a772dF2db965817b904B8dAabc2B56));
        uint256 tokensToSend = 1 ether;

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        address lzAdapterAddress = address(0x0d4b16Abba0C3bDE9266097328a61BD6D40E29E5);
        MoreVaultsComposer vaultComposer = new MoreVaultsComposer();
        vaultComposer.initialize(vault, shareOftAddress, address(vaultsFactory));

        vaultsFactory.setVaultComposer(vault, address(vaultComposer));
        // vaultsFactory.setLzAdapter(lzAdapterAddress);


        vm.stopBroadcast();
    }
}
