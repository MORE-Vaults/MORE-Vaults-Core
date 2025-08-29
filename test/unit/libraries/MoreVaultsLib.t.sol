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
        MoreVaultsStorageHelper.setAvailableAssets(
            address(this),
            availableAssets
        );
        MoreVaultsStorageHelper.setWrappedNative(address(this), wrappedNative);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(this), registry);
        MoreVaultsStorageHelper.setVaultAsset(address(this), token1, 18);
    }

    function test_validateAsset_ShouldNotRevertWhenAssetIsAvailable()
        public
        view
    {
        MoreVaultsLib.validateAssetAvailable(token1);
    }

    function test_validateAsset_ShouldRevertWhenAssetIsNotAvailable() public {
        address invalidAsset = address(9);
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.UnsupportedAsset.selector,
                invalidAsset
            )
        );
        MoreVaultsLib.validateAssetAvailable(invalidAsset);
    }

    function test_removeTokenIfnecessary_ShouldRemoveTokenWhenBalanceIsLow()
        public
    {
        // Mock IERC20.balanceOf to return low balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(5e3) // Less than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[
            keccak256("test")
        ];

        // Add token to set
        tokensHeld.add(token1);

        // Call function
        MoreVaultsLib.removeTokenIfnecessary(tokensHeld, token1);

        // Verify token was removed
        assertFalse(tokensHeld.contains(token1), "Token should be removed");
    }

    function test_removeTokenIfnecessary_ShouldNotRemoveTokenWhenBalanceIsHigh()
        public
    {
        // Mock IERC20.balanceOf to return high balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(20e3) // More than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[
            keccak256("test")
        ];

        // Add token to set
        tokensHeld.add(token1);

        // Call function
        MoreVaultsLib.removeTokenIfnecessary(tokensHeld, token1);

        // Verify token was not removed
        assertTrue(tokensHeld.contains(token1), "Token should not be removed");
    }

    function test_removeTokenIfnecessary_ShouldNotRemoveTokenWhenBalanceIsLowButStakedIsHigh()
        public
    {
        // Mock IERC20.balanceOf to return high balance
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)),
            abi.encode(1e3) // More than 10e3
        );

        // Get storage pointer for tokensHeld
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        EnumerableSet.AddressSet storage tokensHeld = ds.tokensHeld[
            keccak256("test")
        ];
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
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.getDenominationAsset.selector
            ),
            abi.encode(denominationAsset)
        );

        // Mock denomination asset decimals
        vm.mockCall(
            denominationAsset,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(18)
        );

        // Mock oracle source for both wrappedNative and underlying token
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                wrappedNative
            ),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                token1
            ),
            abi.encode(aggregator2, uint96(1000))
        );

        // Mock aggregators with real ETH price
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                wrappedNative
            ),
            abi.encode(ETH_PRICE)
        );
        vm.mockCall(
            aggregator1,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                token1
            ),
            abi.encode(USD_PRICE)
        );
        vm.mockCall(
            aggregator2,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );

        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(8)
        );

        vm.mockCall(
            wrappedNative,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(18)
        );

        uint256 amount = 1e18; // 1 ETH
        uint256 result = MoreVaultsLib.convertToUnderlying(
            address(0),
            amount,
            Math.Rounding.Floor
        );
        uint256 expectedResult = (amount.mulDiv(ETH_PRICE, 1e18));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 decimals
            "Should convert ETH to underlying tokens with correct price"
        );
    }

    function test_convertToUnderlying_ShouldConvertNonNativeToken() public {
        // Mock registry and oracle
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.getDenominationAsset.selector
            ),
            abi.encode(denominationAsset)
        );

        // Mock denomination asset decimals
        vm.mockCall(
            denominationAsset,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(18)
        );

        // Mock oracle sources
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                token2
            ),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                token1
            ),
            abi.encode(aggregator2, uint96(1000))
        );

        // Mock aggregators with ~real SOL price
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                token1
            ),
            abi.encode(USD_PRICE)
        );
        vm.mockCall(
            aggregator1,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                token2
            ),
            abi.encode(SOL_PRICE)
        );
        vm.mockCall(
            aggregator2,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(8)
        );

        vm.mockCall(
            token2,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(18)
        );

        uint256 amount = 1e18; // 1 SOL
        uint256 result = MoreVaultsLib.convertToUnderlying(
            token2,
            amount,
            Math.Rounding.Floor
        );
        uint256 expectedResult = (amount.mulDiv(SOL_PRICE, 1e18));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 decimals
            "Should convert SOL to underlying tokens with correct price"
        );
    }

    function test_convertToUnderlying_ShouldConvertDirectlyWhenUnderlyingEqualsDenomination()
        public
    {
        // Mock registry and oracle
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.getDenominationAsset.selector
            ),
            abi.encode(token1) // Set denomination asset to token1 (our underlying token)
        );

        // Mock denomination asset decimals
        vm.mockCall(
            token1,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(8)
        );

        // Mock oracle sources
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                token2
            ),
            abi.encode(aggregator1, uint96(1000))
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                token1
            ),
            abi.encode(aggregator2, uint96(1000))
        );

        vm.mockCall(
            aggregator1,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );
        vm.mockCall(
            aggregator2,
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                token2
            ),
            abi.encode(SOL_PRICE)
        );

        // Mock token decimals
        vm.mockCall(
            token2,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(8)
        );

        uint256 amount = 1e8; // 1 SOL with 8 decimals
        uint256 result = MoreVaultsLib.convertToUnderlying(
            token2,
            amount,
            Math.Rounding.Floor
        );

        uint256 expectedResult = (amount.mulDiv(SOL_PRICE, 1e8));
        assertEq(
            result,
            expectedResult, // Convert from 8 decimals to 18 and apply price
            "Should convert token with price when underlying equals denomination asset"
        );
    }

    function test_convertToUnderlying_ShouldConvertUnderlyingToUnderlyingAs1To1()
        public
        view
    {
        uint256 amount = 1e8; // 1 SOL with 8 decimals
        uint256 result = MoreVaultsLib.convertToUnderlying(
            token1,
            amount,
            Math.Rounding.Floor
        );

        assertEq(
            result,
            amount,
            "Should convert underlying to underlying as 1 to 1"
        );
    }

    function test_convertToUnderlying_WithZeroAmount() public {
        // Mock registry and oracle
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.getDenominationAsset.selector
            ),
            abi.encode(denominationAsset)
        );

        uint256 result = MoreVaultsLib.convertToUnderlying(
            token1,
            0,
            Math.Rounding.Floor
        );
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

    function test_validateAddressWhitelisted_ShouldNotRevertWhenAddressIsWhitelisted()
        public
    {
        vm.mockCall(
            registry,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(this)
            ),
            abi.encode(true)
        );
        MoreVaultsLib.validateAddressWhitelisted(address(this));
    }
}
