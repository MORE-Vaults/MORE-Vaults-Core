// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ConfigurationFacet} from "../../../src/facets/ConfigurationFacet.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";

contract ConfigurationFacetTest is Test {
    ConfigurationFacet public facet;

    address public owner = address(1);
    address public curator = address(2);
    address public unauthorized = address(3);
    address public newFeeRecipient = address(4);
    address public asset1 = address(5);
    address public asset2 = address(6);
    address public zeroAddress = address(0);
    address public guardian = address(7);
    address public registry = address(8);
    address public oracle = address(9);

    // Storage slot for AccessControlStorage struct
    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION =
        AccessControlLib.ACCESS_CONTROL_STORAGE_POSITION;

    function setUp() public {
        // Deploy facet
        facet = new ConfigurationFacet();

        // Set owner role
        MoreVaultsStorageHelper.setOwner(address(facet), owner);

        // Set curator role
        MoreVaultsStorageHelper.setCurator(address(facet), curator);

        // Set guardian role
        MoreVaultsStorageHelper.setGuardian(address(facet), guardian);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);

        // Set initial values using helper library
        MoreVaultsStorageHelper.setFeeRecipient(address(facet), address(1));
        MoreVaultsStorageHelper.setFee(address(facet), 100); // 1%
        MoreVaultsStorageHelper.setTimeLockPeriod(address(facet), 1 days);

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset1
            ),
            abi.encode(address(1000), uint96(1000))
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset2
            ),
            abi.encode(address(1001), uint96(1001))
        );
    }

    function test_initialize_shouldSetCorrectValues() public {
        facet.initialize(abi.encode(10_000));
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IConfigurationFacet).interfaceId
            ),
            true,
            "Supported interfaces should be set"
        );
    }
    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            facet.facetName(),
            "ConfigurationFacet",
            "Facet name should be correct"
        );
    }

    function test_facetVersion_ShouldReturnCorrectVersion() public view {
        assertEq(
            facet.facetVersion(),
            "1.0.0",
            "Facet version should be correct"
        );
    }

    function test_onFacetRemoval_ShouldDisableInterface() public {
        facet.onFacetRemoval(false);
        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IConfigurationFacet).interfaceId
            )
        );
    }

    function test_setMaxSlippagePercent_ShouldUpdateMaxSlippagePercent()
        public
    {
        vm.startPrank(owner);
        facet.setMaxSlippagePercent(10000);
        vm.stopPrank();
        assertEq(
            MoreVaultsStorageHelper.getSlippagePercent(address(facet)),
            10000,
            "Max slippage percent should be updated"
        );
    }

    function test_setGasLimitForAccounting_ShouldUpdateGasLimitForAccounting()
        public
    {
        vm.startPrank(owner);
        facet.setGasLimitForAccounting(10000, 10000, 10000, 10000);
        vm.stopPrank();
        MoreVaultsLib.GasLimit memory gasLimit = MoreVaultsStorageHelper
            .getGasLimitForAccounting(address(facet));
        assertEq(gasLimit.availableTokenAccountingGas, 10000);
        assertEq(gasLimit.heldTokenAccountingGas, 10000);
        assertEq(gasLimit.facetAccountingGas, 10000);
        assertEq(gasLimit.stakingTokenAccountingGas, 10000);
        assertEq(gasLimit.nestedVaultsGas, 10000);
        assertEq(gasLimit.value, 10000);
    }

    function test_fee_shouldReturnCorrectFee() public view {
        assertEq(facet.fee(), 100);
    }

    function test_feeRecipient_shouldReturnCorrectFeeRecipient() public view {
        assertEq(facet.feeRecipient(), address(1));
    }

    function test_depositCapacity_shouldReturnCorrectDepositCapacity()
        public
        view
    {
        assertEq(facet.depositCapacity(), 0);
    }

    function test_timeLockPeriod_shouldReturnCorrectTimeLockPeriod()
        public
        view
    {
        assertEq(facet.timeLockPeriod(), 1 days);
    }

    function test_setFeeRecipient_ShouldUpdateRecipient() public {
        vm.startPrank(owner);

        // Set new fee recipient
        facet.setFeeRecipient(newFeeRecipient);
        // Verify through getter
        assertEq(
            MoreVaultsStorageHelper.getFeeRecipient(address(facet)),
            newFeeRecipient,
            "Fee recipient should be updated"
        );

        vm.stopPrank();
    }

    function test_setFeeRecipient_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to set new fee recipient
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.setFeeRecipient(newFeeRecipient);

        // Verify fee recipient remains unchanged
        assertEq(
            MoreVaultsStorageHelper.getFeeRecipient(address(facet)),
            address(1),
            "Fee recipient should not be changed"
        );

        vm.stopPrank();
    }

    function test_setFeeRecipient_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(owner);

        // Attempt to set zero address as fee recipient
        vm.expectRevert(MoreVaultsLib.ZeroAddress.selector);
        facet.setFeeRecipient(zeroAddress);

        vm.stopPrank();
    }

    function test_setTimeLockPeriod_ShouldUpdatePeriod() public {
        vm.startPrank(owner);

        // Set new time lock period
        uint256 newPeriod = 2 days;

        facet.setTimeLockPeriod(newPeriod);

        // Verify through getter
        assertEq(
            MoreVaultsStorageHelper.getTimeLockPeriod(address(facet)),
            newPeriod,
            "Time lock period should be updated"
        );
    }

    function test_setDepositCapacity_ShouldUpdateDepositCapacity() public {
        vm.startPrank(owner);

        // Set new deposit capacity
        uint256 newCapacity = 1000000 ether;
        facet.setDepositCapacity(newCapacity);

        assertEq(
            MoreVaultsStorageHelper.getDepositCapacity(address(facet)),
            newCapacity,
            "Deposit capacity should be updated"
        );

        vm.stopPrank();
    }

    function test_setDepositCapacity_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Set new deposit capacity
        uint256 newCapacity = 1000000 ether;
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.setDepositCapacity(newCapacity);
    }

    function test_addAvailableAsset_ShouldAddAsset() public {
        vm.startPrank(curator);

        // Add assets
        facet.addAvailableAsset(asset1);

        // Verify assets are available
        assertTrue(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1),
            "Asset1 should be available"
        );

        // Verify assets are in available assets array
        address[] memory availableAssets = MoreVaultsStorageHelper
            .getAvailableAssets(address(facet));
        assertEq(
            availableAssets.length,
            1,
            "Available assets array should have two elements"
        );
        assertEq(
            availableAssets[0],
            asset1,
            "Asset1 should be in available assets array"
        );

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to add new asset
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.addAvailableAsset(asset1);

        // Verify asset is not available
        assertFalse(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1),
            "Asset should not be available"
        );

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        // Attempt to add zero address as asset
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.addAvailableAsset(zeroAddress);

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenAssetAlreadyAvailable()
        public
    {
        vm.startPrank(curator);

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset1
            ),
            abi.encode(address(1000), uint96(1000))
        );

        // Add asset first time
        facet.addAvailableAsset(asset1);

        // Attempt to add same asset again
        vm.expectRevert(IConfigurationFacet.AssetAlreadyAvailable.selector);
        facet.addAvailableAsset(asset1);

        vm.stopPrank();
    }

    function test_addAvailableAssets_ShouldAddAssets() public {
        vm.startPrank(curator);

        // Prepare assets array
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        // Add assets
        facet.addAvailableAssets(assets);

        // Verify assets are available
        assertTrue(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1),
            "Asset1 should be available"
        );
        assertTrue(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset2),
            "Asset2 should be available"
        );

        // Verify assets are in available assets array
        address[] memory availableAssets = MoreVaultsStorageHelper
            .getAvailableAssets(address(facet));
        assertEq(
            availableAssets.length,
            2,
            "Available assets array should have two elements"
        );
        assertEq(
            availableAssets[0],
            asset1,
            "Asset1 should be in available assets array"
        );
        assertEq(
            availableAssets[1],
            asset2,
            "Asset2 should be in available assets array"
        );

        vm.stopPrank();
    }

    function test_addAvailableAssets_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Prepare assets array
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        // Attempt to add assets
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.addAvailableAssets(assets);

        // Verify assets are not available
        assertFalse(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1),
            "Asset1 should not be available"
        );
        assertFalse(
            MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset2),
            "Asset2 should not be available"
        );

        vm.stopPrank();
    }

    function test_addAvailableAssets_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        // Prepare assets array with zero address
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = zeroAddress;

        // Attempt to add assets
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.addAvailableAssets(assets);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to add new asset
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.enableAssetToDeposit(asset1);

        // Verify asset is not available
        assertFalse(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1),
            "Asset should not be enabled to deposit"
        );

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        // Attempt to add zero address as asset
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.enableAssetToDeposit(zeroAddress);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertWhenAssetAlreadyAvailable()
        public
    {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);

        // Enable asset first time
        facet.enableAssetToDeposit(asset1);

        // Attempt to add same asset again
        vm.expectRevert(IConfigurationFacet.AssetAlreadyAvailable.selector);
        facet.enableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertIfAssetIsNotAvailableForManage()
        public
    {
        vm.startPrank(curator);

        // Attempt to add same asset again
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.UnsupportedAsset.selector,
                asset1
            )
        );
        facet.enableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldEnableAsset() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);

        // Enable asset to deposit
        facet.enableAssetToDeposit(asset1);

        // Verify assets are available
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1),
            "Asset1 should be enabled to deposit"
        );
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(
            depositableAssets.length,
            1,
            "Depositable assets array should have one element"
        );
        assertEq(
            depositableAssets[0],
            asset1,
            "Depositable assets array should have asset1"
        );

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to disable asset
        MoreVaultsStorageHelper.setDepositableAssets(
            address(facet),
            asset1,
            true
        );
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.disableAssetToDeposit(asset1);

        // Verify asset still enabled to deposit
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1),
            "Asset should be enabled to deposit"
        );

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        MoreVaultsStorageHelper.setDepositableAssets(
            address(facet),
            asset1,
            true
        );
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.disableAssetToDeposit(zeroAddress);

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenAssetAlreadyDisabled()
        public
    {
        vm.startPrank(curator);

        // Attempt to add same asset again
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.UnsupportedAsset.selector,
                asset1
            )
        );
        facet.disableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldDisableAsset() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);
        // Enable asset first time
        facet.enableAssetToDeposit(asset1);
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1),
            "Asset1 should be enabled to deposit"
        );
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(
            depositableAssets.length,
            1,
            "Depositable assets array should have one element"
        );
        assertEq(
            depositableAssets[0],
            asset1,
            "Depositable assets array should have asset1"
        );

        facet.disableAssetToDeposit(asset1);

        // Verify assets are available
        assertFalse(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1),
            "Asset1 should be disabled to deposit"
        );
        depositableAssets = facet.getDepositableAssets();
        assertEq(
            depositableAssets.length,
            0,
            "Depositable assets array should be empty"
        );

        vm.stopPrank();
    }

    function test_isAssetAvailable_ShouldReturnCorrectValue() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);

        // Verify asset is available
        assertTrue(facet.isAssetAvailable(asset1), "Asset should be available");

        // Verify non-existent asset is not available
        assertFalse(
            facet.isAssetAvailable(asset2),
            "Asset should not be available"
        );

        vm.stopPrank();
    }

    function test_isAssetDepositable_ShouldReturnCorrectValue() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);
        facet.enableAssetToDeposit(asset1);

        // Verify asset is available
        assertTrue(
            facet.isAssetDepositable(asset1),
            "Asset should be available to deposit"
        );

        // Verify non-existent asset is not available
        assertFalse(
            facet.isAssetDepositable(asset2),
            "Asset should not be available to deposit"
        );

        vm.stopPrank();
    }

    function test_getAvailableAssets_ShouldReturnCorrectArray() public {
        vm.startPrank(curator);

        // Add assets
        facet.addAvailableAsset(asset1);
        facet.addAvailableAsset(asset2);

        // Get available assets
        address[] memory assets = facet.getAvailableAssets();

        // Verify array
        assertEq(assets.length, 2, "Array should have two elements");
        assertEq(assets[0], asset1, "First element should be asset1");
        assertEq(assets[1], asset2, "Second element should be asset2");

        vm.stopPrank();
    }

    function test_setDepositWhitelist_ShouldUpdateDepositWhitelist() public {
        vm.startPrank(curator);

        address[] memory depositors = new address[](1);
        depositors[0] = address(1);
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        facet.setDepositWhitelist(depositors, undelyingAssetCaps);
        vm.stopPrank();

        assertEq(facet.getDepositWhitelist(address(1)), 10 ether);
    }

    function test_setDepositWhitelist_ShouldRevertWhenUnauthorized() public {
        address[] memory depositors = new address[](1);
        depositors[0] = address(1);
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;

        vm.startPrank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.setDepositWhitelist(depositors, undelyingAssetCaps);
        vm.stopPrank();
    }

    function test_setDepositWhitelist_ShouldRevertWhenArraysLengthsMismatch()
        public
    {
        address[] memory depositors = new address[](1);
        depositors[0] = address(1);
        uint256[] memory undelyingAssetCaps = new uint256[](2);
        undelyingAssetCaps[0] = 10 ether;
        undelyingAssetCaps[1] = 20 ether;
        vm.startPrank(curator);
        vm.expectRevert(IConfigurationFacet.ArraysLengthsMismatch.selector);
        facet.setDepositWhitelist(depositors, undelyingAssetCaps);
        vm.stopPrank();
    }

    function test_enableDepositWhitelist_ShouldEnableDepositWhitelist() public {
        vm.startPrank(curator);
        facet.enableDepositWhitelist();
        vm.stopPrank();
        assertTrue(
            facet.isDepositWhitelistEnabled(),
            "Deposit whitelist should be enabled"
        );
    }

    function test_disableDepositWhitelist_ShouldDisableDepositWhitelist()
        public
    {
        vm.startPrank(curator);
        facet.disableDepositWhitelist();
        vm.stopPrank();
        assertFalse(
            facet.isDepositWhitelistEnabled(),
            "Deposit whitelist should be disabled"
        );
    }

    function test_getDepositableAssets_ShouldReturnCorrectArray() public {
        vm.startPrank(curator);
        facet.addAvailableAsset(asset1);
        facet.enableAssetToDeposit(asset1);
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(
            depositableAssets.length,
            1,
            "Depositable assets array should have one element"
        );
        assertEq(
            depositableAssets[0],
            asset1,
            "Depositable assets array should have asset1"
        );
    }
}
