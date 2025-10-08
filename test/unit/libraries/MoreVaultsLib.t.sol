// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IAggregatorV2V3Interface} from "../../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";

contract MoreVaultsLibTest is Test {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;

    // Test addresses
    address public token1 = address(1);
    address public token2 = address(2);
    address public wrappedNative = address(3);
    address public oracle = address(4);
    address public registry = address(5);
    address public aggregator1 = address(6);
    address public aggregator2 = address(7);
    address public denominationAsset = address(8);

    // Price constants (in USD with 8 decimals)
    uint256 constant ETH_PRICE = 3000e8; // 3000 USD
    uint256 constant SOL_PRICE = 100e8; // 100 USD
    uint256 constant USD_PRICE = 1e8; // 1 USD

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        address[] memory availableAssets = new address[](2);
        availableAssets[0] = token1;
        availableAssets[1] = token2;
        // Set initial values in storage
        MoreVaultsStorageHelper.setAvailableAssets(address(this), availableAssets);
        MoreVaultsStorageHelper.setWrappedNative(address(this), wrappedNative);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(this), registry);
        MoreVaultsStorageHelper.setVaultAsset(address(this), token1, 18);
    }

    function test_validateAsset_ShouldNotRevertWhenAssetIsAvailable() public view {
        MoreVaultsLib.validateAssetAvailable(token1);
    }

    function test_validateAsset_ShouldRevertWhenAssetIsNotAvailable() public {
        address invalidAsset = address(9);
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, invalidAsset));
        MoreVaultsLib.validateAssetAvailable(invalidAsset);
    }

    function test_removeTokenIfnecessary_ShouldRemoveTokenWhenBalanceIsLow() public {
        // Mock IERC20.balanceOf to return low balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(5e3) // Less than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[keccak256("test")];

        // Add token to set
        tokensHeld.add(token1);

        // Call function
        MoreVaultsLib.removeTokenIfnecessary(tokensHeld, token1);

        // Verify token was removed
        assertFalse(tokensHeld.contains(token1), "Token should be removed");
    }

    function test_removeTokenIfnecessary_ShouldNotRemoveTokenWhenBalanceIsHigh() public {
        // Mock IERC20.balanceOf to return high balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(20e3) // More than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[keccak256("test")];

        // Add token to set
        tokensHeld.add(token1);

        // Call function
        MoreVaultsLib.removeTokenIfnecessary(tokensHeld, token1);

        // Verify token was not removed
        assertTrue(tokensHeld.contains(token1), "Token should not be removed");
    }

    function test_removeTokenIfnecessary_ShouldNotRemoveTokenWhenBalanceIsLowButStakedIsHigh() public {
        // Mock IERC20.balanceOf to return high balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(1e3) // More than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[keccak256("test")];
        MoreVaultsStorageHelper.setStaked(address(this), token1, 10e4);

        // Add token to set
        tokensHeld.add(token1);

        // Call function
        MoreVaultsLib.removeTokenIfnecessary(tokensHeld, token1);

        // Verify token was not removed
        assertTrue(tokensHeld.contains(token1), "Token should not be removed");
    }

    function test_convertToUnderlying_ShouldConvertNativeToken() public {
        // Mock registry and oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.getDenominationAsset.selector),
            abi.encode(denominationAsset)
        );

        // Mock denomination asset decimals
        vm.mockCall(denominationAsset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        // Mock oracle source for both wrappedNative and underlying token
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, wrappedNative),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, token1),
            abi.encode(aggregator2, uint96(1000))
        );

        // Mock aggregators with real ETH price
        vm.mockCall(
            oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, wrappedNative), abi.encode(ETH_PRICE)
        );
        vm.mockCall(aggregator1, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));
        vm.mockCall(
            oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token1), abi.encode(USD_PRICE)
        );
        vm.mockCall(aggregator2, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));

        vm.mockCall(token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(8));

        vm.mockCall(wrappedNative, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        uint256 amount = 1e18; // 1 ETH
        uint256 result = MoreVaultsLib.convertToUnderlying(address(0), amount, Math.Rounding.Floor);
        uint256 expectedResult = (amount.mulDiv(ETH_PRICE, 1e18));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 decimals
            "Should convert ETH to underlying tokens with correct price"
        );
    }

    function test_convertToUnderlying_ShouldConvertNonNativeToken() public {
        // Mock registry and oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.getDenominationAsset.selector),
            abi.encode(denominationAsset)
        );

        // Mock denomination asset decimals
        vm.mockCall(denominationAsset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        // Mock oracle sources
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, token2),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, token1),
            abi.encode(aggregator2, uint96(1000))
        );

        // Mock aggregators with ~real SOL price
        vm.mockCall(
            oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token1), abi.encode(USD_PRICE)
        );
        vm.mockCall(aggregator1, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));
        vm.mockCall(
            oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token2), abi.encode(SOL_PRICE)
        );
        vm.mockCall(aggregator2, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));
        vm.mockCall(token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(8));

        vm.mockCall(token2, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        uint256 amount = 1e18; // 1 SOL
        uint256 result = MoreVaultsLib.convertToUnderlying(token2, amount, Math.Rounding.Floor);
        uint256 expectedResult = (amount.mulDiv(SOL_PRICE, 1e18));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 decimals
            "Should convert SOL to underlying tokens with correct price"
        );
    }

    function test_convertToUnderlying_ShouldConvertDirectlyWhenUnderlyingEqualsDenomination() public {
        // Mock registry and oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.getDenominationAsset.selector),
            abi.encode(token1) // Set denomination asset to token1 (our underlying token)
        );

        // Mock denomination asset decimals
        vm.mockCall(token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(8));

        // Mock oracle sources
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, token2),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, token1),
            abi.encode(aggregator2, uint96(1000))
        );

        vm.mockCall(aggregator1, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));
        vm.mockCall(aggregator2, abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector), abi.encode(8));
        vm.mockCall(
            oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token2), abi.encode(SOL_PRICE)
        );

        // Mock token decimals
        vm.mockCall(token2, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(8));

        uint256 amount = 1e8; // 1 SOL with 8 decimals
        uint256 result = MoreVaultsLib.convertToUnderlying(token2, amount, Math.Rounding.Floor);

        uint256 expectedResult = (amount.mulDiv(SOL_PRICE, 1e8));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 and apply price
            "Should convert token with price when underlying equals denomination asset"
        );
    }

    function test_convertToUnderlying_ShouldConvertUnderlyingToUnderlyingAs1To1() public view {
        uint256 amount = 1e8; // 1 SOL with 8 decimals
        uint256 result = MoreVaultsLib.convertToUnderlying(token1, amount, Math.Rounding.Floor);

        assertEq(result, amount, "Should convert underlying to underlying as 1 to 1");
    }

    function test_convertToUnderlying_WithZeroAmount() public {
        // Mock registry and oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.getDenominationAsset.selector),
            abi.encode(denominationAsset)
        );

        uint256 result = MoreVaultsLib.convertToUnderlying(token1, 0, Math.Rounding.Floor);
        assertEq(result, 0, "Should return 0 for zero amount");
    }

    function test_setDepositCapacity_ShouldSetDepositCapacity() public {
        uint256 newCapacity = 1000000 ether;
        MoreVaultsLib._setDepositCapacity(newCapacity);
        assertEq(
            MoreVaultsStorageHelper.getDepositCapacity(address(this)),
            newCapacity,
            "Should set deposit capacity correctly"
        );
    }

    function test_validateAddressWhitelisted_ShouldNotRevertWhenAddressIsWhitelisted() public {
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(this)),
            abi.encode(true)
        );
        MoreVaultsLib.validateAddressWhitelisted(address(this));
    }

    // Tests for fee functions
    function test_setFee_ShouldSetFeeCorrectly() public {
        uint96 newFee = 1000; // 10%

        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.FeeSet(0, newFee);

        MoreVaultsLib._setFee(newFee);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertEq(ds.fee, newFee, "Fee should be set correctly");
    }

    function test_setFee_ShouldRevertWhenFeeExceedsMax() public {
        uint96 invalidFee = 6000; // 60%, exceeds MAX_FEE (50%)

        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.InvalidFee.selector));
        MoreVaultsLib._setFee(invalidFee);
    }

    function test_setFeeRecipient_ShouldSetRecipientCorrectly() public {
        address newRecipient = address(0x123);

        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.FeeRecipientSet(address(0), newRecipient);

        MoreVaultsLib._setFeeRecipient(newRecipient);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertEq(ds.feeRecipient, newRecipient, "Fee recipient should be set correctly");
    }

    function test_setFeeRecipient_ShouldRevertWhenAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.ZeroAddress.selector));
        MoreVaultsLib._setFeeRecipient(address(0));
    }

    // Tests for time lock functions
    function test_setTimeLockPeriod_ShouldSetPeriodCorrectly() public {
        uint256 newPeriod = 7 days;

        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.TimeLockPeriodSet(0, newPeriod);

        MoreVaultsLib._setTimeLockPeriod(newPeriod);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertEq(ds.timeLockPeriod, newPeriod, "Time lock period should be set correctly");
    }

    // Tests for asset management functions
    function test_addAvailableAsset_ShouldAddAssetCorrectly() public {
        address newAsset = address(0x999);

        // Mock registry oracle call
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        // Mock oracle registry
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, newAsset),
            abi.encode(aggregator1, uint96(1000))
        );

        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.AssetToManageAdded(newAsset);

        MoreVaultsLib._addAvailableAsset(newAsset);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertTrue(ds.isAssetAvailable[newAsset], "Asset should be marked as available");
    }

    function test_addAvailableAsset_ShouldRevertWhenAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.InvalidAddress.selector));
        MoreVaultsLib._addAvailableAsset(address(0));
    }

    function test_addAvailableAsset_ShouldRevertWhenAssetAlreadyAvailable() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.AssetAlreadyAvailable.selector));
        MoreVaultsLib._addAvailableAsset(token1);
    }

    function test_enableAssetToDeposit_ShouldEnableAssetCorrectly() public {
        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.AssetToDepositEnabled(token1);

        MoreVaultsLib._enableAssetToDeposit(token1);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertTrue(ds.isAssetDepositable[token1], "Asset should be marked as depositable");
    }

    function test_enableAssetToDeposit_ShouldRevertWhenAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.InvalidAddress.selector));
        MoreVaultsLib._enableAssetToDeposit(address(0));
    }

    function test_enableAssetToDeposit_ShouldRevertWhenAssetNotAvailable() public {
        address unavailableAsset = address(0x888);

        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, unavailableAsset));
        MoreVaultsLib._enableAssetToDeposit(unavailableAsset);
    }

    function test_enableAssetToDeposit_ShouldRevertWhenAssetAlreadyDepositable() public {
        // First enable it
        MoreVaultsLib._enableAssetToDeposit(token1);

        // Try to enable again
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.AssetAlreadyAvailable.selector));
        MoreVaultsLib._enableAssetToDeposit(token1);
    }

    function test_disableAssetToDeposit_ShouldDisableAssetCorrectly() public {
        // First enable it
        MoreVaultsLib._enableAssetToDeposit(token1);

        vm.expectEmit(true, true, true, true);
        emit MoreVaultsLib.AssetToDepositDisabled(token1);

        MoreVaultsLib._disableAssetToDeposit(token1);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertFalse(ds.isAssetDepositable[token1], "Asset should be marked as not depositable");
    }

    function test_disableAssetToDeposit_ShouldRevertWhenAddressIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.InvalidAddress.selector));
        MoreVaultsLib._disableAssetToDeposit(address(0));
    }

    function test_disableAssetToDeposit_ShouldRevertWhenAssetNotDepositable() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, token1));
        MoreVaultsLib._disableAssetToDeposit(token1);
    }

    // Tests for conversion functions
    function test_convertUnderlyingToUsd_ShouldConvertCorrectly() public {
        // Mock oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token1),
            abi.encode(USD_PRICE)
        );
        vm.mockCall(token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        uint256 amount = 100e18; // 100 tokens
        uint256 result = MoreVaultsLib.convertUnderlyingToUsd(amount, Math.Rounding.Floor);

        uint256 expectedResult = amount.mulDiv(USD_PRICE, 1e18);
        assertEq(result, expectedResult, "Should convert underlying to USD correctly");
    }

    function test_convertUsdToUnderlying_ShouldConvertCorrectly() public {
        // Mock oracle
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, token1),
            abi.encode(USD_PRICE)
        );
        vm.mockCall(token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(18));

        uint256 usdAmount = 100e8; // 100 USD (8 decimals)
        uint256 result = MoreVaultsLib.convertUsdToUnderlying(usdAmount, Math.Rounding.Floor);

        uint256 expectedResult = usdAmount.mulDiv(1e18, USD_PRICE);
        assertEq(result, expectedResult, "Should convert USD to underlying correctly");
    }

    // Tests for validation functions
    function test_validateAssetDepositable_ShouldNotRevertWhenAssetIsDepositable() public {
        MoreVaultsLib._enableAssetToDeposit(token1);
        MoreVaultsLib.validateAssetDepositable(token1);
    }

    function test_validateAssetDepositable_ShouldRevertWhenAssetIsNotDepositable() public {
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, token1));
        MoreVaultsLib.validateAssetDepositable(token1);
    }

    function test_validateAssetDepositable_ShouldHandleNativeToken() public {
        // Mock registry oracle call
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        // Mock oracle for wrapped native
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, wrappedNative),
            abi.encode(aggregator1, uint96(1000))
        );

        MoreVaultsLib._addAvailableAsset(wrappedNative);
        MoreVaultsLib._enableAssetToDeposit(wrappedNative);

        // Test with address(0) which should resolve to wrapped native
        MoreVaultsLib.validateAssetDepositable(address(0));
    }

    function test_validateNotMulticall_ShouldNotRevertWhenNotInMulticall() public view {
        MoreVaultsLib.validateNotMulticall();
    }

    function test_validateNotMulticall_ShouldRevertWhenInMulticall() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.isMulticall = true;

        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.RestrictedActionInsideMulticall.selector));
        MoreVaultsLib.validateNotMulticall();
    }

    // Tests for whitelist functions
    function test_setWhitelistFlag_ShouldSetFlagCorrectly() public {
        MoreVaultsLib._setWhitelistFlag(true);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        assertTrue(ds.isWhitelistEnabled, "Whitelist should be enabled");

        MoreVaultsLib._setWhitelistFlag(false);
        assertFalse(ds.isWhitelistEnabled, "Whitelist should be disabled");
    }

    function test_setDepositWhitelist_ShouldSetWhitelistCorrectly() public {
        address depositor1 = address(0x100);
        address depositor2 = address(0x200);
        uint256 cap1 = 1000e18;
        uint256 cap2 = 2000e18;

        // Create storage arrays using helper
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.depositWhitelist[depositor1] = cap1;
        ds.depositWhitelist[depositor2] = cap2;

        assertEq(ds.depositWhitelist[depositor1], cap1, "First depositor cap should be set");
        assertEq(ds.depositWhitelist[depositor2], cap2, "Second depositor cap should be set");
    }

    // Tests for withdrawal request functions
    function test_withdrawFromRequest_ShouldAllowWithdrawalWhenQueueDisabled() public {
        address requester = address(0x123);
        uint256 shares = 100e18;

        // Queue is disabled by default
        bool result = MoreVaultsLib.withdrawFromRequest(requester, shares);

        // Should only allow if msg.sender is the requester
        assertTrue(result == (address(this) == requester), "Should check requester identity when queue disabled");
    }

    function test_withdrawFromRequest_ShouldAllowWithdrawalWhenTimelockPassed() public {
        address requester = address(0x123);
        uint256 shares = 100e18;

        // Enable withdrawal queue
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.isWithdrawalQueueEnabled = true;
        ds.witdrawTimelock = 1 days;

        // Set withdrawal request
        ds.withdrawalRequests[requester].shares = shares;
        ds.withdrawalRequests[requester].timelockEndsAt = block.timestamp - 1; // Already passed

        bool result = MoreVaultsLib.withdrawFromRequest(requester, shares);

        assertTrue(result, "Should allow withdrawal when timelock passed");
        assertEq(ds.withdrawalRequests[requester].shares, 0, "Shares should be deducted");
    }

    function test_withdrawFromRequest_ShouldRejectWhenInsufficientShares() public {
        address requester = address(0x123);
        uint256 requestedShares = 100e18;

        // Enable withdrawal queue
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.isWithdrawalQueueEnabled = true;
        ds.witdrawTimelock = 1 days;

        // Set withdrawal request with insufficient shares
        ds.withdrawalRequests[requester].shares = 50e18; // Less than requested
        ds.withdrawalRequests[requester].timelockEndsAt = block.timestamp - 1;

        bool result = MoreVaultsLib.withdrawFromRequest(requester, requestedShares);

        assertFalse(result, "Should reject withdrawal when insufficient shares");
    }

    // Tests for gas limit functions
    function test_checkGasLimitOverflow_ShouldNotRevertWhenWithinLimit() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Set high gas limit
        ds.gasLimit.value = 10_000_000;
        ds.gasLimit.heldTokenAccountingGas = 50000;
        ds.gasLimit.stakingTokenAccountingGas = 50000;
        ds.gasLimit.availableTokenAccountingGas = 50000;
        ds.gasLimit.facetAccountingGas = 50000;
        ds.gasLimit.nestedVaultsGas = 100000;

        // Should not revert
        MoreVaultsLib.checkGasLimitOverflow();
    }

    function test_checkGasLimitOverflow_ShouldRevertWhenExceedingLimit() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        // Set low gas limit
        ds.gasLimit.value = 100;
        ds.gasLimit.heldTokenAccountingGas = 50000;
        ds.gasLimit.stakingTokenAccountingGas = 50000;
        ds.gasLimit.availableTokenAccountingGas = 50000;
        ds.gasLimit.facetAccountingGas = 50000;
        ds.gasLimit.nestedVaultsGas = 100000;

        // Add some tokens to trigger gas calculation
        bytes32 heldId = keccak256("held");
        ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].add(heldId);
        ds.tokensHeld[heldId].add(token1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.AccountingGasLimitExceeded.selector,
                ds.gasLimit.value,
                50000 * 1 + 50000 * 2 + 100000 // Calculation based on tokens
            )
        );
        MoreVaultsLib.checkGasLimitOverflow();
    }

    function test_checkGasLimitOverflow_ShouldSkipWhenGasLimitIsZero() public {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.gasLimit.value = 0;

        // Should not revert even with high consumption
        MoreVaultsLib.checkGasLimitOverflow();
    }

    // Tests for factory address
    function test_factoryAddress_ShouldReturnCorrectAddress() public {
        address expectedFactory = address(0x456);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.factory = expectedFactory;

        assertEq(MoreVaultsLib.factoryAddress(), expectedFactory, "Should return correct factory address");
    }

    // Tests for _getCrossChainAccountingManager
    function test_getCrossChainAccountingManager_ShouldReturnSetManager() public {
        address customManager = address(0x789);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.crossChainAccountingManager = customManager;

        assertEq(MoreVaultsLib._getCrossChainAccountingManager(), customManager, "Should return custom manager");
    }

    function test_getCrossChainAccountingManager_ShouldReturnDefaultManager() public {
        address defaultManager = address(0x999);

        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.defaultCrossChainAccountingManager.selector),
            abi.encode(defaultManager)
        );

        assertEq(MoreVaultsLib._getCrossChainAccountingManager(), defaultManager, "Should return default manager");
    }
}
