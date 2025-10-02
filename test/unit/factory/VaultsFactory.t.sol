// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IVaultsFactory, VaultsFactory} from "../../../src/factory/VaultsFactory.sol";
import {DiamondCutFacet} from "../../../src/facets/DiamondCutFacet.sol";
import {IAccessControlFacet, AccessControlFacet} from "../../../src/facets/AccessControlFacet.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {IMoreVaultsRegistry, IOracleRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MockFacet} from "../../mocks/MockFacet.sol";
import {MockMoreVaultsComposer} from "../../mocks/MockMoreVaultsComposer.sol";
import {MockOFTAdapterFactory} from "../../mocks/MockOFTAdapterFactory.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IMoreVaultsComposer} from "../../../src/interfaces/LayerZero/IMoreVaultsComposer.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";

contract CorruptedComposer {
    function initialize(address _vault, address _registry, address _lzAdapter, address _factory) external {
        revert("CorruptedComposer: initialization failed");
    }
}

contract VaultsFactoryTest is Test {
    // Test addresses
    VaultsFactory public factory;
    address public registry;
    address public diamondCutFacet;
    address public accessControlFacet;
    address public admin = address(1);
    address public curator = address(2);
    address public guardian = address(3);
    address public feeRecipient = address(4);
    address public oracle = address(5);
    address public layerZeroEndpoint = address(6);
    uint32 public localEid = uint32(block.chainid);
    uint96 public maxFinalizationTime = 1 days;
    address public lzAdapter = address(7);
    address payable public composerImplementation;
    address public oftAdapterFactory;
    address public asset;
    address public wrappedNative;

    // Test data
    string constant VAULT_NAME = "Test Vault";
    string constant VAULT_SYMBOL = "TV";
    uint96 constant FEE = 1000; // 10%
    uint256 constant TIME_LOCK_PERIOD = 1 days;
    bytes4 constant TEST_SELECTOR = 0x12345678;

    function setUp() public {
        // Deploy mocks
        registry = address(1001);
        wrappedNative = address(1002);

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        AccessControlFacet accessFacet = new AccessControlFacet();
        diamondCutFacet = address(cutFacet);
        accessControlFacet = address(accessFacet);

        MockERC20 mockAsset = new MockERC20("Test Asset", "TA");
        asset = address(mockAsset);

        // Deploy mock composer
        MockMoreVaultsComposer mockComposer = new MockMoreVaultsComposer();
        composerImplementation = payable(address(mockComposer));

        // Deploy mock OFT adapter factory
        MockOFTAdapterFactory mockOFTFactory = new MockOFTAdapterFactory(layerZeroEndpoint, admin);
        oftAdapterFactory = address(mockOFTFactory);

        // Deploy factory
        vm.prank(admin);
        factory = new VaultsFactory(layerZeroEndpoint);

        vm.mockCall(
            layerZeroEndpoint, abi.encodeWithSelector(ILayerZeroEndpointV2.setDelegate.selector, admin), abi.encode()
        );
    }

    function test_initialize_ShouldSetInitialValues() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        assertEq(address(VaultsFactory(factory).registry()), registry, "Should set correct registry");
        assertEq(VaultsFactory(factory).diamondCutFacet(), diamondCutFacet, "Should set correct diamond cut facet");
        assertEq(VaultsFactory(factory).owner(), admin, "Should set admin role");
    }

    function test_initialize_ShouldRevertIfZeroAddress() public {
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            admin,
            address(0),
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            admin,
            registry,
            address(0),
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            address(0),
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            address(0),
            uint32(block.chainid),
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );
    }

    function test_setDiamondCutFacet_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newFacet = address(5);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setDiamondCutFacet(newFacet);
    }

    function test_setDiamondCutFacet_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setDiamondCutFacet(address(0));
    }

    function test_setDiamondCutFacet_ShouldUpdateFacet() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newFacet = address(5);
        vm.prank(admin);
        VaultsFactory(factory).setDiamondCutFacet(newFacet);
        assertEq(VaultsFactory(factory).diamondCutFacet(), newFacet, "Should update diamond cut facet");
    }

    function test_setAccessControlFacet_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newFacet = address(5);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setAccessControlFacet(newFacet);
    }

    function test_setAccessControlFacet_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setAccessControlFacet(address(0));
    }

    function test_setAccessControlFacet_ShouldUpdateFacet() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newFacet = address(5);
        vm.prank(admin);
        VaultsFactory(factory).setAccessControlFacet(newFacet);
        assertEq(VaultsFactory(factory).accessControlFacet(), newFacet, "Should update access control facet");
    }

    function test_deployVault_ShouldDeployVaultWithFacets() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );

        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );

        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        assertTrue(VaultsFactory(factory).isFactoryVault(vault), "Should mark as factory vault");
        assertEq(VaultsFactory(factory).getVaultsCount(), 1, "Should increment vaults count");

        address[] memory vaults = VaultsFactory(factory).getDeployedVaults();
        assertEq(vaults.length, 1, "Should have one deployed vault");
        assertEq(vaults[0], vault, "Should store deployed vault address");
        assertEq(VaultsFactory(factory).isFactoryVault(vault), true, "Should be a factory vault");
    }

    function test_isVault_ShouldReturnFalseForNonFactoryVault() public view {
        assertFalse(VaultsFactory(factory).isFactoryVault(address(1)), "Should return false for non-factory vault");
    }

    function test_getDeployedVaults_ShouldReturnEmptyArrayInitially() public view {
        address[] memory vaults = VaultsFactory(factory).getDeployedVaults();
        assertEq(vaults.length, 0, "Should return empty array initially");
    }

    function test_getVaultsCount_ShouldReturnZeroInitially() public view {
        assertEq(VaultsFactory(factory).getVaultsCount(), 0, "Should return zero initially");
    }

    function test_linkVault_shouldRevertIfCallerisFactoryVault() public {
        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAuthorizedToLinkFacets.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).link(address(0));
    }

    function test_linkVault_shouldRevertIfCallerIsNotAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).pauseFacet(address(0));
    }

    function test_pauseFacet_ShouldAddFacetToRestricted() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(admin);
        VaultsFactory(factory).pauseFacet(address(diamondCutFacet));

        address[] memory restricredFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restricredFacets.length, 1);
        assertEq(restricredFacets[0], address(diamondCutFacet));
    }

    function test_pauseShouldWorkForSelectedFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory vaultSelectors = new bytes4[](3);
        vaultSelectors[0] = VaultFacet.initialize.selector;
        vaultSelectors[1] = VaultFacet.pause.selector;
        vaultSelectors[2] = VaultFacet.paused.selector;
        IDiamondCut.FacetCut memory vaultCut = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: vaultSelectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Prepare facets
        MockFacet mock1 = new MockFacet();
        MockFacet mock2 = new MockFacet();
        MockFacet mock3 = new MockFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TEST_SELECTOR;
        IDiamondCut.FacetCut[] memory facets1 = new IDiamondCut.FacetCut[](2);
        facets1[0] = vaultCut;
        facets1[1] = IDiamondCut.FacetCut({
            facetAddress: address(mock1),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: ""
        });

        IDiamondCut.FacetCut[] memory facets2 = new IDiamondCut.FacetCut[](2);
        facets2[0] = vaultCut;
        facets2[1] = IDiamondCut.FacetCut({
            facetAddress: address(mock2),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: ""
        });

        IDiamondCut.FacetCut[] memory facets3 = new IDiamondCut.FacetCut[](2);
        facets3[0] = vaultCut;
        facets3[1] = IDiamondCut.FacetCut({
            facetAddress: address(mock3),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: ""
        });

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        // check registry if permissionless
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        // allow vault facet
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, VaultFacet.initialize.selector),
            abi.encode(vaultFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, VaultFacet.paused.selector),
            abi.encode(vaultFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, VaultFacet.pause.selector),
            abi.encode(vaultFacet)
        );

        // allow diamond cut facet
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );

        // allow access control facet
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );

        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        // allow mock1
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(mock1)),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, TEST_SELECTOR),
            abi.encode(address(mock1))
        );

        address vault1 = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        vault1 = VaultsFactory(factory).deployVault(facets1, accessControlFacetInitData, true, bytes32(0));

        // aloow mock 2
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(mock2)),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, TEST_SELECTOR),
            abi.encode(address(mock2))
        );

        address vault2 = VaultsFactory(factory).predictVaultAddress(bytes32(uint256(1)));

        vault2 = VaultsFactory(factory).deployVault(facets2, accessControlFacetInitData, true, bytes32(uint256(1)));

        // allow mock3
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(mock3)),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, TEST_SELECTOR),
            abi.encode(address(mock3))
        );

        address vault3 = VaultsFactory(factory).predictVaultAddress(bytes32(uint256(2)));

        vault3 = VaultsFactory(factory).deployVault(facets3, accessControlFacetInitData, true, bytes32(uint256(2)));

        vm.prank(admin);
        VaultsFactory(factory).pauseFacet(address(mock2));
        assertFalse(VaultFacet(vault1).paused());
        assertTrue(VaultFacet(vault2).paused());
        assertFalse(VaultFacet(vault3).paused());
    }

    function test_setFacetRestricted_shouldRevertIfCalledNotByAnAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);
    }

    function test_setFacetRestricted_shouldSetFacetToRestricted() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        address[] memory restricredFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restricredFacets.length, 1);
        assertEq(restricredFacets[0], address(diamondCutFacet));
    }

    function test_setFacetRestricted_shouldSetFacetToNotRestricted() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, false);

        address[] memory restricredFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restricredFacets.length, 0);
    }

    function test_setMaxFinalizationTime_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setMaxFinalizationTime(2 days);
    }

    function test_setMaxFinalizationTime_ShouldUpdateTime() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        uint96 newTime = 2 days;
        vm.prank(admin);
        VaultsFactory(factory).setMaxFinalizationTime(newTime);
        assertEq(VaultsFactory(factory).maxFinalizationTime(), newTime, "Should update max finalization time");
    }

    function test_setLzAdapter_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setLzAdapter(address(9));
    }

    function test_setLzAdapter_ShouldUpdateAdapter() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newAdapter = address(9);
        vm.prank(admin);
        VaultsFactory(factory).setLzAdapter(newAdapter);
        assertEq(VaultsFactory(factory).lzAdapter(), newAdapter, "Should update LZ adapter");
    }

    function test_setVaultComposer_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setVaultComposer(address(1), address(2));
    }

    function test_setVaultComposer_ShouldUpdateComposer() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address vault = address(1);
        address composer = address(2);
        vm.prank(admin);
        VaultsFactory(factory).setVaultComposer(vault, composer);
        assertEq(VaultsFactory(factory).vaultComposer(vault), composer, "Should update vault composer");
    }

    function test_setComposerImplementation_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setComposerImplementation(address(9));
    }

    function test_setComposerImplementation_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setComposerImplementation(address(0));
    }

    function test_setComposerImplementation_ShouldUpdateImplementation() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newImplementation = address(9);
        vm.prank(admin);
        VaultsFactory(factory).setComposerImplementation(newImplementation);
        assertEq(
            VaultsFactory(factory).composerImplementation(), newImplementation, "Should update composer implementation"
        );
    }

    function test_setOFTAdapterFactory_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(curator))
        );
        VaultsFactory(factory).setOFTAdapterFactory(address(9));
    }

    function test_setOFTAdapterFactory_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setOFTAdapterFactory(address(0));
    }

    function test_setOFTAdapterFactory_ShouldUpdateFactory() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        address newOFTFactory = address(9);
        vm.prank(admin);
        VaultsFactory(factory).setOFTAdapterFactory(newOFTFactory);
        assertEq(VaultsFactory(factory).oftAdapterFactory(), newOFTFactory, "Should update OFT adapter factory");
    }

    function test_unlink_ShouldRevertIfCallerIsNotVault() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAuthorizedToLinkFacets.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).unlink(address(0));
    }

    function test_unlink_ShouldRemoveVaultFromFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Deploy a vault first
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Now test unlink
        vm.prank(vault);
        VaultsFactory(factory).unlink(address(vaultFacet));

        assertFalse(VaultsFactory(factory).isVaultLinked(address(vaultFacet), vault), "Should unlink vault from facet");
    }

    function test_getLinkedVaults_ShouldReturnEmptyArrayInitially() public view {
        address[] memory vaults = VaultsFactory(factory).getLinkedVaults(address(1));
        assertEq(vaults.length, 0, "Should return empty array initially");
    }

    function test_isVaultLinked_ShouldReturnFalseInitially() public view {
        assertFalse(VaultsFactory(factory).isVaultLinked(address(1), address(2)), "Should return false initially");
    }

    function test_hubToSpokes_ShouldReturnEmptyArraysInitially() public view {
        (uint32[] memory eids, address[] memory vaults) = VaultsFactory(factory).hubToSpokes(1, address(1));
        assertEq(eids.length, 0, "Should return empty eids array");
        assertEq(vaults.length, 0, "Should return empty vaults array");
    }

    function test_isSpokeOfHub_ShouldReturnFalseInitially() public view {
        assertFalse(VaultsFactory(factory).isSpokeOfHub(1, address(1), 2, address(2)), "Should return false initially");
    }

    function test_isCrossChainVault_ShouldReturnFalseInitially() public view {
        assertFalse(VaultsFactory(factory).isCrossChainVault(1, address(1)), "Should return false initially");
    }

    function test_spokeToHub_ShouldReturnZeroValuesInitially() public view {
        (uint32 eid, address vault) = VaultsFactory(factory).spokeToHub(1, address(1));
        assertEq(eid, 0, "Should return zero eid");
        assertEq(vault, address(0), "Should return zero address");
    }

    function test_deployVault_ShouldRevertWithRestrictedFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        // Restrict the vault facet AFTER mocking registry calls
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(address(vaultFacet), true);

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.RestrictedFacet.selector, address(vaultFacet)));
        VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));
    }

    function test_deployVault_ShouldRevertWithZeroComposerImplementation() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            address(0), // Zero composer implementation
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));
    }

    function test_deployVault_ShouldRevertWithComposerInitializationFailure() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        address corruptedComposerImplmentation = address(new CorruptedComposer());
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            corruptedComposerImplmentation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.previewDeposit.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));
        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        vm.expectRevert(IVaultsFactory.ComposerInitializationFailed.selector);
        VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));
    }

    // ===== Cross-chain functionality tests =====
    // Note: These tests are simplified due to LayerZero complexity
    // Full integration tests would require proper LayerZero endpoint mocking

    function test_requestRegisterSpoke_ShouldRevertIfNotAVault() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        deal(admin, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAVault.selector, address(1)));
        vm.prank(admin);
        VaultsFactory(factory).requestRegisterSpoke(1, address(2), address(1), "");
    }

    function test_hubSendBootstrap_ShouldRevertIfNotAVault() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAVault.selector, address(1)));
        vm.prank(admin);
        VaultsFactory(factory).hubSendBootstrap(1, address(1), "");
    }

    function test_hubSendBootstrap_ShouldRevertIfNotOwner() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Deploy a vault first
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Mock vault owner to be admin, but call from curator
        vm.mockCall(vault, abi.encodeWithSelector(IAccessControlFacet.owner.selector), abi.encode(admin));

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAnOwnerOfVault.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).hubSendBootstrap(1, vault, "");
    }

    function test_hubBroadcastSpokeAdded_ShouldRevertIfNotAVault() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAVault.selector, address(1)));
        vm.prank(admin);
        VaultsFactory(factory).hubBroadcastSpokeAdded(address(1), 1, address(2), dstEids, "");
    }

    function test_hubBroadcastSpokeAdded_ShouldRevertIfNotOwner() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Deploy a vault first
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Mock vault owner to be admin, but call from curator
        vm.mockCall(vault, abi.encodeWithSelector(IAccessControlFacet.owner.selector), abi.encode(admin));

        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAnOwnerOfVault.selector, curator));
        vm.prank(curator);
        VaultsFactory(factory).hubBroadcastSpokeAdded(vault, 1, address(2), dstEids, "");
    }

    // ===== Edge cases and error conditions =====

    function test_initialize_ShouldRevertWithZeroLocalEid() public {
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            0, // Zero localEid
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );
    }

    function test_link_ShouldAddVaultToFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Deploy a vault first
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Test link function
        address newFacet = address(999);
        vm.prank(vault);
        VaultsFactory(factory).link(newFacet);

        assertTrue(VaultsFactory(factory).isVaultLinked(newFacet, vault), "Should link vault to facet");
    }

    function test_deployVault_ShouldSetCorrectValues() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );

        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );

        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        assertTrue(VaultsFactory(factory).isFactoryVault(vault), "Should mark as factory vault");
        assertEq(VaultsFactory(factory).deployedAt(vault), uint96(block.timestamp), "Should set deployment time");
        assertTrue(VaultsFactory(factory).isVaultLinked(diamondCutFacet, vault), "Should link diamond cut facet");
        assertTrue(VaultsFactory(factory).isVaultLinked(accessControlFacet, vault), "Should link access control facet");
        assertTrue(VaultsFactory(factory).isVaultLinked(address(vaultFacet), vault), "Should link vault facet");
    }

    // ===== Additional edge cases and internal function coverage =====

    function test_deployVault_ShouldHandleMultipleFacets() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare multiple facets
        VaultFacet vaultFacet = new VaultFacet();
        MockFacet mockFacet1 = new MockFacet();
        MockFacet mockFacet2 = new MockFacet();

        bytes4[] memory vaultSelectors = new bytes4[](1);
        vaultSelectors[0] = VaultFacet.initialize.selector;

        bytes4[] memory mockSelectors1 = new bytes4[](1);
        mockSelectors1[0] = TEST_SELECTOR;

        bytes4[] memory mockSelectors2 = new bytes4[](1);
        mockSelectors2[0] = bytes4(uint32(TEST_SELECTOR) + 1);

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](3);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: vaultSelectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });
        facets[1] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet1),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: mockSelectors1,
            initData: ""
        });
        facets[2] = IDiamondCut.FacetCut({
            facetAddress: address(mockFacet2),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: mockSelectors2,
            initData: ""
        });

        // Mock registry calls for all facets
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, vaultSelectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, mockFacet1), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, mockSelectors1[0]),
            abi.encode(mockFacet1)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, mockFacet2), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, mockSelectors2[0]),
            abi.encode(mockFacet2)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Verify all facets are linked
        assertTrue(VaultsFactory(factory).isVaultLinked(diamondCutFacet, vault), "Should link diamond cut facet");
        assertTrue(VaultsFactory(factory).isVaultLinked(accessControlFacet, vault), "Should link access control facet");
        assertTrue(VaultsFactory(factory).isVaultLinked(address(vaultFacet), vault), "Should link vault facet");
        assertTrue(VaultsFactory(factory).isVaultLinked(address(mockFacet1), vault), "Should link mock facet 1");
        assertTrue(VaultsFactory(factory).isVaultLinked(address(mockFacet2), vault), "Should link mock facet 2");
    }

    function test_deployVault_ShouldRevertWithRestrictedVaultFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        // Restrict the vault facet AFTER mocking registry calls
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(address(vaultFacet), true);

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.RestrictedFacet.selector, address(vaultFacet)));
        VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));
    }

    function test_deployVault_ShouldRevertWithRestrictedAccessControlFacet() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Prepare facets
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        // Restrict the access control facet AFTER mocking registry calls
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(accessControlFacet, true);

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.RestrictedFacet.selector, accessControlFacet));
        VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));
    }

    function test_predictVaultAddress_ShouldReturnSameAddressForSameSalt() public view {
        bytes32 salt1 = bytes32(uint256(123));
        bytes32 salt2 = bytes32(uint256(123));

        address addr1 = VaultsFactory(factory).predictVaultAddress(salt1);
        address addr2 = VaultsFactory(factory).predictVaultAddress(salt2);

        assertEq(addr1, addr2, "Should return same address for same salt");
    }

    function test_predictVaultAddress_ShouldReturnDifferentAddressForDifferentSalt() public view {
        bytes32 salt1 = bytes32(uint256(123));
        bytes32 salt2 = bytes32(uint256(456));

        address addr1 = VaultsFactory(factory).predictVaultAddress(salt1);
        address addr2 = VaultsFactory(factory).predictVaultAddress(salt2);

        assertNotEq(addr1, addr2, "Should return different address for different salt");
    }

    function test_getLinkedVaults_ShouldReturnCorrectVaults() public {
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector), abi.encode(false));

        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Deploy a vault first
        VaultFacet vaultFacet = new VaultFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VaultFacet.initialize.selector;

        IDiamondCut.FacetCut[] memory facets = new IDiamondCut.FacetCut[](1);
        facets[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors,
            initData: abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE)
        });

        // Mock registry calls
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, diamondCutFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(diamondCutFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, accessControlFacet),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector, IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );
        vm.mockCall(
            registry, abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, vaultFacet), abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, selectors[0]),
            abi.encode(vaultFacet)
        );
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(1000), uint96(1000))
        );

        address vault = VaultsFactory(factory).predictVaultAddress(bytes32(0));

        bytes memory accessControlFacetInitData = abi.encode(admin, curator, guardian);
        vault = VaultsFactory(factory).deployVault(facets, accessControlFacetInitData, true, bytes32(0));

        // Test getLinkedVaults
        address[] memory linkedVaults = VaultsFactory(factory).getLinkedVaults(diamondCutFacet);
        assertEq(linkedVaults.length, 1, "Should have one linked vault");
        assertEq(linkedVaults[0], vault, "Should return correct vault address");
    }

    function test_getRestrictedFacets_ShouldReturnEmptyInitially() public view {
        address[] memory restrictedFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restrictedFacets.length, 0, "Should return empty array initially");
    }

    function test_getRestrictedFacets_ShouldReturnCorrectFacets() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Add some restricted facets
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(accessControlFacet, true);

        address[] memory restrictedFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restrictedFacets.length, 2, "Should have two restricted facets");

        // Check that both facets are in the array
        bool foundDiamondCut = false;
        bool foundAccessControl = false;
        for (uint256 i = 0; i < restrictedFacets.length; i++) {
            if (restrictedFacets[i] == diamondCutFacet) {
                foundDiamondCut = true;
            }
            if (restrictedFacets[i] == accessControlFacet) {
                foundAccessControl = true;
            }
        }
        assertTrue(foundDiamondCut, "Should include diamond cut facet");
        assertTrue(foundAccessControl, "Should include access control facet");
    }

    function test_setFacetRestricted_ShouldRemoveFacetFromRestricted() public {
        vm.prank(admin);
        factory.initialize(
            admin,
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative,
            localEid,
            maxFinalizationTime,
            lzAdapter,
            composerImplementation,
            oftAdapterFactory
        );

        // Add facet to restricted
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        address[] memory restrictedFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restrictedFacets.length, 1, "Should have one restricted facet");

        // Remove facet from restricted
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, false);

        restrictedFacets = VaultsFactory(factory).getRestrictedFacets();
        assertEq(restrictedFacets.length, 0, "Should have no restricted facets");
    }
}
