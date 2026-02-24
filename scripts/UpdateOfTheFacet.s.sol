// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CREATE3} from "@solady/src/utils/CREATE3.sol";
import {IDiamondCut, DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {IERC7540Facet, ERC7540Facet} from "../src/facets/ERC7540Facet.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {VaultsRegistry} from "../src/registry/VaultsRegistry.sol";

/**
 * @title UpdateOfTheFacet
 * @notice Comprehensive deployment script for updating the ERC7540Facet:
 *         Flow EVM, Ethereum, Arbitrum, Avalanche, Plasma, Base
 * 
 * @dev This script handles:
 *      1. Deployment of new ERC7540Facet.
 *      2. Updating registry with the new ERC7540Facet.
 *      43. Saving the addresses to the .env.deployments file.
 * 
 * @dev Usage:
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id {CHAIN_ID} \
 *        --rpc-url {RPC_URL} -vv --slow --broadcast --verify
 *      ethereum mainnet update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 1 --rpc-url https://eth-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1
 *      arbitrum update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 42161 --rpc-url https://arb-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1
 *      avalanche update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 43114 --rpc-url https://avax-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1
 *      base update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 8453 --rpc-url https://base-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1
 *      flow evm update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 747 --rpc-url https://mainnet.evm.nodes.onflow.org -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://evm.flowscan.io/api/'
 *      plasma update script
 *      forge script scripts/UpdateOfTheFacet.s.sol:UpdateOfTheFacet --chain-id 9745 --rpc-url https://plasma-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://plasmascan.to/api'
 */

contract UpdateOfTheFacet is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address registryAddr = vm.envAddress("VAULT_REGISTRY");
        address factoryAddr = vm.envAddress("VAULTS_FACTORY");
        if (registryAddr == address(0) || factoryAddr == address(0)) {
            revert("Missing VAULT_REGISTRY or VAULTS_FACTORY env");
        }

        VaultsRegistry registry = VaultsRegistry(registryAddr);
        VaultsFactory factory = VaultsFactory(factoryAddr);

        // Optional custom salt tag to make address deterministic across reruns
        string memory upgradeTag = vm.envOr("UPGRADE_TAG", string("erc7540FacetUpgradeV1.0.0"));
        bytes32 salt = keccak256(abi.encode(upgradeTag, uint256(1)));

        // Deploy new ERC7540Facet
        ERC7540Facet erc7540Facet = ERC7540Facet(
            CREATE3.deployDeterministic(type(ERC7540Facet).creationCode, salt)
        );

        console.log("New ERC7540Facet deployed:", address(erc7540Facet));

        // Remove old selector mapping if exists
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
        address oldFacet = registry.selectorToFacet(functionSelectorsERC7540Facet[0]);
        if (oldFacet != address(0) && oldFacet != address(erc7540Facet)) {
            registry.removeFacet(oldFacet);
            console.log("Removed ERC7540Facet selector from old facet:", oldFacet);
        }

        // Add new selector mapping
        {
            registry.addFacet(address(erc7540Facet), functionSelectorsERC7540Facet);
            console.log("Registry updated with ERC7540Facet selector ->", address(erc7540Facet));
        }

        // Write to .env.deployments
        string memory existing = "";
        try vm.readFile(".env.deployments") returns (string memory content) {
            existing = content;
        } catch {}
        string memory out = string(
            abi.encodePacked(
                existing,
                "ERC7540_FACET=",
                vm.toString(address(erc7540Facet)),
                "\n"
            )
        );
        vm.writeFile(".env.deployments", out);

        // Write to .env as well
        string memory envContent = "";
        try vm.readFile(".env") returns (string memory content2) {
            envContent = content2;
        } catch {}
        vm.writeFile(
            ".env",
            string(
                abi.encodePacked(
                    envContent,
                    "ERC7540_FACET=",
                    vm.toString(address(erc7540Facet)),
                    "\n"
                )
            )
        );

        vm.stopBroadcast();
    }
}
