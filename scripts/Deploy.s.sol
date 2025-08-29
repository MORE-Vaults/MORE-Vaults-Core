// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VaultsRegistry} from "../src/registry/VaultsRegistry.sol";
import {BaseVaultsRegistry} from "../src/registry/BaseVaultsRegistry.sol";
import {VaultsFactory} from "../src/factory/VaultsFactory.sol";
import {MoreVaultsDiamond} from "../src/MoreVaultsDiamond.sol";
import {IDiamondCut, DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {IERC165, IDiamondLoupe, DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {IAccessControlFacet, AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {IConfigurationFacet, ConfigurationFacet} from "../src/facets/ConfigurationFacet.sol";
import {IMulticallFacet, MulticallFacet} from "../src/facets/MulticallFacet.sol";
import {IVaultFacet, IERC4626, IERC20, VaultFacet} from "../src/facets/VaultFacet.sol";
import {IERC4626Facet, ERC4626Facet} from "../src/facets/ERC4626Facet.sol";
import {IERC7540Facet, ERC7540Facet} from "../src/facets/ERC7540Facet.sol";
import {DeployConfig} from "./config/DeployConfig.s.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OracleRegistry} from "../src/registry/OracleRegistry.sol";
import {IOracleRegistry, IAggregatorV2V3Interface} from "../src/interfaces/IOracleRegistry.sol";
import {IAaveOracle} from "@aave-v3-core/contracts/interfaces/IAaveOracle.sol";
import {console} from "forge-std/console.sol";

// testnet deployment script
// forge script scripts/Deploy.s.sol:DeployScript --chain-id 545 --rpc-url https://testnet.evm.nodes.onflow.org -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://evm-testnet.flowscan.io/api/'

// mainnet deployment script
// forge script scripts/Deploy.s.sol:DeployScript --chain-id 747 --rpc-url https://mainnet.evm.nodes.onflow.org -vv --slow --broadcast --verify --verifier blockscout --verifier-url 'https://evm.flowscan.io/api/'

// ethereum mainnet deployment script
// forge script scripts/Deploy.s.sol:DeployScript --chain-id 1 --rpc-url https://eth-mainnet.g.alchemy.com/v2/8yei2I_LU23eG8eAXP_wN2pS-4JrTa7R -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1

contract DeployScript is Script {
    DeployConfig config;
    VaultsRegistry registry;
    VaultsFactory factory;
    MoreVaultsDiamond diamond;
    OracleRegistry oracleRegistry;

    // FLOW MAINNET
    // address constant USDF = address(0x2aaBea2058b5aC2D339b163C6Ab6f2b6d53aabED);
    // address constant WFLOW =
    //     address(0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e);
    // address constant ankrFLOW =
    //     address(0x1b97100eA1D7126C4d60027e231EA4CB25314bdb);
    // address constant WETH = address(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590);
    // address constant stgUSDC =
    //     address(0xF1815bd50389c46847f0Bda824eC8da914045D14);

    // ETHEREUM MAINNET
    address constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant RLUSD =
        address(0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD);
    address constant USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    function test_skip() public pure {}

    function setUp() public {
        config = new DeployConfig();

        config.initParamsForProtocolDeployment(
            vm.envAddress("WRAPPED_NATIVE"),
            vm.envAddress("USD_STABLE_TOKEN_ADDRESS"),
            vm.envAddress("AAVE_ORACLE")
        );

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
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        DeployConfig.FacetAddresses memory facetAddresses;
        DiamondCutFacet diamondCut = new DiamondCutFacet();

        {
            // Deploy facets
            DiamondLoupeFacet diamondLoupe = new DiamondLoupeFacet();
            AccessControlFacet accessControl = new AccessControlFacet();
            ConfigurationFacet configuration = new ConfigurationFacet();
            MulticallFacet multicall = new MulticallFacet();
            VaultFacet vault = new VaultFacet();
            ERC4626Facet erc4626 = new ERC4626Facet();
            ERC7540Facet erc7540 = new ERC7540Facet();

            facetAddresses.diamondLoupe = address(diamondLoupe);
            facetAddresses.accessControl = address(accessControl);
            facetAddresses.configuration = address(configuration);
            facetAddresses.multicall = address(multicall);
            facetAddresses.vault = address(vault);
            facetAddresses.erc4626 = address(erc4626);
            facetAddresses.erc7540 = address(erc7540);
        }

        // Save addresses to .env.deployments file
        string memory addresses = string(
            abi.encodePacked(
                "DIAMOND_CUT_FACET=",
                vm.toString(address(diamondCut)),
                "\n",
                "DIAMOND_LOUPE_FACET=",
                vm.toString(facetAddresses.diamondLoupe),
                "\n",
                "ACCESS_CONTROL_FACET=",
                vm.toString(facetAddresses.accessControl),
                "\n",
                "CONFIGURATION_FACET=",
                vm.toString(facetAddresses.configuration),
                "\n",
                "VAULT_FACET=",
                vm.toString(facetAddresses.vault),
                "\n",
                "MULTICALL_FACET=",
                vm.toString(facetAddresses.multicall),
                "\n",
                "ERC4626_FACET=",
                vm.toString(facetAddresses.erc4626),
                "\n",
                "ERC7540_FACET=",
                vm.toString(facetAddresses.erc7540),
                "\n"
            )
        );
        vm.writeFile(".env.deployments", addresses);

        // Save addresses to .env file
        addresses = string(
            abi.encodePacked(
                vm.readFile(".env"),
                "\n",
                "# DEPLOYED PROTOCOL ADDRESSES",
                "\n",
                "DIAMOND_CUT_FACET=",
                vm.toString(address(diamondCut)),
                "\n",
                "DIAMOND_LOUPE_FACET=",
                vm.toString(facetAddresses.diamondLoupe),
                "\n",
                "ACCESS_CONTROL_FACET=",
                vm.toString(facetAddresses.accessControl),
                "\n",
                "CONFIGURATION_FACET=",
                vm.toString(facetAddresses.configuration),
                "\n",
                "VAULT_FACET=",
                vm.toString(facetAddresses.vault),
                "\n",
                "MULTICALL_FACET=",
                vm.toString(facetAddresses.multicall),
                "\n",
                "ERC4626_FACET=",
                vm.toString(facetAddresses.erc4626),
                "\n",
                "ERC7540_FACET=",
                vm.toString(facetAddresses.erc7540),
                "\n"
            )
        );
        vm.writeFile(".env", string(abi.encodePacked(addresses, addresses2)));

        console.log("Facets deployed");

        // FLOW MAINNET
        // address[] memory assets = new address[](5);
        // assets[0] = USDF;
        // assets[1] = ankrFLOW;
        // assets[2] = WFLOW;
        // assets[3] = stgUSDC;
        // assets[4] = WETH;
        // address[] memory sources = new address[](5);
        // sources[0] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(USDF);
        // sources[1] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(
        //     ankrFLOW
        // );
        // sources[2] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(WFLOW);
        // sources[3] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(stgUSDC);
        // sources[4] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(WETH);
        // uint96[] memory confidence = new uint96[](5);
        // confidence[0] = 4 hours;
        // confidence[1] = 4 hours;
        // confidence[2] = 4 hours;
        // confidence[3] = 4 hours;
        // confidence[4] = 4 hours;

        // IOracleRegistry.OracleInfo[]
        //     memory infos = new IOracleRegistry.OracleInfo[](5);
        // for (uint i; i < assets.length; ) {
        //     infos[i] = IOracleRegistry.OracleInfo({
        //         aggregator: IAggregatorV2V3Interface(sources[i]),
        //         stalenessThreshold: confidence[i]
        //     });
        //     unchecked {
        //         ++i;
        //     }
        // }

        // ETHEREUM MAINNET
        address[] memory assets = new address[](4);
        assets[0] = USDC;
        assets[1] = WETH;
        assets[2] = RLUSD;
        assets[3] = USDT;
        address[] memory sources = new address[](4);
        sources[0] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(USDC);
        sources[1] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(WETH);
        sources[2] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(RLUSD);
        sources[3] = IAaveOracle(config.aaveOracle()).getSourceOfAsset(USDT);
        uint96[] memory confidence = new uint96[](4);
        confidence[0] = 4 hours;
        confidence[1] = 4 hours;
        confidence[2] = 4 hours;
        confidence[3] = 4 hours;

        IOracleRegistry.OracleInfo[]
            memory infos = new IOracleRegistry.OracleInfo[](4);
        for (uint i; i < assets.length; ) {
            infos[i] = IOracleRegistry.OracleInfo({
                aggregator: IAggregatorV2V3Interface(sources[i]),
                stalenessThreshold: confidence[i]
            });
            unchecked {
                ++i;
            }
        }

        // Deploy oracle registry
        oracleRegistry = new OracleRegistry();
        oracleRegistry.initialize(assets, infos, address(0), 8);
        console.log("Oracle registry deployed at:", address(oracleRegistry));

        // Save registry address
        vm.writeFile(
            ".env.deployments",
            string(
                abi.encodePacked(
                    vm.readFile(".env.deployments"),
                    "ORACLE_REGISTRY=",
                    vm.toString(address(oracleRegistry)),
                    "\n"
                )
            )
        );
        vm.writeFile(
            ".env",
            string(
                abi.encodePacked(
                    vm.readFile(".env"),
                    "ORACLE_REGISTRY=",
                    vm.toString(address(oracleRegistry)),
                    "\n"
                )
            )
        );

        // Deploy registry
        address registryImplementation = address(new VaultsRegistry());
        registry = VaultsRegistry(
            address(
                new TransparentUpgradeableProxy(
                    registryImplementation,
                    msg.sender,
                    abi.encodeWithSelector(
                        BaseVaultsRegistry.initialize.selector,
                        oracleRegistry,
                        config.usdce()
                    )
                )
            )
        );
        console.log("Registry deployed at:", address(registry));

        // Save registry address
        vm.writeFile(
            ".env.deployments",
            string(
                abi.encodePacked(
                    vm.readFile(".env.deployments"),
                    "VAULT_REGISTRY=",
                    vm.toString(address(registry)),
                    "\n"
                )
            )
        );
        vm.writeFile(
            ".env",
            string(
                abi.encodePacked(
                    vm.readFile(".env"),
                    "VAULT_REGISTRY=",
                    vm.toString(address(registry)),
                    "\n"
                )
            )
        );

        {
            bytes4[] memory functionSelectorsDiamondCutFacet = new bytes4[](1);
            functionSelectorsDiamondCutFacet[0] = IDiamondCut
                .diamondCut
                .selector;
            bytes4[] memory functionSelectorsAccessControlFacet = new bytes4[](
                1
            );
            functionSelectorsAccessControlFacet[0] = AccessControlFacet
                .setMoreVaultsRegistry
                .selector;
            registry.addFacet(
                address(diamondCut),
                functionSelectorsDiamondCutFacet
            );
            registry.addFacet(
                address(facetAddresses.accessControl),
                functionSelectorsAccessControlFacet
            );
        }

        // Add facets to registry
        IDiamondCut.FacetCut[] memory cuts = config.getCuts(facetAddresses);
        for (uint i = 0; i < cuts.length; ) {
            registry.addFacet(cuts[i].facetAddress, cuts[i].functionSelectors);
            unchecked {
                ++i;
            }
        }
        console.log("Facets added to registry");

        // Deploy factory
        address factoryImplementation = address(new VaultsFactory());
        factory = VaultsFactory(
            address(
                new TransparentUpgradeableProxy(
                    factoryImplementation,
                    msg.sender,
                    abi.encodeWithSelector(
                        VaultsFactory.initialize.selector,
                        address(registry),
                        address(diamondCut),
                        address(facetAddresses.accessControl),
                        config.wrappedNative()
                    )
                )
            )
        );
        console.log("Factory deployed at:", address(factory));

        // Save factory address
        vm.writeFile(
            ".env.deployments",
            string(
                abi.encodePacked(
                    vm.readFile(".env.deployments"),
                    "VAULTS_FACTORY=",
                    vm.toString(address(factory)),
                    "\n"
                )
            )
        );
        vm.writeFile(
            ".env",
            string(
                abi.encodePacked(
                    vm.readFile(".env"),
                    "VAULTS_FACTORY=",
                    vm.toString(address(factory)),
                    "\n"
                )
            )
        );

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
        vm.writeFile(
            ".env",
            string(
                abi.encodePacked(
                    vm.readFile(".env"),
                    "VAULT_ADDRESS=",
                    vm.toString(vaultAddress),
                    "\n"
                )
            )
        );

        vm.stopBroadcast();
    }
}
