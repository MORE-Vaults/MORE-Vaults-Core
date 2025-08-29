// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IVaultsFactory, VaultsFactory} from "../../../src/factory/VaultsFactory.sol";
import {DiamondCutFacet} from "../../../src/facets/DiamondCutFacet.sol";
import {IAccessControlFacet, AccessControlFacet} from "../../../src/facets/AccessControlFacet.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {IMoreVaultsRegistry, IOracleRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IAggregatorV2V3Interface} from "../../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MockFacet} from "../../mocks/MockFacet.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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

        // Deploy factory
        vm.prank(admin);
        factory = new VaultsFactory();
    }

    function test_initialize_ShouldSetInitialValues() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        assertEq(
            address(VaultsFactory(factory).registry()),
            registry,
            "Should set correct registry"
        );
        assertEq(
            VaultsFactory(factory).diamondCutFacet(),
            diamondCutFacet,
            "Should set correct diamond cut facet"
        );
        assertTrue(
            VaultsFactory(factory).hasRole(0x00, admin),
            "Should set admin role"
        );
    }

    function test_initialize_ShouldRevertIfZeroAddress() public {
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            address(0),
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            registry,
            address(0),
            accessControlFacet,
            wrappedNative
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            registry,
            diamondCutFacet,
            address(0),
            wrappedNative
        );

        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            address(0)
        );
    }

    function test_setDiamondCutFacet_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        address newFacet = address(5);
        vm.prank(curator);
        vm.expectRevert();
        VaultsFactory(factory).setDiamondCutFacet(newFacet);
    }

    function test_setDiamondCutFacet_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setDiamondCutFacet(address(0));
    }

    function test_setDiamondCutFacet_ShouldUpdateFacet() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        address newFacet = address(5);
        vm.prank(admin);
        VaultsFactory(factory).setDiamondCutFacet(newFacet);
        assertEq(
            VaultsFactory(factory).diamondCutFacet(),
            newFacet,
            "Should update diamond cut facet"
        );
    }

    function test_setAccessControlFacet_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        address newFacet = address(5);
        vm.prank(curator);
        vm.expectRevert();
        VaultsFactory(factory).setAccessControlFacet(newFacet);
    }

    function test_setAccessControlFacet_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        vm.prank(admin);
        vm.expectRevert(IVaultsFactory.ZeroAddress.selector);
        VaultsFactory(factory).setAccessControlFacet(address(0));
    }

    function test_setAccessControlFacet_ShouldUpdateFacet() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        address newFacet = address(5);
        vm.prank(admin);
        VaultsFactory(factory).setAccessControlFacet(newFacet);
        assertEq(
            VaultsFactory(factory).accessControlFacet(),
            newFacet,
            "Should update access control facet"
        );
    }

    function test_deployVault_ShouldDeployVaultWithFacets() public {
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
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
            initData: abi.encode(
                VAULT_NAME,
                VAULT_SYMBOL,
                asset,
                feeRecipient,
                FEE
            )
        });

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                diamondCutFacet
            ),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IDiamondCut.diamondCut.selector
            ),
            abi.encode(diamondCutFacet)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                accessControlFacet
            ),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IAccessControlFacet.setMoreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                vaultFacet
            ),
            abi.encode(true)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                selectors[0]
            ),
            abi.encode(vaultFacet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );

        // IOracleRegistry.AssetSource memory assetSource = IOracleRegistry
        //     .AssetSource({
        //         aggregator: IAggregatorV2V3Interface(asset),
        //         stalenessThreshold: 1000
        //     });
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset
            ),
            abi.encode(address(1000), uint96(1000))
        );

        bytes memory accessControlFacetInitData = abi.encode(
            admin,
            curator,
            guardian
        );
        address vault = VaultsFactory(factory).deployVault(
            facets,
            accessControlFacetInitData
        );

        assertTrue(
            VaultsFactory(factory).isVault(vault),
            "Should mark as factory vault"
        );
        assertEq(
            VaultsFactory(factory).getVaultsCount(),
            1,
            "Should increment vaults count"
        );

        address[] memory vaults = VaultsFactory(factory).getDeployedVaults();
        assertEq(vaults.length, 1, "Should have one deployed vault");
        assertEq(vaults[0], vault, "Should store deployed vault address");
        assertEq(
            VaultsFactory(factory).isVault(vault),
            true,
            "Should be a factory vault"
        );
    }

    function test_isVault_ShouldReturnFalseForNonFactoryVault() public view {
        assertFalse(
            VaultsFactory(factory).isVault(address(1)),
            "Should return false for non-factory vault"
        );
    }

    function test_getDeployedVaults_ShouldReturnEmptyArrayInitially()
        public
        view
    {
        address[] memory vaults = VaultsFactory(factory).getDeployedVaults();
        assertEq(vaults.length, 0, "Should return empty array initially");
    }

    function test_getVaultsCount_ShouldReturnZeroInitially() public view {
        assertEq(
            VaultsFactory(factory).getVaultsCount(),
            0,
            "Should return zero initially"
        );
    }

    function test_linkVault_shouldRevertIfCallerIsVault() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultsFactory.NotAuthorizedToLinkFacets.selector,
                curator
            )
        );
        vm.prank(curator);
        VaultsFactory(factory).link(address(0));
    }

    function test_linkVault_shouldRevertIfCallerIsNotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                curator,
                bytes32(0)
            )
        );
        vm.prank(curator);
        VaultsFactory(factory).pauseFacet(address(0));
    }

    function test_pauseFacet_ShouldAddFacetToRestricted() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );

        vm.prank(admin);
        VaultsFactory(factory).pauseFacet(address(diamondCutFacet));

        address[] memory restricredFacets = VaultsFactory(factory)
            .getRestrictedFacets();
        assertEq(restricredFacets.length, 1);
        assertEq(restricredFacets[0], address(diamondCutFacet));
    }

    function test_pauseShouldWorkForSelectedFacet() public {
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
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
            initData: abi.encode(
                VAULT_NAME,
                VAULT_SYMBOL,
                asset,
                feeRecipient,
                FEE
            )
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

        bytes memory accessControlFacetInitData = abi.encode(
            admin,
            curator,
            guardian
        );

        // check registry if permissionless
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isPermissionless.selector
            ),
            abi.encode(false)
        );

        // allow vault facet
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                vaultFacet
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                VaultFacet.initialize.selector
            ),
            abi.encode(vaultFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                VaultFacet.paused.selector
            ),
            abi.encode(vaultFacet)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                VaultFacet.pause.selector
            ),
            abi.encode(vaultFacet)
        );

        // allow diamond cut facet
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                diamondCutFacet
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IDiamondCut.diamondCut.selector
            ),
            abi.encode(diamondCutFacet)
        );

        // allow access control facet
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                accessControlFacet
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IAccessControlFacet.setMoreVaultsRegistry.selector
            ),
            abi.encode(accessControlFacet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );

        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset
            ),
            abi.encode(address(1000), uint96(1000))
        );

        // allow mock1
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(mock1)
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(address(mock1))
        );

        address vault1 = VaultsFactory(factory).deployVault(
            facets1,
            accessControlFacetInitData
        );

        // aloow mock 2
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(mock2)
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(address(mock2))
        );

        address vault2 = VaultsFactory(factory).deployVault(
            facets2,
            accessControlFacetInitData
        );

        // allow mock3
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isFacetAllowed.selector,
                address(mock3)
            ),
            abi.encode(true)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                TEST_SELECTOR
            ),
            abi.encode(address(mock3))
        );

        address vault3 = VaultsFactory(factory).deployVault(
            facets3,
            accessControlFacetInitData
        );

        vm.prank(admin);
        VaultsFactory(factory).pauseFacet(address(mock2));
        assertFalse(VaultFacet(vault1).paused());
        assertTrue(VaultFacet(vault2).paused());
        assertFalse(VaultFacet(vault3).paused());
    }

    function test_setFacetRestricted_shouldRevertIfCalledNotByAnAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                curator,
                bytes32(0)
            )
        );
        vm.prank(curator);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);
    }

    function test_setFacetRestricted_shouldSetFacetToRestricted() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        address[] memory restricredFacets = VaultsFactory(factory)
            .getRestrictedFacets();
        assertEq(restricredFacets.length, 1);
        assertEq(restricredFacets[0], address(diamondCutFacet));
    }

    function test_setFacetRestricted_shouldSetFacetToNotRestricted() public {
        vm.prank(admin);
        factory.initialize(
            registry,
            diamondCutFacet,
            accessControlFacet,
            wrappedNative
        );
        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, true);

        vm.prank(admin);
        VaultsFactory(factory).setFacetRestricted(diamondCutFacet, false);

        address[] memory restricredFacets = VaultsFactory(factory)
            .getRestrictedFacets();
        assertEq(restricredFacets.length, 0);
    }
}
