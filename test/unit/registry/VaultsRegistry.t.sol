// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IMoreVaultsRegistry, VaultsRegistry} from "../../../src/registry/VaultsRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract VaultsRegistryTest is Test {
    VaultsRegistry public registry;
    MockERC20 public usdc;
    address public admin = address(1);
    address public user = address(2);
    address public vault = address(3);
    address public recipient = address(4);
    address public facet = address(5);
    address public oracle = address(6);
    address public baseCurrency = address(7);

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy registry
        vm.prank(admin);
        registry = new VaultsRegistry();
        vm.prank(admin);

        // Mock oracle calls
        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(baseCurrency));
        registry.initialize(admin, address(oracle), address(usdc));
        vm.mockCall(oracle, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(address(0)));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
    }

    function test_constructor_ShouldSetInitialValues() public view {
        assertEq(address(registry.oracle()), oracle, "Should set correct oracle");
        assertEq(registry.usdStableTokenAddress(), address(usdc), "Should set correct USDC address");
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "Should set admin role");
    }

    function test_addFacet_ShouldAddFacetAndSelectors() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        assertTrue(registry.isFacetAllowed(facet), "Should allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 2, "Should add selectors");
        assertEq(registry.selectorToFacet(selectors[0]), facet, "Should map selector to facet");
        assertEq(registry.selectorToFacet(selectors[1]), facet, "Should map selector to facet");
    }

    function test_addFacet_ShouldAddSelectorsIfFacetAlreadyExists() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        bytes4[] memory selectorsNew = new bytes4[](1);
        selectorsNew[0] = bytes4(keccak256("test3()"));

        vm.prank(admin);
        registry.addFacet(facet, selectorsNew);
        assertTrue(registry.isFacetAllowed(facet), "Should allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 3, "Should add selectors");
        assertEq(registry.selectorToFacet(selectors[0]), facet, "Should map selector to facet");
        assertEq(registry.selectorToFacet(selectors[1]), facet, "Should map selector to facet");
        assertEq(registry.selectorToFacet(selectorsNew[0]), facet, "Should map selector to facet");
        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 1, "Should push facet to facet list");
        assertEq(facets[0], facet, "Should return correct facet");
    }

    function test_addFacet_ShouldntPushFacetToFacetListIfFacetAlreadyAdded() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        bytes4[] memory selectorsNew = new bytes4[](1);
        selectorsNew[0] = bytes4(keccak256("test3()"));

        vm.prank(admin);
        registry.addFacet(facet, selectorsNew);
        assertTrue(registry.isFacetAllowed(facet), "Should allow facet");

        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 1, "Should not push facet to facet list");
        assertEq(facets[0], facet, "Should return correct facet");

        assertEq(registry.getFacetSelectors(facet).length, 3, "Should add selectors");
        assertEq(registry.selectorToFacet(selectors[0]), facet, "Should map selector to facet");
        assertEq(registry.selectorToFacet(selectors[1]), facet, "Should map selector to facet");
        assertEq(registry.selectorToFacet(selectorsNew[0]), facet, "Should map selector to facet");
    }

    function test_addFacet_ShouldRevertWithZeroAddress() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("test()"));

        vm.prank(admin);
        vm.expectRevert(IMoreVaultsRegistry.ZeroAddress.selector);
        registry.addFacet(address(0), selectors);
    }

    function test_addFacet_ShouldRevertWhenSelectorAlreadyExists() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("test()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        address facet2 = address(6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsRegistry.SelectorAlreadyExists.selector, facet, selectors[0]));
        registry.addFacet(facet2, selectors);
    }

    function test_addFacet_ShouldRevertWhenNotAdmin() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("test()"));

        vm.prank(user);
        vm.expectRevert();
        registry.addFacet(facet, selectors);
    }

    function test_editFacet_ShouldEditFacetAndSelectors() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        bytes4[] memory selectorsNew = new bytes4[](1);
        selectorsNew[0] = bytes4(keccak256("test3()"));
        bool[] memory isSelectorAllowed = new bool[](1);
        isSelectorAllowed[0] = true;

        vm.prank(admin);
        registry.editFacet(facet, selectorsNew, isSelectorAllowed);

        assertTrue(registry.isFacetAllowed(facet), "Should allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 3, "Should add selectors");
        assertEq(registry.selectorToFacet(selectors[0]), facet, "Should map selector to facet");
        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 1, "Should not push facet to facet list");
        assertEq(facets[0], facet, "Should return correct facet");
    }

    function test_editFacet_ShouldRemoveSelectorFromList() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        bytes4[] memory selectorsNew = new bytes4[](1);
        selectorsNew[0] = selectors[0];
        bool[] memory isSelectorAllowed = new bool[](1);
        isSelectorAllowed[0] = false;

        vm.prank(admin);
        registry.editFacet(facet, selectorsNew, isSelectorAllowed);

        assertTrue(registry.isFacetAllowed(facet), "Should allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 1, "Should remove selector from list");
        assertEq(registry.selectorToFacet(selectors[0]), address(0), "Should remove selector mapping");
        assertEq(registry.selectorToFacet(selectors[1]), facet, "Should keep selector mapping");
        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 1, "Should not push facet to facet list");
        assertEq(facets[0], facet, "Should return correct facet");
    }

    function test_editFacet_ShouldRemoveFacetFromListIfNoSelectorsLeft() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = false;
        isSelectorAllowed[1] = false;

        vm.prank(admin);
        registry.editFacet(facet, selectors, isSelectorAllowed);

        assertFalse(registry.isFacetAllowed(facet), "Should not allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 0, "Should remove all selectors from facet");
        assertEq(registry.selectorToFacet(selectors[0]), address(0), "Should remove selector mapping");
        assertEq(registry.selectorToFacet(selectors[1]), address(0), "Should remove selector mapping");
        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 0, "Should remove facet from facet list");
    }

    function test_editFacet_ShouldRevertWhenFacetNotAllowed() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = false;
        isSelectorAllowed[1] = false;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsRegistry.FacetNotAllowed.selector, facet));
        registry.editFacet(facet, selectors, isSelectorAllowed);
    }

    function test_editFacet_ShouldRevertIfFacetProvidedIsZeroAddress() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = false;
        isSelectorAllowed[1] = false;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsRegistry.ZeroAddress.selector));
        registry.editFacet(address(0), selectors, isSelectorAllowed);
    }

    function test_editFacet_ShouldRevertIfArraysLengthMismatch() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](1);
        isSelectorAllowed[0] = false;

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        vm.prank(admin);

        vm.expectRevert(abi.encodeWithSelector(VaultsRegistry.ArrayLengthMismatch.selector));
        registry.editFacet(facet, selectors, isSelectorAllowed);
    }

    function test_editFacet_ShouldRevertIfAddingSelectorThatAlreadyExists() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = true;
        isSelectorAllowed[1] = true;

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsRegistry.SelectorAlreadyExists.selector, facet, selectors[0]));
        registry.editFacet(facet, selectors, isSelectorAllowed);
    }

    function test_editFacet_ShouldRevertIfRemovingSelectorThatDoesntExist() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = false;
        isSelectorAllowed[1] = false;

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        selectors[0] = bytes4(keccak256("test3()"));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultsRegistry.SelectorDidntExist.selector, selectors[0]));
        registry.editFacet(facet, selectors, isSelectorAllowed);
    }

    function test_editFacet_ShouldRevertIfCalledNotByAdmin() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        bool[] memory isSelectorAllowed = new bool[](2);
        isSelectorAllowed[0] = false;
        isSelectorAllowed[1] = false;

        vm.prank(user);
        vm.expectRevert();
        registry.editFacet(facet, selectors, isSelectorAllowed);
    }

    function test_removeFacet_ShouldRemoveFacetAndSelectors() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        vm.prank(admin);
        registry.removeFacet(facet);

        assertFalse(registry.isFacetAllowed(facet), "Should not allow facet");
        assertEq(registry.getFacetSelectors(facet).length, 0, "Should remove selectors");
        assertEq(registry.selectorToFacet(selectors[0]), address(0), "Should remove selector mapping");
        assertEq(registry.selectorToFacet(selectors[1]), address(0), "Should remove selector mapping");
        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 0, "Should remove facet from facet list");
    }

    function test_removeFacet_ShouldRevertWhenFacetNotAllowed() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsRegistry.FacetNotAllowed.selector, facet));
        registry.removeFacet(facet);
    }

    function test_removeFacet_ShouldRevertWhenNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        registry.removeFacet(facet);
    }

    function test_setProtocolFeeInfo_ShouldSetFeeInfo() public {
        uint96 fee = 1000; // 10%

        vm.prank(admin);
        registry.setProtocolFeeInfo(vault, recipient, fee);

        (address feeRecipient, uint96 actualFee) = registry.protocolFeeInfo(vault);
        assertEq(feeRecipient, recipient, "Should set correct recipient");
        assertEq(actualFee, fee, "Should set correct fee");
    }

    function test_setProtocolFeeInfo_ShouldRevertWithZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IMoreVaultsRegistry.ZeroAddress.selector);
        registry.setProtocolFeeInfo(vault, address(0), 1000);
    }

    function test_setProtocolFeeInfo_ShouldRevertWithInvalidFee() public {
        vm.prank(admin);
        vm.expectRevert(VaultsRegistry.InvalidFee.selector);
        registry.setProtocolFeeInfo(vault, recipient, 5001); // 50.01%
    }

    function test_setProtocolFeeInfo_ShouldRevertWhenNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        registry.setProtocolFeeInfo(vault, recipient, 1000);
    }

    function test_isFacetAllowed_ShouldReturnCorrectValue() public {
        assertFalse(registry.isFacetAllowed(facet), "Should not allow unknown facet");

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("test()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        assertTrue(registry.isFacetAllowed(facet), "Should allow added facet");
    }

    function test_getDenominationAsset_ShouldReturnBaseCurrency() public view {
        assertEq(registry.getDenominationAsset(), baseCurrency, "Should return base currency");
    }

    function test_getDenominationAsset_ShouldReturnUsdcWhenNoBaseCurrency() public {
        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(address(0)));

        assertEq(registry.getDenominationAsset(), address(usdc), "Should return USDC address");
    }

    function test_getDenominationAssetDecimals_ShouldReturnBaseCurrencyDecimals() public {
        vm.mockCall(baseCurrency, abi.encodeWithSignature("decimals()"), abi.encode(8));
        assertEq(registry.getDenominationAssetDecimals(), 8, "Should return base currency decimals");
    }

    function test_getDenominationAssetDecimals_ShouldReturnUsdcDecimalsWhenNoBaseCurrency() public {
        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(address(0)));

        assertEq(
            registry.getDenominationAssetDecimals(), MockERC20(address(usdc)).decimals(), "Should return USDC decimals"
        );
    }

    function test_getAllowedFacets_ShouldReturnAllFacets() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("test()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        address[] memory facets = registry.getAllowedFacets();
        assertEq(facets.length, 1, "Should return all facets");
        assertEq(facets[0], facet, "Should return correct facet");
    }

    function test_removeFacet_ShouldFindFacetAndRemoveIt() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("test()"));
        selectors[1] = bytes4(keccak256("test2()"));

        address facet2 = address(6);
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = bytes4(keccak256("test3()"));

        vm.startPrank(admin);
        registry.addFacet(facet, selectors);
        registry.addFacet(facet2, selectors2);

        registry.removeFacet(facet2);

        assertEq(registry.getAllowedFacets().length, 1, "Should remove facet");
        assertEq(registry.getAllowedFacets()[0], facet, "Should return correct facet");
        vm.stopPrank();
    }

    function test_addToWhitelist_ShouldWhitelistProtocol() public {
        assertFalse(registry.isWhitelisted(vault), "Should not be whitelisted by default");

        vm.prank(admin);
        registry.addToWhitelist(vault);

        assertTrue(registry.isWhitelisted(vault), "Should be whitelisted after add");
    }

    function test_removeFromWhitelist_ShouldRemoveProtocolFromWhitelist() public {
        vm.prank(admin);
        registry.addToWhitelist(vault);
        assertTrue(registry.isWhitelisted(vault), "Should be whitelisted after add");

        vm.prank(admin);
        registry.removeFromWhitelist(vault);

        assertFalse(registry.isWhitelisted(vault), "Should not be whitelisted after remove");
    }

    function test_addToWhitelist_ShouldRevertWhenNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        registry.addToWhitelist(vault);
    }

    function test_removeFromWhitelist_ShouldRevertWhenNotAdmin() public {
        vm.prank(admin);
        registry.addToWhitelist(vault);

        vm.prank(user);
        vm.expectRevert();
        registry.removeFromWhitelist(vault);
    }

    function test_isWhitelisted_ShouldReturnCorrectValue() public {
        assertEq(registry.isWhitelisted(address(1)), false, "Should not be whitelisted by default");
        vm.prank(admin);
        registry.addToWhitelist(address(1));
        assertTrue(registry.isWhitelisted(address(1)), "Should be whitelisted");

        vm.prank(admin);
        registry.removeFromWhitelist(address(1));
        assertFalse(registry.isWhitelisted(address(1)), "Should not be whitelisted after remove");
    }

    function test_setSelectorAndMask_ShouldSetSelectorAndMask() public {
        bytes4 selector = bytes4(keccak256("test()"));
        bytes memory mask = bytes(abi.encode(type(uint256).max));

        vm.prank(admin);
        registry.setSelectorAndMask(facet, selector, true, mask);

        (bool isAllowed, bytes memory fetchedMask) = registry.selectorInfo(facet, selector);
        assertTrue(isAllowed, "Should allow selector");
        assertEq(mask, fetchedMask, "Should set mask");
    }

    function test_setSelectorAndMask_ShouldRevertWhenNotAdmin() public {
        bytes4 selector = bytes4(keccak256("test()"));
        bytes memory mask = bytes(abi.encode(type(uint256).max));

        vm.prank(user);
        vm.expectRevert();
        registry.setSelectorAndMask(facet, selector, true, mask);
    }

    function test_getSelectorInfo_ShouldReturnSelectorInfo() public {
        bytes4 selector = bytes4(keccak256("test()"));
        bytes memory mask = bytes(abi.encode(type(uint256).max));

        vm.prank(admin);
        registry.setSelectorAndMask(facet, selector, true, mask);

        (bool isAllowed, bytes memory fetchedMask) = registry.selectorInfo(facet, selector);
        assertTrue(isAllowed, "Should allow selector");
        assertEq(mask, fetchedMask, "Should set mask");
    }

    function test_isPermissionless_ShouldReturnFalse() public view {
        assertFalse(registry.isPermissionless());
    }

    function test_setBridge_ShouldSetBridgeAllowed() public {
        address bridge = address(0x1234);

        vm.prank(admin);
        registry.setBridge(bridge, true);

        assertTrue(registry.isBridgeAllowed(bridge));
    }

    function test_setIsCrossChainAccountingManager_ShouldSetManager() public {
        address manager = address(0x5678);

        vm.prank(admin);
        registry.setIsCrossChainAccountingManager(manager, true);

        assertTrue(registry.isCrossChainAccountingManager(manager));
    }

    function test_setDefaultCrossChainAccountingManager_ShouldSetDefaultManager() public {
        address manager = address(0x9ABC);

        registry.setDefaultCrossChainAccountingManager(manager);

        assertEq(registry.defaultCrossChainAccountingManager(), manager);
    }

    function test_isBridgeAllowed_ShouldReturnCorrectValue() public {
        address bridge = address(0xDEF0);

        assertFalse(registry.isBridgeAllowed(bridge));

        vm.prank(admin);
        registry.setBridge(bridge, true);

        assertTrue(registry.isBridgeAllowed(bridge));
    }

    function test_isCrossChainAccountingManager_ShouldReturnCorrectValue() public {
        address manager = address(0x1111);

        assertFalse(registry.isCrossChainAccountingManager(manager));

        vm.prank(admin);
        registry.setIsCrossChainAccountingManager(manager, true);

        assertTrue(registry.isCrossChainAccountingManager(manager));
    }

    function test_editFacet_ShouldRemoveSelectorFromMiddleOfArray() public {
        bytes4[] memory selectors = new bytes4[](3);

        // Add 3 selectors first using addFacet
        selectors[0] = bytes4(keccak256("test1()"));
        selectors[1] = bytes4(keccak256("test2()"));
        selectors[2] = bytes4(keccak256("test3()"));

        vm.prank(admin);
        registry.addFacet(facet, selectors);

        // Now remove the FIRST selector (this will force loop iteration to reach ++j)
        bytes4[] memory removeSelectors = new bytes4[](1);
        bool[] memory removeAllowed = new bool[](1);
        removeSelectors[0] = selectors[0]; // Remove first one
        removeAllowed[0] = false;

        vm.prank(admin);
        registry.editFacet(facet, removeSelectors, removeAllowed);

        // Verify selector was removed
        (bool isAllowed,) = registry.selectorInfo(facet, selectors[0]);
        assertFalse(isAllowed);
    }
}
