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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

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
    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION = AccessControlLib.ACCESS_CONTROL_STORAGE_POSITION;

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

        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset1),
            abi.encode(address(1000), uint96(1000))
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset2),
            abi.encode(address(1001), uint96(1001))
        );

        // Mock balanceOf for asset1 and asset2 to return 0 (no existing balance)
        vm.mockCall(asset1, abi.encodeWithSelector(IERC20.balanceOf.selector, address(facet)), abi.encode(0));
        vm.mockCall(asset2, abi.encodeWithSelector(IERC20.balanceOf.selector, address(facet)), abi.encode(0));
    }

    function test_initialize_shouldSetCorrectValues() public {
        facet.initialize(abi.encode(10_000));
        assertEq(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IConfigurationFacet).interfaceId),
            true,
            "Supported interfaces should be set"
        );
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "ConfigurationFacet", "Facet name should be correct");
    }

    function test_facetVersion_ShouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0", "Facet version should be correct");
    }

    function test_onFacetRemoval_ShouldDisableInterface() public {
        facet.onFacetRemoval(false);
        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IConfigurationFacet).interfaceId)
        );
    }

    function test_setMaxSlippagePercent_ShouldUpdateMaxSlippagePercent() public {
        vm.startPrank(address(facet));
        facet.setMaxSlippagePercent(2000);
        vm.stopPrank();
        assertEq(
            MoreVaultsStorageHelper.getSlippagePercent(address(facet)), 2000, "Max slippage percent should be updated"
        );
    }

    function test_setMaxSlippagePercent_ShouldRevertWhenSlippageTooHigh() public {
        vm.startPrank(address(facet));
        vm.expectRevert(IConfigurationFacet.SlippageTooHigh.selector);
        facet.setMaxSlippagePercent(2001);
        vm.stopPrank();
    }

    function test_setGasLimitForAccounting_ShouldUpdateGasLimitForAccounting() public {
        vm.startPrank(address(facet));
        facet.setGasLimitForAccounting(10000, 10000, 10000, 10000);
        vm.stopPrank();
        MoreVaultsLib.GasLimit memory gasLimit = MoreVaultsStorageHelper.getGasLimitForAccounting(address(facet));
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

    function test_depositCapacity_shouldReturnCorrectDepositCapacity() public view {
        assertEq(facet.depositCapacity(), 0);
    }

    function test_timeLockPeriod_shouldReturnCorrectTimeLockPeriod() public view {
        assertEq(facet.timeLockPeriod(), 1 days);
    }

    function test_setFeeRecipient_ShouldUpdateRecipient() public {
        vm.startPrank(owner);

        // Set new fee recipient
        facet.setFeeRecipient(newFeeRecipient);
        // Verify through getter
        assertEq(
            MoreVaultsStorageHelper.getFeeRecipient(address(facet)), newFeeRecipient, "Fee recipient should be updated"
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
            MoreVaultsStorageHelper.getFeeRecipient(address(facet)), address(1), "Fee recipient should not be changed"
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
        vm.startPrank(address(facet));

        // Set new time lock period
        uint256 newPeriod = 2 days;

        facet.setTimeLockPeriod(newPeriod);

        // Verify through getter
        assertEq(
            MoreVaultsStorageHelper.getTimeLockPeriod(address(facet)), newPeriod, "Time lock period should be updated"
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
        assertTrue(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1), "Asset1 should be available");

        // Verify assets are in available assets array
        address[] memory availableAssets = MoreVaultsStorageHelper.getAvailableAssets(address(facet));
        assertEq(availableAssets.length, 1, "Available assets array should have two elements");
        assertEq(availableAssets[0], asset1, "Asset1 should be in available assets array");

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to add new asset
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.addAvailableAsset(asset1);

        // Verify asset is not available
        assertFalse(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1), "Asset should not be available");

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        // Attempt to add zero address as asset
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.addAvailableAsset(zeroAddress);

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenAssetAlreadyAvailable() public {
        vm.startPrank(curator);

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset1),
            abi.encode(address(1000), uint96(1000))
        );

        // Add asset first time
        facet.addAvailableAsset(asset1);

        // Attempt to add same asset again
        vm.expectRevert(IConfigurationFacet.AssetAlreadyAvailable.selector);
        facet.addAvailableAsset(asset1);

        vm.stopPrank();
    }

    function test_addAvailableAsset_ShouldRevertWhenAssetHasExistingBalance() public {
        // Create a token and send it to the vault (simulate accidental transfer)
        MockERC20 token = new MockERC20("Accidental Token", "ACC");
        token.mint(address(facet), 1000 ether);

        // Mock oracle for this token
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(token)),
            abi.encode(address(2000), uint96(2000))
        );

        vm.startPrank(curator);

        // Should revert because vault has balance of this token
        vm.expectRevert(IConfigurationFacet.CannotAddAssetWithExistingBalance.selector);
        facet.addAvailableAsset(address(token));

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
        assertTrue(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1), "Asset1 should be available");
        assertTrue(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset2), "Asset2 should be available");

        // Verify assets are in available assets array
        address[] memory availableAssets = MoreVaultsStorageHelper.getAvailableAssets(address(facet));
        assertEq(availableAssets.length, 2, "Available assets array should have two elements");
        assertEq(availableAssets[0], asset1, "Asset1 should be in available assets array");
        assertEq(availableAssets[1], asset2, "Asset2 should be in available assets array");

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
        assertFalse(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset1), "Asset1 should not be available");
        assertFalse(MoreVaultsStorageHelper.isAssetAvailable(address(facet), asset2), "Asset2 should not be available");

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

    function test_addAvailableAssets_ShouldRevertWhenAssetHasExistingBalance() public {
        // Create two tokens, one with balance
        MockERC20 token1 = new MockERC20("Token 1", "TK1");
        MockERC20 token2 = new MockERC20("Token 2", "TK2");

        // Give vault balance of token2 (simulate accidental transfer)
        token2.mint(address(facet), 500 ether);

        // Mock oracles
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(token1)),
            abi.encode(address(3000), uint96(3000))
        );
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(token2)),
            abi.encode(address(3001), uint96(3001))
        );

        address[] memory assets = new address[](2);
        assets[0] = address(token1);
        assets[1] = address(token2);

        vm.startPrank(curator);

        // Should revert on token2 because it has existing balance
        vm.expectRevert(IConfigurationFacet.CannotAddAssetWithExistingBalance.selector);
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
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1), "Asset should not be enabled to deposit"
        );

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(address(facet));

        // Attempt to add zero address as asset
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.enableAssetToDeposit(zeroAddress);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertWhenAssetAlreadyAvailable() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);

        vm.stopPrank();
        vm.startPrank(address(facet));
        // Enable asset first time
        facet.enableAssetToDeposit(asset1);

        // Attempt to add same asset again
        vm.expectRevert(IConfigurationFacet.AssetAlreadyAvailable.selector);
        facet.enableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldRevertIfAssetIsNotAvailableForManage() public {
        vm.startPrank(address(facet));

        // Attempt to add same asset again
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, asset1));
        facet.enableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_enableAssetToDeposit_ShouldEnableAsset() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);
        vm.stopPrank();
        vm.startPrank(address(facet));
        // Enable asset to deposit
        facet.enableAssetToDeposit(asset1);

        // Verify assets are available
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1), "Asset1 should be enabled to deposit"
        );
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(depositableAssets.length, 1, "Depositable assets array should have one element");
        assertEq(depositableAssets[0], asset1, "Depositable assets array should have asset1");

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenUnauthorized() public {
        vm.startPrank(unauthorized);

        // Attempt to disable asset
        MoreVaultsStorageHelper.setDepositableAssets(address(facet), asset1, true);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.disableAssetToDeposit(asset1);

        // Verify asset still enabled to deposit
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1), "Asset should be enabled to deposit"
        );

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenZeroAddress() public {
        vm.startPrank(curator);

        MoreVaultsStorageHelper.setDepositableAssets(address(facet), asset1, true);
        vm.expectRevert(IConfigurationFacet.InvalidAddress.selector);
        facet.disableAssetToDeposit(zeroAddress);

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldRevertWhenAssetAlreadyDisabled() public {
        vm.startPrank(curator);

        // Attempt to add same asset again
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, asset1));
        facet.disableAssetToDeposit(asset1);

        vm.stopPrank();
    }

    function test_disableAssetToDeposit_ShouldDisableAsset() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);
        // Enable asset first time
        vm.stopPrank();
        vm.startPrank(address(facet));
        facet.enableAssetToDeposit(asset1);
        assertTrue(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1), "Asset1 should be enabled to deposit"
        );
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(depositableAssets.length, 1, "Depositable assets array should have one element");
        assertEq(depositableAssets[0], asset1, "Depositable assets array should have asset1");
        vm.stopPrank();
        vm.startPrank(curator);
        facet.disableAssetToDeposit(asset1);

        // Verify assets are available
        assertFalse(
            MoreVaultsStorageHelper.isAssetDepositable(address(facet), asset1), "Asset1 should be disabled to deposit"
        );
        depositableAssets = facet.getDepositableAssets();
        assertEq(depositableAssets.length, 0, "Depositable assets array should be empty");

        vm.stopPrank();
    }

    function test_isAssetAvailable_ShouldReturnCorrectValue() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);

        // Verify asset is available
        assertTrue(facet.isAssetAvailable(asset1), "Asset should be available");

        // Verify non-existent asset is not available
        assertFalse(facet.isAssetAvailable(asset2), "Asset should not be available");

        vm.stopPrank();
    }

    function test_isAssetDepositable_ShouldReturnCorrectValue() public {
        vm.startPrank(curator);

        // Add asset
        facet.addAvailableAsset(asset1);
        vm.stopPrank();
        vm.startPrank(address(facet));
        facet.enableAssetToDeposit(asset1);

        // Verify asset is available
        assertTrue(facet.isAssetDepositable(asset1), "Asset should be available to deposit");

        // Verify non-existent asset is not available
        assertFalse(facet.isAssetDepositable(asset2), "Asset should not be available to deposit");

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
        vm.startPrank(owner);

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

    function test_setDepositWhitelist_ShouldRevertWhenArraysLengthsMismatch() public {
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
        vm.startPrank(owner);
        facet.enableDepositWhitelist();
        vm.stopPrank();
        assertTrue(facet.isDepositWhitelistEnabled(), "Deposit whitelist should be enabled");
    }

    function test_disableDepositWhitelist_ShouldDisableDepositWhitelist() public {
        vm.startPrank(address(facet));
        facet.disableDepositWhitelist();
        vm.stopPrank();
        assertFalse(facet.isDepositWhitelistEnabled(), "Deposit whitelist should be disabled");
    }

    function test_getDepositableAssets_ShouldReturnCorrectArray() public {
        vm.startPrank(curator);
        facet.addAvailableAsset(asset1);
        vm.stopPrank();
        vm.startPrank(address(facet));
        facet.enableAssetToDeposit(asset1);
        address[] memory depositableAssets = facet.getDepositableAssets();
        assertEq(depositableAssets.length, 1, "Depositable assets array should have one element");
        assertEq(depositableAssets[0], asset1, "Depositable assets array should have asset1");
    }

    function test_getWithdrawalFee_ShouldReturnCorrectFee() public {
        vm.startPrank(address(facet));
        facet.setWithdrawalFee(1000);
        vm.stopPrank();
        assertEq(facet.getWithdrawalFee(), 1000);
    }

    function test_getWithdrawalQueueStatus_ShouldReturnCorrectStatus() public {
        vm.startPrank(address(facet));
        facet.updateWithdrawalQueueStatus(true);
        vm.stopPrank();
        assertTrue(facet.getWithdrawalQueueStatus());
    }

    function test_getWithdrawalFee2_ShouldReturnCorrectFee() public {
        vm.startPrank(owner);
        MoreVaultsStorageHelper.setWithdrawalFee(address(facet), uint96(1000));
        vm.stopPrank();
        assertEq(facet.getWithdrawalFee(), 1000);
    }

    function test_getWithdrawalQueueStatus2_ShouldReturnCorrectStatus() public {
        vm.startPrank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(address(facet), true);
        vm.stopPrank();
        assertTrue(facet.getWithdrawalQueueStatus());
    }

    // ===== Tests for recoverAssets =====

    function test_recoverAssets_ShouldRecoverWhenGuardianCalls() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Test Token", "TST");

        // Mint tokens to the facet (simulating accidentally sent tokens)
        token.mint(address(facet), 1000 ether);

        address receiver = address(0x999);

        vm.startPrank(guardian);

        // Expect event emission
        vm.expectEmit(true, true, false, true);
        emit IConfigurationFacet.AssetsRecovered(address(token), receiver, 500 ether);

        // Recover assets
        facet.recoverAssets(address(token), receiver, 500 ether);

        vm.stopPrank();

        // Verify balances
        assertEq(token.balanceOf(receiver), 500 ether, "Receiver should have received tokens");
        assertEq(token.balanceOf(address(facet)), 500 ether, "Facet should have remaining tokens");
    }

    function test_recoverAssets_ShouldRecoverWhenOwnerCalls() public {
        // Create a mock ERC20 token
        MockERC20 token = new MockERC20("Test Token", "TST");

        // Mint tokens to the facet
        token.mint(address(facet), 1000 ether);

        address receiver = address(0x999);

        vm.startPrank(owner);

        // Recover assets (owner has guardian permissions)
        facet.recoverAssets(address(token), receiver, 1000 ether);

        vm.stopPrank();

        // Verify balances
        assertEq(token.balanceOf(receiver), 1000 ether, "Receiver should have received all tokens");
        assertEq(token.balanceOf(address(facet)), 0, "Facet should have no tokens left");
    }

    function test_recoverAssets_ShouldRevertWhenUnauthorized() public {
        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), 1000 ether);

        vm.startPrank(unauthorized);

        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.recoverAssets(address(token), address(0x999), 500 ether);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRevertWhenAssetIsAvailable() public {
        // Create a mock token and use it as an available asset
        MockERC20 availableToken = new MockERC20("Available Token", "AVL");

        // Mock oracle for this token
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(availableToken)),
            abi.encode(address(1002), uint96(1002))
        );

        // Add token as available asset FIRST (before minting)
        vm.startPrank(curator);
        facet.addAvailableAsset(address(availableToken));
        vm.stopPrank();

        // Now mint tokens to the vault
        availableToken.mint(address(facet), 1000 ether);

        // Should revert when trying to recover available asset
        vm.startPrank(guardian);
        vm.expectRevert(IConfigurationFacet.AssetIsAvailable.selector);
        facet.recoverAssets(address(availableToken), address(0x999), 100 ether);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRecoverVaultShares() public {
        // In a real scenario, vault shares would be ERC20 tokens (the vault itself is an ERC20)
        // We create a mock token to simulate vault shares sent to the vault by mistake
        MockERC20 vaultSharesToken = new MockERC20("Vault Shares", "vSHARE");

        // Mint some tokens to the facet (simulating vault shares accidentally sent)
        vaultSharesToken.mint(address(facet), 100 ether);

        vm.startPrank(guardian);

        // Guardian should be able to recover any token, including ones that represent vault shares
        facet.recoverAssets(address(vaultSharesToken), address(0x999), 50 ether);

        vm.stopPrank();

        // Verify balances
        assertEq(vaultSharesToken.balanceOf(address(0x999)), 50 ether, "Receiver should have received tokens");
        assertEq(vaultSharesToken.balanceOf(address(facet)), 50 ether, "Facet should have remaining tokens");
    }

    function test_recoverAssets_ShouldRevertWhenInsufficientBalance() public {
        MockERC20 token = new MockERC20("Test Token", "TST");
        // Mint only 100 tokens
        token.mint(address(facet), 100 ether);

        vm.startPrank(guardian);

        // Try to recover 200 tokens - should revert from SafeERC20
        vm.expectRevert();
        facet.recoverAssets(address(token), address(0x999), 200 ether);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRevertWhenAmountIsZero() public {
        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), 1000 ether);

        vm.startPrank(guardian);

        vm.expectRevert(IConfigurationFacet.InvalidAmount.selector);
        facet.recoverAssets(address(token), address(0x999), 0);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRevertWhenReceiverIsZeroAddress() public {
        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), 1000 ether);

        vm.startPrank(guardian);

        vm.expectRevert(IConfigurationFacet.InvalidReceiver.selector);
        facet.recoverAssets(address(token), address(0), 500 ether);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRevertDuringMulticall() public {
        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), 1000 ether);

        // Set isMulticall to true
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        vm.startPrank(guardian);

        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        facet.recoverAssets(address(token), address(0x999), 500 ether);

        vm.stopPrank();
    }

    function testFuzz_recoverAssets_ShouldRecoverVariousAmounts(uint256 amount) public {
        // Bound the amount to reasonable values
        amount = bound(amount, 1, 1e27); // 1 to 1 billion tokens

        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), amount);

        address receiver = address(0x999);

        vm.startPrank(guardian);
        facet.recoverAssets(address(token), receiver, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(receiver), amount, "Receiver should have received exact amount");
        assertEq(token.balanceOf(address(facet)), 0, "Facet should have no tokens left");
    }

    function test_recoverAssets_ShouldNotAffectAvailableAssets() public {
        // Create an available token
        MockERC20 availableAsset = new MockERC20("Available", "AVL");

        // Mock oracle for available asset
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(availableAsset)),
            abi.encode(address(5000), uint96(5000))
        );

        // Add availableAsset as available (balance is 0 at this point)
        vm.startPrank(curator);
        facet.addAvailableAsset(address(availableAsset));
        vm.stopPrank();

        // Create a different token that is NOT available
        MockERC20 token = new MockERC20("Test Token", "TST");
        token.mint(address(facet), 1000 ether);

        vm.startPrank(guardian);

        // Should be able to recover non-available asset
        facet.recoverAssets(address(token), address(0x999), 500 ether);

        vm.stopPrank();

        // Verify availableAsset is still available
        assertTrue(facet.isAssetAvailable(address(availableAsset)), "Available asset should still be available");
    }

    function test_recoverAssets_ShouldRevertWhenAssetIsHeldToken() public {
        // Create a mock LP token
        MockERC20 lpToken = new MockERC20("LP Token", "LP");

        // Simulate that this token is held by a facet (e.g., ERC4626 facet)
        bytes32 heldId = keccak256("TEST_FACET_ID");

        // Register this as a held token ID in vaultExternalAssets
        MoreVaultsStorageHelper.addVaultExternalAsset(address(facet), uint8(MoreVaultsLib.TokenType.HeldToken), heldId);

        // Add the LP token to tokensHeld for this facet
        address[] memory tokensToAdd = new address[](1);
        tokensToAdd[0] = address(lpToken);
        MoreVaultsStorageHelper.setTokensHeld(address(facet), heldId, tokensToAdd);

        // Mint some LP tokens to the vault
        lpToken.mint(address(facet), 1000 ether);

        // Try to recover - should revert
        vm.startPrank(guardian);
        vm.expectRevert(IConfigurationFacet.AssetIsHeldToken.selector);
        facet.recoverAssets(address(lpToken), address(0x999), 500 ether);
        vm.stopPrank();
    }

    function test_recoverAssets_ShouldRevertForMultipleHeldTokenTypes() public {
        // Create multiple mock tokens for different facets
        MockERC20 erc4626Token = new MockERC20("ERC4626 Token", "E4626");
        MockERC20 erc7540Token = new MockERC20("ERC7540 Token", "E7540");

        bytes32 erc4626Id = keccak256("ERC4626_FACET");
        bytes32 erc7540Id = keccak256("ERC7540_FACET");

        // Register both as held token IDs
        MoreVaultsStorageHelper.addVaultExternalAsset(
            address(facet), uint8(MoreVaultsLib.TokenType.HeldToken), erc4626Id
        );
        MoreVaultsStorageHelper.addVaultExternalAsset(
            address(facet), uint8(MoreVaultsLib.TokenType.HeldToken), erc7540Id
        );

        // Add ERC4626 token to first held set
        address[] memory tokens4626 = new address[](1);
        tokens4626[0] = address(erc4626Token);
        MoreVaultsStorageHelper.setTokensHeld(address(facet), erc4626Id, tokens4626);

        // Add ERC7540 token to second held set
        address[] memory tokens7540 = new address[](1);
        tokens7540[0] = address(erc7540Token);
        MoreVaultsStorageHelper.setTokensHeld(address(facet), erc7540Id, tokens7540);

        // Mint tokens
        erc4626Token.mint(address(facet), 1000 ether);
        erc7540Token.mint(address(facet), 2000 ether);

        vm.startPrank(guardian);

        // Should revert for ERC4626 token
        vm.expectRevert(IConfigurationFacet.AssetIsHeldToken.selector);
        facet.recoverAssets(address(erc4626Token), address(0x999), 100 ether);

        // Should revert for ERC7540 token
        vm.expectRevert(IConfigurationFacet.AssetIsHeldToken.selector);
        facet.recoverAssets(address(erc7540Token), address(0x999), 200 ether);

        vm.stopPrank();
    }

    function test_recoverAssets_ShouldSucceedForNonHeldToken() public {
        // Create a held token and a non-held token
        MockERC20 heldToken = new MockERC20("Held Token", "HELD");
        MockERC20 normalToken = new MockERC20("Normal Token", "NORM");

        bytes32 heldId = keccak256("HELD_FACET");

        // Register held token
        MoreVaultsStorageHelper.addVaultExternalAsset(address(facet), uint8(MoreVaultsLib.TokenType.HeldToken), heldId);
        address[] memory tokensToAdd = new address[](1);
        tokensToAdd[0] = address(heldToken);
        MoreVaultsStorageHelper.setTokensHeld(address(facet), heldId, tokensToAdd);

        // Mint both tokens
        heldToken.mint(address(facet), 1000 ether);
        normalToken.mint(address(facet), 2000 ether);

        vm.startPrank(guardian);

        // Should revert for held token
        vm.expectRevert(IConfigurationFacet.AssetIsHeldToken.selector);
        facet.recoverAssets(address(heldToken), address(0x999), 100 ether);

        // Should succeed for normal token
        facet.recoverAssets(address(normalToken), address(0x999), 500 ether);

        vm.stopPrank();

        // Verify normal token was recovered
        assertEq(normalToken.balanceOf(address(0x999)), 500 ether, "Normal token should be recovered");
        assertEq(normalToken.balanceOf(address(facet)), 1500 ether, "Facet should have remaining normal tokens");

        // Verify held token was NOT recovered
        assertEq(heldToken.balanceOf(address(facet)), 1000 ether, "Held token should not be recovered");
    }
}

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
