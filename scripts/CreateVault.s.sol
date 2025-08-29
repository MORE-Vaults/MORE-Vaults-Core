// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VaultsRegistry} from "../src/registry/VaultsRegistry.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {MoreVaultsDiamond} from "../src/MoreVaultsDiamond.sol";
import {IDiamondCut, DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {IERC165, IDiamondLoupe, DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {IAccessControlFacet, AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {IConfigurationFacet, ConfigurationFacet} from "../src/facets/ConfigurationFacet.sol";
import {IMulticallFacet, MulticallFacet} from "../src/facets/MulticallFacet.sol";
import {IVaultFacet, IERC4626, IERC20, VaultFacet} from "../src/facets/VaultFacet.sol";
import {IMORELeverageFacet, MORELeverageFacet} from "../src/facets/MORELeverageFacet.sol";
import {IPool, IAaveV3Facet, AaveV3Facet} from "../src/facets/AaveV3Facet.sol";
import {DeployConfig} from "./config/DeployConfig.s.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "forge-std/console.sol";

// testnet deployment script
// forge script scripts/CreateVault.s.sol:CreateVaultScript --chain-id 545 --rpc-url https://testnet.evm.nodes.onflow.org -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://evm-testnet.flowscan.io/api/'

// mainnet deployment script
// forge script scripts/CreateVault.s.sol:CreateVaultScript --chain-id 747 --rpc-url https://mainnet.evm.nodes.onflow.org -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://evm.flowscan.io/api/'

contract CreateVaultScript is Script {
    DeployConfig config;
    VaultsFactory factory;

    address diamondLoupe;
    address accessControl;
    address configuration;
    address multicall;
    address vault;
    address erc4626;
    address erc7540;

    function test_skip() public pure {}

    function setUp() public {
        // Load config from environment variables
        config = new DeployConfig();

        config.initParamsForVaultCreation(
            vm.envAddress("OWNER"),
            vm.envAddress("CURATOR"),
            vm.envAddress("GUARDIAN"),
            vm.envAddress("FEE_RECIPIENT"),
            vm.envAddress("UNDERLYING_ASSET"),
            uint96(vm.envUint("FEE")),
            vm.envUint("DEPOSIT_CAPACITY"),
            vm.envUint("TIME_LOCK_PERIOD"),
            vm.envUint("MAX_SLIPPAGE_PERCENT"),
            vm.envString("VAULT_NAME"),
            vm.envString("VAULT_SYMBOL")
        );

        diamondLoupe = vm.envAddress("DIAMOND_LOUPE_FACET");
        accessControl = vm.envAddress("ACCESS_CONTROL_FACET");
        configuration = vm.envAddress("CONFIGURATION_FACET");
        vault = vm.envAddress("VAULT_FACET");
        multicall = vm.envAddress("MULTICALL_FACET");
        erc4626 = vm.envAddress("ERC4626_FACET");
        erc7540 = vm.envAddress("ERC7540_FACET");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = VaultsFactory(vm.envAddress("VAULTS_FACTORY"));

        DeployConfig.FacetAddresses memory facetAddresses;
        facetAddresses.diamondLoupe = address(diamondLoupe);
        facetAddresses.accessControl = address(accessControl);
        facetAddresses.configuration = address(configuration);
        facetAddresses.multicall = address(multicall);
        facetAddresses.vault = address(vault);
        facetAddresses.erc4626 = address(erc4626);
        facetAddresses.erc7540 = address(erc7540);

        IDiamondCut.FacetCut[] memory cuts = config.getCuts(facetAddresses);

        // Deploy vault
        bytes memory accessControlFacetInitData = abi.encode(
            config.owner(),
            config.curator(),
            config.guardian()
        );
        address vaultAddress = factory.deployVault(
            cuts,
            accessControlFacetInitData
        );
        console.log("Vault deployed at:", vaultAddress);

        // Save factory address
        vm.writeFile(
            ".env.deployments",
            string(
                abi.encodePacked(
                    vm.readFile(".env.deployments"),
                    "VAULT_ADDRESS=",
                    vm.toString(vaultAddress),
                    "\n"
                )
            )
        );

        vm.stopBroadcast();
    }
}
