// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IMoreVaultsRegistry, BaseVaultsRegistry} from "../../../src/registry/BaseVaultsRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

// Test implementation of BaseVaultsRegistry
contract TestBaseVaultsRegistry is BaseVaultsRegistry {
    // function to exclude from coverage
    function test_skip() external {}

    function _isFacetAllowed(address) internal pure override returns (bool) {
        return true;
    }

    function isPermissionless() external pure override returns (bool) {
        return false;
    }

    function addFacet(address, bytes4[] calldata) external override {}

    function removeFacet(address) external override {}

    function setProtocolFeeInfo(address, address, uint96) external override {}

    function protocolFeeInfo(address) external view override returns (address, uint96) {}

    function addToWhitelist(address) external override {}

    function removeFromWhitelist(address) external override {}

    function setBridge(address, bool) external override {}

    function isBridgeAllowed(address) external view override returns (bool) {}

    function defaultCrossChainAccountingManager() external view override returns (address) {}

    function isCrossChainAccountingManager(address) external view override returns (bool) {}

    function setDefaultCrossChainAccountingManager(address) external override {}

    function isWhitelisted(address) external view override returns (bool) {}

    function setSelectorAndMask(address, bytes4, bool, bytes memory) external override {}

    function selectorInfo(address, bytes4) external view override returns (bool, bytes memory) {}
}

contract BaseVaultsRegistryTest is Test {
    TestBaseVaultsRegistry public registry;
    MockERC20 public usdc;
    address public admin = address(1);
    address public user = address(2);
    address public oracle = address(3);
    address public baseCurrency = address(4);

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC");

        // Deploy registry
        vm.prank(admin);
        registry = new TestBaseVaultsRegistry();

        // Mock oracle calls
        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(baseCurrency));
    }

    function test_initialize_ShouldSetInitialValues() public {
        vm.prank(admin);
        registry.initialize(admin, address(oracle), address(usdc));
        assertEq(address(registry.oracle()), oracle, "Should set correct oracle");
        assertEq(registry.usdStableTokenAddress(), address(usdc), "Should set correct USDC address");
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), "Should set admin role");
    }

    function test_initialize_ShouldRevertWithZeroOracle() public {
        vm.expectRevert(IMoreVaultsRegistry.ZeroAddress.selector);
        registry.initialize(admin, address(0), address(usdc));
    }

    function test_updateOracle_ShouldUpdateOracle() public {
        address newOracle = address(5);

        vm.prank(admin);
        registry.initialize(admin, address(oracle), address(usdc));
        vm.prank(admin);
        registry.updateOracleRegistry(newOracle);

        assertEq(address(registry.oracle()), newOracle, "Should update oracle");
    }

    function test_updateOracle_ShouldRevertWithZeroAddress() public {
        vm.prank(admin);
        registry.initialize(admin, address(oracle), address(usdc));
        vm.expectRevert(IMoreVaultsRegistry.ZeroAddress.selector);
        vm.prank(admin);
        registry.updateOracleRegistry(address(0));
    }

    function test_updateOracle_ShouldRevertWhenNotAdmin() public {
        registry.initialize(admin, address(oracle), address(usdc));

        vm.prank(user);
        vm.expectRevert();
        registry.updateOracleRegistry(address(0));
    }

    function test_getDenominationAsset_ShouldReturnBaseCurrency() public {
        registry.initialize(admin, address(oracle), address(usdc));

        assertEq(registry.getDenominationAsset(), baseCurrency, "Should return base currency");
    }

    function test_getDenominationAsset_ShouldReturnUsdcWhenNoBaseCurrency() public {
        registry.initialize(admin, address(oracle), address(usdc));

        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(address(0)));

        assertEq(registry.getDenominationAsset(), address(usdc), "Should return USDC address");
    }

    function test_getDenominationAssetDecimals_ShouldReturnBaseCurrencyDecimals() public {
        registry.initialize(admin, address(oracle), address(usdc));

        vm.mockCall(baseCurrency, abi.encodeWithSignature("decimals()"), abi.encode(18));

        assertEq(registry.getDenominationAssetDecimals(), 18, "Should return base currency decimals");
    }

    function test_getDenominationAssetDecimals_ShouldReturnUsdcDecimalsWhenNoBaseCurrency() public {
        registry.initialize(admin, address(oracle), address(usdc));

        vm.mockCall(oracle, abi.encodeWithSignature("BASE_CURRENCY()"), abi.encode(address(0)));

        assertEq(
            registry.getDenominationAssetDecimals(), MockERC20(address(usdc)).decimals(), "Should return USDC decimals"
        );
    }

    function test_isBridgeAllowed_ShouldReturnCorrectValue() public {
        vm.startPrank(admin);
        registry.initialize(admin, address(oracle), address(usdc));

        assertFalse(registry.isBridgeAllowed(address(1111)), "Should not allow unknown bridge");

        registry.setBridge(address(1111), true);
        vm.stopPrank();
    }
}
