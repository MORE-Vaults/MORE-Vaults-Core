// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {BaseFacetInitializer} from "../../../src/facets/BaseFacetInitializer.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";

contract VaultFacetTest is Test {
    using Math for uint256;

    // Test addresses
    address public facet;
    address public owner = address(9999);
    address public curator = address(7);
    address public guardian = address(8);
    address public feeRecipient = address(9);
    address public registry = address(1000);
    address public asset;
    address public user = address(1);
    address public factory = address(1001);

    // Test data
    string constant VAULT_NAME = "Test Vault";
    string constant VAULT_SYMBOL = "TV";
    uint96 constant FEE_BASIS_POINT = 10000;
    uint96 constant FEE = 1000; // 10%
    uint256 constant TIME_LOCK_PERIOD = 1 days;
    uint256 constant DEPOSIT_CAPACITY = 1000000 ether;
    address public oracleRegistry = address(1001);
    address public oracle = address(1002);

    address public protocolFeeRecipient = address(1003);
    uint96 public protocolFee = 1000; // 10%
    uint8 public decimalsOffset = 2;

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        // Deploy facet
        VaultFacet vaultFacet = new VaultFacet();
        facet = address(vaultFacet);

        // Deploy mock asset
        MockERC20 mockAsset = new MockERC20("Test Asset", "TA");
        asset = address(mockAsset);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setOwner(facet, owner);
        MoreVaultsStorageHelper.setFactory(facet, factory);

        // Initialize vault
        bytes memory initData = abi.encode(
            VAULT_NAME,
            VAULT_SYMBOL,
            asset,
            feeRecipient,
            FEE,
            DEPOSIT_CAPACITY
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleRegistry)
        );

        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset
            ),
            abi.encode(address(2000), uint96(1000))
        );

        VaultFacet(facet).initialize(initData);

        // // Setup initial state
        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setCurator(facet, curator);
        MoreVaultsStorageHelper.setGuardian(facet, guardian);
        MoreVaultsStorageHelper.setDepositWhitelist(
            facet,
            user,
            10_000_000 ether
        );
        MoreVaultsStorageHelper.setIsHub(facet, true);

        // Mint some assets to user for testing
        MockERC20(asset).mint(user, 1000 ether);
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);
    }

    function test_initialize_ShouldSetInitialValues() public view {
        assertEq(
            IERC20Metadata(facet).name(),
            VAULT_NAME,
            "Should set correct name"
        );
        assertEq(
            IERC20Metadata(facet).symbol(),
            VAULT_SYMBOL,
            "Should set correct symbol"
        );
        assertEq(
            IERC20Metadata(facet).decimals(),
            18 + decimalsOffset,
            "Should set correct decimals"
        );
        assertEq(
            MoreVaultsStorageHelper.getFeeRecipient(facet),
            feeRecipient,
            "Should set correct fee recipient"
        );
        assertEq(
            MoreVaultsStorageHelper.getFee(facet),
            FEE,
            "Should set correct fee"
        );
        assertEq(
            MoreVaultsStorageHelper.getDepositCapacity(facet),
            DEPOSIT_CAPACITY,
            "Should set correct deposit capacity"
        );
        assertEq(
            MoreVaultsStorageHelper.isAssetAvailable(facet, asset),
            true,
            "Should set asset available"
        );

        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(
                facet,
                type(IVaultFacet).interfaceId
            ),
            "Should set supported interface"
        );
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(
                facet,
                type(IERC4626).interfaceId
            ),
            "Should set supported interface"
        );
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(
                facet,
                type(IERC20).interfaceId
            ),
            "Should set supported interface"
        );
        assertTrue(
            MoreVaultsStorageHelper.getIsHub(facet),
            "Should set as hub"
        );
    }

    function test_initialize_ShouldRevertWithInvalidParameters() public {
        VaultFacet newFacet = new VaultFacet();
        bytes memory initData = abi.encode(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(0), // Invalid asset
            registry,
            curator,
            guardian,
            feeRecipient,
            FEE,
            TIME_LOCK_PERIOD
        );
        vm.expectRevert(BaseFacetInitializer.InvalidParameters.selector);
        VaultFacet(address(newFacet)).initialize(initData);
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            VaultFacet(facet).facetName(),
            "VaultFacet",
            "Should return correct facet name"
        );
    }

    function test_deposit_ShouldMintShares() public {
        uint256 depositAmount = 100 ether;

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);

        assertEq(
            IERC20(facet).balanceOf(user),
            shares,
            "Should mint correct amount of shares"
        );
        assertEq(
            IERC20(asset).balanceOf(facet),
            depositAmount,
            "Should receive correct amount of assets"
        );
    }

    function test_deposit_ShouldRevertWhenCalledInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).deposit(100 ether, user);
    }

    function test_deposit_ShouldMintSharesWithMultipleAssets() public {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);
        for (uint256 i = 0; i < tokens.length; i++) {
            MoreVaultsStorageHelper.setDepositableAssets(
                facet,
                tokens[i],
                true
            );
        }

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset2
            ),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                asset2
            ),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        vm.prank(user);
        VaultFacet(facet).deposit(tokens, amounts, user);

        // apply generic slippage 1% for conversion of non underlying asset
        uint256 expectedShares = depositAmount + depositAmount2;
        assertEq(
            IERC20(facet).balanceOf(user),
            expectedShares * 10 ** decimalsOffset,
            "Should mint correct amount of shares"
        );
        assertEq(
            IERC20(asset).balanceOf(facet),
            depositAmount,
            "Should receive correct amount of assets1"
        );
        assertEq(
            IERC20(asset2).balanceOf(facet),
            depositAmount2,
            "Should receive correct amount of assets2"
        );
    }

    function test_deposit_ShouldRevertWhenDepositMultipleAssetsInMulticall()
        public
    {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;

        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).deposit(tokens, amounts, user);
    }

    function test_deposit_ShouldMintSharesWhenDepositingNative() public {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);
        for (uint256 i = 0; i < tokens.length; i++) {
            MoreVaultsStorageHelper.setDepositableAssets(
                facet,
                tokens[i],
                true
            );
        }

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset2
            ),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                asset2
            ),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        vm.prank(user);
        uint256 depositAmountInNative = 100 ether;
        vm.deal(user, depositAmountInNative);
        MoreVaultsStorageHelper.setWrappedNative(facet, asset);
        VaultFacet(facet).deposit{value: depositAmountInNative}(
            tokens,
            amounts,
            user
        );

        // apply generic slippage 1% for conversion of non underlying asset
        uint256 expectedShares = depositAmount +
            depositAmount2 +
            depositAmountInNative;
        assertEq(
            IERC20(facet).balanceOf(user),
            expectedShares * 10 ** decimalsOffset,
            "Should mint correct amount of shares"
        );
        assertEq(
            IERC20(asset).balanceOf(facet),
            depositAmount,
            "Should receive correct amount of assets1"
        );
        assertEq(
            IERC20(asset2).balanceOf(facet),
            depositAmount2,
            "Should receive correct amount of assets2"
        );

        assertEq(
            address(facet).balance,
            depositAmountInNative,
            "Should receive correct amount of native"
        );
    }

    function test_mint_ShouldMintShares() public {
        uint256 mintAmount = 100 ether;

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        vm.prank(user);
        uint256 assets = VaultFacet(facet).mint(mintAmount, user);

        assertEq(
            IERC20(facet).balanceOf(user),
            mintAmount,
            "Should mint correct amount of shares"
        );
        assertEq(
            IERC20(asset).balanceOf(facet),
            assets,
            "Should receive correct amount of assets"
        );
    }

    function test_mint_ShouldRevertinMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).mint(100 ether, user);
    }

    function test_mint_ShouldRevertWhenExceededDepositCapacity() public {
        uint256 mintAmount = 1000001 * 10 ** IERC20Metadata(facet).decimals();

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user,
                1000001 * 10 ** IERC20Metadata(asset).decimals(),
                1000000 * 10 ** IERC20Metadata(asset).decimals()
            )
        );
        VaultFacet(facet).mint(mintAmount, user);
    }

    function test_withdraw_ShouldBurnShares() public {
        vm.prank(curator);
        VaultFacet(facet).setWithdrawalTimelock(110);
        assertEq(
            VaultFacet(facet).getWithdrawalTimelock(),
            110,
            "Should set correct timelock duration"
        );
        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // First deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);
        // Then withdraw
        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );

        uint256 withdrawAmount = 50 ether;
        uint256 expectedShares = IVaultFacet(facet).convertToShares(
            withdrawAmount
        );
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount);
        (uint256 sharesRequest, uint256 timelockEndsAt) = VaultFacet(facet)
            .getWithdrawalRequest(user);
        assertEq(
            sharesRequest,
            expectedShares,
            "Should request correct amount of shares"
        );
        assertEq(
            timelockEndsAt,
            block.timestamp + 110,
            "Should set correct timelock end time"
        );
        uint256 currentTimestamp = block.timestamp;
        vm.warp(currentTimestamp + 200);
        vm.prank(user);
        VaultFacet(facet).withdraw(withdrawAmount, user, user);

        assertEq(
            IERC20(asset).balanceOf(user),
            950 * 10 ** IERC20Metadata(asset).decimals(),
            "Should return correct amount of assets"
        );
        assertEq(
            IERC20(facet).balanceOf(user),
            50 * 10 ** IERC20Metadata(facet).decimals(),
            "Should burn correct amount of shares"
        );
    }

    function test_withdraw_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).withdraw(100 ether, user, user);
    }

    function test_requestWithdraw_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).requestWithdraw(100 ether);
    }

    function test_redeem_ShouldBurnShares() public {
        vm.prank(curator);
        VaultFacet(facet).setWithdrawalTimelock(110);
        assertEq(
            VaultFacet(facet).getWithdrawalTimelock(),
            110,
            "Should set correct timelock duration"
        );
        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );

        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // First deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        // Then withdraw
        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );

        uint256 balanceBefore = IERC20(asset).balanceOf(user);
        vm.prank(user);
        VaultFacet(facet).requestRedeem(shares);
        (uint256 sharesRequest, uint256 timelockEndsAt) = VaultFacet(facet)
            .getWithdrawalRequest(user);
        assertEq(
            sharesRequest,
            shares,
            "Should request correct amount of shares"
        );
        assertEq(
            timelockEndsAt,
            block.timestamp + 110,
            "Should set correct timelock end time"
        );
        uint256 currentTimestamp = block.timestamp;
        vm.warp(currentTimestamp + 200);
        vm.prank(user);
        uint256 assets = VaultFacet(facet).redeem(shares, user, user);

        assertEq(
            IERC20(asset).balanceOf(user),
            balanceBefore + assets,
            "Should return correct amount of assets"
        );
        assertEq(
            IERC20(facet).balanceOf(user),
            shares - shares,
            "Should burn correct amount of shares"
        );
    }

    function test_redeem_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).redeem(100 ether, user, user);
    }

    function test_requestRedeem_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).requestRedeem(100 ether);
    }

    function test_pause_ShouldRevertWhenNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        VaultFacet(facet).pause();
    }

    function test_pause_ShouldPauseVault() public {
        vm.prank(owner);
        VaultFacet(facet).pause();
        assertTrue(VaultFacet(facet).paused(), "Should be paused");
    }

    function test_unpause_ShouldUnpauseVault() public {
        // First pause
        vm.prank(owner);
        VaultFacet(facet).pause();

        address[] memory restrictedFacets = new address[](1);
        restrictedFacets[0] = address(101);
        vm.mockCall(
            factory,
            abi.encodeWithSignature("getRestrictedFacets()"),
            abi.encode(restrictedFacets)
        );

        vm.mockCall(
            factory,
            abi.encodeWithSignature("isVaultLinked(address,address)"),
            abi.encode(false)
        );
        // Then unpause
        vm.prank(owner);
        VaultFacet(facet).unpause();
        assertFalse(VaultFacet(facet).paused(), "Should be unpaused");
    }

    function test_unpause_ShouldRevertIfUsingRestrictedFacet() public {
        // First pause
        vm.prank(owner);
        VaultFacet(facet).pause();

        address[] memory restrictedFacets = new address[](1);
        restrictedFacets[0] = address(101);
        vm.mockCall(
            factory,
            abi.encodeWithSignature("getRestrictedFacets()"),
            abi.encode(restrictedFacets)
        );

        vm.mockCall(
            factory,
            abi.encodeWithSignature("isVaultLinked(address,address)"),
            abi.encode(true)
        );
        // Then unpause
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultFacet.VaultIsUsingRestrictedFacet.selector,
                address(101)
            )
        );
        VaultFacet(facet).unpause();
    }

    function test_deposit_ShouldRevertWhenPaused() public {
        // Pause vault
        vm.prank(owner);
        VaultFacet(facet).pause();

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        VaultFacet(facet).deposit(100 ether, user);
    }

    function test_deposit_ShouldRevertWhenExceededDepositCapacity() public {
        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        deal(asset, user, 1000001 ether);
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user,
                1000001 ether,
                1000000 ether
            )
        );
        VaultFacet(facet).deposit(1000001 ether, user);
    }

    function test_deposit_ShouldRevertWhenExceededDepositCapacityMultipleAssets()
        public
    {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 500000 ether;
        uint256 depositAmount2 = 500001 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);
        for (uint256 i = 0; i < tokens.length; i++) {
            MoreVaultsStorageHelper.setDepositableAssets(
                facet,
                tokens[i],
                true
            );
        }

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset2
            ),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                asset2
            ),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        deal(asset, user, 1000001 ether);

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user,
                1000001 ether,
                1000000 ether
            )
        );
        VaultFacet(facet).deposit(tokens, amounts, user);
    }

    function test_deposit_ShouldRevertWhenPausedWithMultipleAssets() public {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);

        // Pause vault
        vm.prank(owner);
        VaultFacet(facet).pause();

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        VaultFacet(facet).deposit(tokens, amounts, user);
    }

    function test_deposit_ShouldRevertWhenDepositWithMultipleAssetsAndArrayLengthsDoesntMatch()
        public
    {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);

        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // Try to deposit
        vm.prank(user);
        uint256[] memory corruptedAmounts = new uint256[](1);
        corruptedAmounts[0] = depositAmount;
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultFacet.ArraysLengthsDontMatch.selector,
                2,
                1
            )
        );
        VaultFacet(facet).deposit(tokens, corruptedAmounts, user);
    }

    function test_deposit_ShouldRevertWhenDepositWithMultipleAssetsAndAssetIsNotDepositable()
        public
    {
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);
        MoreVaultsStorageHelper.setDepositableAssets(facet, asset2, false);

        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultFacet.UnsupportedAsset.selector,
                asset2
            )
        );
        VaultFacet(facet).deposit(tokens, amounts, user);
    }

    function test_accrueInterest_ShouldDistributeFeesWithProtocolFee() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(protocolFeeRecipient, protocolFee)
        );
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 * 10 ** 8, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(protocolFeeRecipient, protocolFee)
        );

        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 * 10 ** 8, block.timestamp, block.timestamp, 0) // 10% price increase
        );

        // Calculate expected fees
        uint256 totalInterest = 10 ether; // 10% of 100 ether
        uint256 totalFee = (totalInterest * FEE) / FEE_BASIS_POINT; // 10% of interest
        uint256 protocolFeeAmount = (totalFee * protocolFee) / FEE_BASIS_POINT; // 10% of fee
        uint256 vaultFeeAmount = totalFee - protocolFeeAmount;

        MockERC20(asset).mint(facet, totalInterest);

        vm.prank(user);
        uint256 newShares = VaultFacet(facet).deposit(1, user);

        // Check fee distribution
        assertApproxEqAbs(
            IERC20(facet).balanceOf(protocolFeeRecipient),
            VaultFacet(facet).convertToShares(protocolFeeAmount),
            10,
            "Should distribute correct protocol fee"
        );
        assertApproxEqAbs(
            IERC20(facet).balanceOf(feeRecipient),
            VaultFacet(facet).convertToShares(vaultFeeAmount),
            10,
            "Should distribute correct vault fee"
        );
        assertApproxEqAbs(
            IERC20(facet).totalSupply(),
            shares + newShares + VaultFacet(facet).convertToShares(totalFee),
            10,
            "Should increase total supply by fee amount"
        );
    }

    function test_accrueInterest_ShouldDistributeFeesWithoutProtocolFee()
        public
    {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0) // No protocol fee
        );
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0) // No protocol fee
        );

        // Calculate expected fees
        uint256 totalInterest = 10 ether; // 10% of 100 ether
        uint256 totalFee = (totalInterest * FEE) / FEE_BASIS_POINT; // 10% of interest
        MockERC20(asset).mint(facet, totalInterest);

        // Trigger interest accrual
        vm.prank(user);
        uint256 newShares = VaultFacet(facet).deposit(1, user);

        // Check fee distribution
        assertApproxEqAbs(
            IERC20(facet).balanceOf(feeRecipient),
            VaultFacet(facet).convertToShares(totalFee),
            10,
            "Should distribute all fees to vault fee recipient"
        );
        assertApproxEqAbs(
            IERC20(facet).totalSupply(),
            depositAmount *
                10 ** decimalsOffset +
                newShares +
                VaultFacet(facet).convertToShares(totalFee),
            10,
            "Should increase total supply by fee amount"
        );
    }

    function test_accrueInterest_ShouldNotDistributeFeesWhenNoFee() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Set fee to 0
        MoreVaultsStorageHelper.setFee(facet, 0);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // Trigger interest accrual
        vm.prank(user);
        VaultFacet(facet).deposit(0, user);

        // Check that no fees were distributed
        assertEq(
            IERC20(facet).balanceOf(feeRecipient),
            0,
            "Should not distribute any fees"
        );
        assertEq(
            IERC20(facet).totalSupply(),
            depositAmount * 10 ** decimalsOffset,
            "Should not mint extra shares for fee"
        );
    }

    function test_accrueInterest_ShouldNotDistributeFeesWhenInterestIsZero()
        public
    {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls with no price change
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0) // No price change
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        // Trigger interest accrual
        vm.prank(user);
        VaultFacet(facet).deposit(0, user);

        // Check that no fees were distributed
        assertEq(
            IERC20(facet).balanceOf(feeRecipient),
            0,
            "Should not distribute any fees when no price change"
        );
        assertEq(
            IERC20(facet).totalSupply(),
            depositAmount * 10 ** decimalsOffset,
            "Should not mint extra shares for fee"
        );
    }

    function test_accrueInterest_ShouldRevertIfTotalAssetsIsZero() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls with no price change
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0) // No price change
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );

        MockERC20(asset).burn(facet, depositAmount);

        // Trigger interest accrual
        vm.prank(user);
        vm.expectRevert(IVaultFacet.VaultDebtIsGreaterThanAssets.selector);
        VaultFacet(facet).deposit(0, user);
    }

    function test_setFee_ShouldUpdateFee() public {
        vm.startPrank(owner);

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.protocolFeeInfo.selector
            ),
            abi.encode(address(0), 0)
        );

        // Set new fee
        uint96 newFee = 200; // 2%
        IVaultFacet(facet).setFee(newFee);

        // Verify through getter
        assertEq(
            MoreVaultsStorageHelper.getFee(address(facet)),
            newFee,
            "Fee should be updated"
        );

        vm.stopPrank();
    }

    function test_setFee_ShouldRevertWhenUnauthorized() public {
        MoreVaultsStorageHelper.setFee(address(facet), 100); // 1%

        address unauthorized = address(113);
        vm.startPrank(unauthorized);

        // Attempt to set new fee
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        IVaultFacet(facet).setFee(200);

        // Verify fee remains unchanged
        assertEq(
            MoreVaultsStorageHelper.getFee(address(facet)),
            100,
            "Fee should not be changed"
        );

        vm.stopPrank();
    }

    function test_setFee_ShouldRevertWhenInvalidFee() public {
        MoreVaultsStorageHelper.setFee(address(facet), 100); // 1%

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.protocolFeeInfo.selector
            ),
            abi.encode(address(0), 0)
        );

        vm.startPrank(owner);

        // Attempt to set fee above 50%
        vm.expectRevert(MoreVaultsLib.InvalidFee.selector);
        IVaultFacet(facet).setFee(5001);

        vm.stopPrank();
    }

    function test_deposit_ShouldRevertWhenDepositWhitelistIsExceeded() public {
        address[] memory depositors = new address[](1);
        address user2 = address(114);
        depositors[0] = user2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user2, 10 ether);
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user2,
                100 ether,
                10 ether
            )
        );
        VaultFacet(facet).deposit(100 ether, user2);
        vm.stopPrank();
    }

    function test_mint_ShouldRevertWhenDepositWhitelistIsExceeded() public {
        address[] memory depositors = new address[](1);
        address user2 = address(114);
        depositors[0] = user2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user2, 10 ether);
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        // Mock oracle calls for price increase
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSignature("getSourceOfAsset(address)"),
            abi.encode(oracle)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user2,
                100 ether,
                10 ether
            )
        );
        VaultFacet(facet).mint(10_000 ether, user2);
        vm.stopPrank();
    }

    function test_multiAssetDeposit_ShouldRevertWhenDeposit_WhitelistIsExceeded()
        public
    {
        address[] memory depositors = new address[](1);
        address user2 = address(114);
        depositors[0] = user2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user2, 10 ether);
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(user2, depositAmount2);
        vm.prank(user);
        IERC20(asset2).approve(facet, type(uint256).max);

        address[] memory tokens = new address[](2);
        tokens[0] = asset;
        tokens[1] = asset2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = depositAmount;
        amounts[1] = depositAmount2;
        MoreVaultsStorageHelper.setAvailableAssets(facet, tokens);
        for (uint256 i = 0; i < tokens.length; i++) {
            MoreVaultsStorageHelper.setDepositableAssets(
                facet,
                tokens[i],
                true
            );
        }

        // Mock oracle call
        vm.mockCall(
            registry,
            abi.encodeWithSignature("oracle()"),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("getDenominationAsset()"),
            abi.encode(asset)
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                asset2
            ),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(
                IOracleRegistry.getAssetPrice.selector,
                asset2
            ),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("decimals()"),
            abi.encode(8)
        );
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0)
        );
        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user2,
                300 ether,
                10 ether
            )
        );
        VaultFacet(facet).deposit(tokens, amounts, user2);
        vm.stopPrank();
    }
}
