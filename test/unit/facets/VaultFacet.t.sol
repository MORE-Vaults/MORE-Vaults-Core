// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC165} from "../../../src/interfaces/IERC165.sol";
import {IERC173} from "../../../src/interfaces/IERC173.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {IDiamondLoupe} from "../../../src/interfaces/facets/IDiamondLoupe.sol";
import {IMulticallFacet} from "../../../src/interfaces/facets/IMulticallFacet.sol";
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
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";
import {console} from "forge-std/console.sol";

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
        bytes memory initData = abi.encode(VAULT_NAME, VAULT_SYMBOL, asset, feeRecipient, FEE, DEPOSIT_CAPACITY);

        vm.mockCall(
            address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracleRegistry)
        );

        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(2000), uint96(1000))
        );

        VaultFacet(facet).initialize(initData);

        // // Setup initial state
        MoreVaultsStorageHelper.setMoreVaultsRegistry(facet, registry);
        MoreVaultsStorageHelper.setCurator(facet, curator);
        MoreVaultsStorageHelper.setGuardian(facet, guardian);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user, 10_000_000 ether);
        MoreVaultsStorageHelper.setIsHub(facet, true);

        vm.mockCall(
            factory, abi.encodeWithSelector(IVaultsFactory.localEid.selector), abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, uint32(block.chainid), facet),
            abi.encode(false)
        );

        // Mint some assets to user for testing
        MockERC20(asset).mint(user, 1000 ether);
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);
    }

    function test_initialize_ShouldSetInitialValues() public view {
        assertEq(IERC20Metadata(facet).name(), VAULT_NAME, "Should set correct name");
        assertEq(IERC20Metadata(facet).symbol(), VAULT_SYMBOL, "Should set correct symbol");
        assertEq(IERC20Metadata(facet).decimals(), 18 + decimalsOffset, "Should set correct decimals");
        assertEq(MoreVaultsStorageHelper.getFeeRecipient(facet), feeRecipient, "Should set correct fee recipient");
        assertEq(MoreVaultsStorageHelper.getFee(facet), FEE, "Should set correct fee");
        assertEq(
            MoreVaultsStorageHelper.getDepositCapacity(facet), DEPOSIT_CAPACITY, "Should set correct deposit capacity"
        );
        assertEq(MoreVaultsStorageHelper.isAssetAvailable(facet, asset), true, "Should set asset available");

        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(facet, type(IVaultFacet).interfaceId),
            "Should set supported interface"
        );
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(facet, type(IERC4626).interfaceId),
            "Should set supported interface"
        );
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(facet, type(IERC20).interfaceId),
            "Should set supported interface"
        );
        assertTrue(MoreVaultsStorageHelper.getIsHub(facet), "Should set as hub");
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
        assertEq(VaultFacet(facet).facetName(), "VaultFacet", "Should return correct facet name");
    }

    function test_deposit_ShouldMintShares() public {
        uint256 depositAmount = 100 ether;

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);

        assertEq(IERC20(facet).balanceOf(user), shares, "Should mint correct amount of shares");
        assertEq(IERC20(asset).balanceOf(facet), depositAmount, "Should receive correct amount of assets");
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
            MoreVaultsStorageHelper.setDepositableAssets(facet, tokens[i], true);
        }

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset2),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, asset2),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.prank(user);
        VaultFacet(facet).deposit(tokens, amounts, user);

        // apply generic slippage 1% for conversion of non underlying asset
        uint256 expectedShares = depositAmount + depositAmount2;
        assertEq(
            IERC20(facet).balanceOf(user), expectedShares * 10 ** decimalsOffset, "Should mint correct amount of shares"
        );
        assertEq(IERC20(asset).balanceOf(facet), depositAmount, "Should receive correct amount of assets1");
        assertEq(IERC20(asset2).balanceOf(facet), depositAmount2, "Should receive correct amount of assets2");
    }

    function test_deposit_ShouldRevertWhenDepositMultipleAssetsInMulticall() public {
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
            MoreVaultsStorageHelper.setDepositableAssets(facet, tokens[i], true);
        }

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset2),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, asset2),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.prank(user);
        uint256 depositAmountInNative = 100 ether;
        vm.deal(user, depositAmountInNative);
        MoreVaultsStorageHelper.setWrappedNative(facet, asset);
        VaultFacet(facet).deposit{value: depositAmountInNative}(tokens, amounts, user);

        // apply generic slippage 1% for conversion of non underlying asset
        uint256 expectedShares = depositAmount + depositAmount2 + depositAmountInNative;
        assertEq(
            IERC20(facet).balanceOf(user), expectedShares * 10 ** decimalsOffset, "Should mint correct amount of shares"
        );
        assertEq(IERC20(asset).balanceOf(facet), depositAmount, "Should receive correct amount of assets1");
        assertEq(IERC20(asset2).balanceOf(facet), depositAmount2, "Should receive correct amount of assets2");

        assertEq(address(facet).balance, depositAmountInNative, "Should receive correct amount of native");
    }

    function test_mint_ShouldMintShares() public {
        uint256 mintAmount = 100 ether;

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.prank(user);
        uint256 assets = VaultFacet(facet).mint(mintAmount, user);

        assertEq(IERC20(facet).balanceOf(user), mintAmount, "Should mint correct amount of shares");
        assertEq(IERC20(asset).balanceOf(facet), assets, "Should receive correct amount of assets");
    }

    function test_mint_ShouldRevertinMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).mint(100 ether, user);
    }

    function test_depositCapacty_shouldPassIfSetToZero() public {
        MoreVaultsStorageHelper.setDepositCapacity(facet, 0);
        uint256 depositAmount = 100 ether;
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        assertEq(IERC20(facet).balanceOf(user), shares);
        uint256 maxDeposit = VaultFacet(facet).maxDeposit(user);
        assertEq(maxDeposit, type(uint256).max);
        uint256 maxMint = VaultFacet(facet).maxMint(user);
        assertEq(maxMint, type(uint256).max);
    }

    function test_MaxDeposit_MaxMint_ShouldReturnZeroIfExceeded() public {
        MoreVaultsStorageHelper.setDepositCapacity(facet, 0);
        uint256 depositAmount = 100 ether;
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        assertEq(IERC20(facet).balanceOf(user), shares);
        MoreVaultsStorageHelper.setDepositCapacity(facet, 1);
        uint256 maxDeposit = VaultFacet(facet).maxDeposit(user);
        assertEq(maxDeposit, 0);
        uint256 maxMint = VaultFacet(facet).maxMint(user);
        assertEq(maxMint, 0);
    }

    function test_mint_ShouldRevertWhenExceededDepositCapacity() public {
        uint256 mintAmount = 1000001 * 10 ** IERC20Metadata(facet).decimals();

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

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
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 110);
        assertEq(MoreVaultsStorageHelper.getWithdrawTimelock(facet), 110, "Should set correct timelock duration");
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        assertEq(
            MoreVaultsStorageHelper.getIsWithdrawalQueueEnabled(facet),
            true,
            "Should set correct withdrawal queue status"
        );
        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));

        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // First deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);
        // Then withdraw
        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));

        uint256 withdrawAmount = 50 ether;
        uint256 expectedShares = IVaultFacet(facet).convertToShares(withdrawAmount);
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount);
        (uint256 sharesRequest, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(sharesRequest, expectedShares, "Should request correct amount of shares");
        assertEq(timelockEndsAt, block.timestamp + 110, "Should set correct timelock end time");
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
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 110);
        assertEq(MoreVaultsStorageHelper.getWithdrawTimelock(facet), 110, "Should set correct timelock duration");
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        assertEq(
            MoreVaultsStorageHelper.getIsWithdrawalQueueEnabled(facet),
            true,
            "Should set correct withdrawal queue status"
        );
        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));

        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // First deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        // Then withdraw
        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));

        uint256 balanceBefore = IERC20(asset).balanceOf(user);
        vm.prank(user);
        VaultFacet(facet).requestRedeem(shares);
        (uint256 sharesRequest, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(sharesRequest, shares, "Should request correct amount of shares");
        assertEq(timelockEndsAt, block.timestamp + 110, "Should set correct timelock end time");
        uint256 currentTimestamp = block.timestamp;
        vm.warp(currentTimestamp + 200);
        vm.prank(user);
        uint256 assets = VaultFacet(facet).redeem(shares, user, user);

        assertEq(IERC20(asset).balanceOf(user), balanceBefore + assets, "Should return correct amount of assets");
        assertEq(IERC20(facet).balanceOf(user), shares - shares, "Should burn correct amount of shares");
    }

    function test_redeem_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).redeem(100 ether, user, user);
    }

    function test_requestRedeem_shouldRevertIfSharesIsZero() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        vm.prank(user);
        vm.expectRevert(VaultFacet.InvalidSharesAmount.selector);
        VaultFacet(facet).requestRedeem(0);
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
        vm.prank(guardian);
        VaultFacet(facet).pause();

        address[] memory restrictedFacets = new address[](1);
        restrictedFacets[0] = address(101);
        vm.mockCall(factory, abi.encodeWithSignature("getRestrictedFacets()"), abi.encode(restrictedFacets));

        vm.mockCall(factory, abi.encodeWithSignature("isVaultLinked(address,address)"), abi.encode(false));
        // Then unpause
        vm.prank(guardian);
        VaultFacet(facet).unpause();
        assertFalse(VaultFacet(facet).paused(), "Should be unpaused");
    }

    function test_unpause_ShouldRevertIfUsingRestrictedFacet() public {
        // First pause
        vm.prank(guardian);
        VaultFacet(facet).pause();

        address[] memory restrictedFacets = new address[](1);
        restrictedFacets[0] = address(101);
        vm.mockCall(factory, abi.encodeWithSignature("getRestrictedFacets()"), abi.encode(restrictedFacets));

        vm.mockCall(factory, abi.encodeWithSignature("isVaultLinked(address,address)"), abi.encode(true));
        // Then unpause
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(VaultFacet.VaultIsUsingRestrictedFacet.selector, address(101)));
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
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));

        deal(asset, user, 1000001 ether);
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user, 1000001 ether, 1000000 ether
            )
        );
        VaultFacet(facet).deposit(1000001 ether, user);
    }

    function test_deposit_ShouldRevertWhenExceededDepositCapacityMultipleAssets() public {
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
            MoreVaultsStorageHelper.setDepositableAssets(facet, tokens[i], true);
        }

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset2),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, asset2),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        deal(asset, user, 1000001 ether);

        // Try to deposit
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user, 1000001 ether, 1000000 ether
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

    function test_deposit_ShouldRevertWhenDepositWithMultipleAssetsAndArrayLengthsDoesntMatch() public {
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

        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Try to deposit
        vm.prank(user);
        uint256[] memory corruptedAmounts = new uint256[](1);
        corruptedAmounts[0] = depositAmount;
        vm.expectRevert(abi.encodeWithSelector(IVaultFacet.ArraysLengthsDontMatch.selector, 2, 1));
        VaultFacet(facet).deposit(tokens, corruptedAmounts, user);
    }

    function test_deposit_ShouldRevertWhenDepositWithMultipleAssetsAndAssetIsNotDepositable() public {
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

        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Try to deposit
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IVaultFacet.UnsupportedAsset.selector, asset2));
        VaultFacet(facet).deposit(tokens, amounts, user);
    }

    function test_accrueInterest_ShouldDistributeFeesWithProtocolFee() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(
            registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(protocolFeeRecipient, protocolFee)
        );

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 * 10 ** 8, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(
            registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(protocolFeeRecipient, protocolFee)
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

    function test_accrueInterest_ShouldDistributeFeesWithoutProtocolFee() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(
            registry,
            abi.encodeWithSignature("protocolFeeInfo(address)"),
            abi.encode(address(0), 0) // No protocol fee
        );
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
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
            depositAmount * 10 ** decimalsOffset + newShares + VaultFacet(facet).convertToShares(totalFee),
            10,
            "Should increase total supply by fee amount"
        );
    }

    function test_accrueInterest_ShouldNotDistributeFeesWhenNoFee() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Set fee to 0
        MoreVaultsStorageHelper.setFee(facet, 0);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));

        // Trigger interest accrual
        vm.prank(user);
        VaultFacet(facet).deposit(0, user);

        // Check that no fees were distributed
        assertEq(IERC20(facet).balanceOf(feeRecipient), 0, "Should not distribute any fees");
        assertEq(
            IERC20(facet).totalSupply(), depositAmount * 10 ** decimalsOffset, "Should not mint extra shares for fee"
        );
    }

    function test_accrueInterest_ShouldNotDistributeFeesWhenInterestIsZero() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls with no price change
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0) // No price change
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));

        // Trigger interest accrual
        vm.prank(user);
        VaultFacet(facet).deposit(0, user);

        // Check that no fees were distributed
        assertEq(IERC20(facet).balanceOf(feeRecipient), 0, "Should not distribute any fees when no price change");
        assertEq(
            IERC20(facet).totalSupply(), depositAmount * 10 ** decimalsOffset, "Should not mint extra shares for fee"
        );
    }

    function test_accrueInterest_ShouldRevertIfTotalAssetsIsZero() public {
        // Setup initial deposit
        uint256 depositAmount = 100 ether;

        // Mock oracle calls for price increase
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.prank(user);
        VaultFacet(facet).deposit(depositAmount, user);

        // Move time forward to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Mock oracle calls with no price change
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1 ether, block.timestamp, block.timestamp, 0) // No price change
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));

        MockERC20(asset).burn(facet, depositAmount);

        // Trigger interest accrual
        vm.prank(user);
        vm.expectRevert(IVaultFacet.VaultDebtIsGreaterThanAssets.selector);
        VaultFacet(facet).deposit(0, user);
    }

    function test_setFee_ShouldUpdateFee() public {
        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), 0)
        );

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Set new fee
        uint96 newFee = 200; // 2%
        IVaultFacet(facet).setFee(newFee);

        // Verify through getter
        assertEq(MoreVaultsStorageHelper.getFee(address(facet)), newFee, "Fee should be updated");

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
        assertEq(MoreVaultsStorageHelper.getFee(address(facet)), 100, "Fee should not be changed");

        vm.stopPrank();
    }

    function test_setFee_ShouldRevertWhenInvalidFee() public {
        MoreVaultsStorageHelper.setFee(address(facet), 100); // 1%

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), 0)
        );

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.startPrank(address(facet));

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
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user2, 100 ether, 10 ether)
        );

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

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
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(oracleRegistry, abi.encodeWithSignature("getSourceOfAsset(address)"), abi.encode(oracle));
        vm.mockCall(
            oracle,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(0, 1.1 ether, block.timestamp, block.timestamp, 0) // 10% price increase
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user2, 100 ether, 10 ether)
        );
        VaultFacet(facet).mint(10_000 ether, user2);
        vm.stopPrank();
    }

    function test_multiAssetDeposit_ShouldRevertWhenDeposit_WhitelistIsExceeded() public {
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
            MoreVaultsStorageHelper.setDepositableAssets(facet, tokens[i], true);
        }

        // Mock oracle call
        vm.mockCall(registry, abi.encodeWithSignature("oracle()"), abi.encode(oracleRegistry));
        vm.mockCall(registry, abi.encodeWithSignature("getDenominationAsset()"), abi.encode(asset));
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset2),
            abi.encode(oracle, uint96(1000))
        );
        vm.mockCall(
            oracleRegistry,
            abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector, asset2),
            abi.encode(1 * 10 ** 8)
        );
        vm.mockCall(oracle, abi.encodeWithSignature("decimals()"), abi.encode(8));
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        vm.startPrank(user2);
        MockERC20(asset).mint(user2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user2, 300 ether, 10 ether)
        );
        VaultFacet(facet).deposit(tokens, amounts, user2);
        vm.stopPrank();
    }

    // ============ Withdrawal Fee Tests ============

    // function test_setWithdrawalFee_ShouldUpdateFee() public {
    //     uint96 newFee = 500; // 5%

    //     vm.prank(owner);
    //     VaultFacet(facet).setWithdrawalFee(newFee);

    //     assertEq(VaultFacet(facet).getWithdrawalFee(), newFee);
    // }

    // function test_setWithdrawalFee_ShouldRevertWhenUnauthorized() public {
    //     uint96 newFee = 500;

    //     vm.prank(user);
    //     vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
    //     VaultFacet(facet).setWithdrawalFee(newFee);
    // }

    // function test_getWithdrawalFee_ShouldReturnCurrentFee() public {
    //     uint96 initialFee = VaultFacet(facet).getWithdrawalFee();
    //     assertEq(initialFee, 0); // Should start at 0

    //     uint96 newFee = 1000; // 10%
    //     vm.prank(owner);
    //     VaultFacet(facet).setWithdrawalFee(newFee);

    //     assertEq(VaultFacet(facet).getWithdrawalFee(), newFee);
    // }

    function test_withdraw_ShouldApplyWithdrawalFee() public {
        // Setup withdrawal fee
        uint96 withdrawalFee = 1000; // 10%
        MoreVaultsStorageHelper.setWithdrawalFee(facet, withdrawalFee);

        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Request withdrawal
        uint256 withdrawAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount);

        // Fast forward past timelock
        vm.warp(block.timestamp + 1 days + 1);

        // Check balances before withdrawal
        uint256 userBalanceBefore = IERC20(asset).balanceOf(user);
        uint256 feeRecipientBalanceBefore = IERC20(facet).balanceOf(feeRecipient);

        // Execute withdrawal
        vm.prank(user);
        VaultFacet(facet).withdraw(withdrawAmount, user, user);

        // Check balances after withdrawal
        uint256 userBalanceAfter = IERC20(asset).balanceOf(user);
        uint256 feeRecipientBalanceAfter = IERC20(facet).balanceOf(feeRecipient);

        // Calculate expected fee (10% of 100 ether = 10 ether)
        uint256 expectedFee = (withdrawAmount * withdrawalFee) / 10000;
        uint256 expectedNetAmount = withdrawAmount - expectedFee;

        assertEq(userBalanceAfter - userBalanceBefore, expectedNetAmount);
        assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore);
    }

    function test_redeem_ShouldApplyWithdrawalFee() public {
        // Setup withdrawal fee
        uint96 withdrawalFee = 1000; // 10%
        MoreVaultsStorageHelper.setWithdrawalFee(facet, withdrawalFee);

        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Request redeem
        uint256 redeemShares = shares / 10; // Redeem 10% of shares
        vm.prank(user);
        VaultFacet(facet).requestRedeem(redeemShares);

        // Fast forward past timelock
        vm.warp(block.timestamp + 1 days + 1);

        // Check balances before redeem
        uint256 userBalanceBefore = IERC20(asset).balanceOf(user);
        uint256 feeRecipientBalanceBefore = IERC20(facet).balanceOf(feeRecipient);

        // Execute redeem
        vm.prank(user);
        uint256 assets = VaultFacet(facet).redeem(redeemShares, user, user);

        // Check balances after redeem
        uint256 userBalanceAfter = IERC20(asset).balanceOf(user);
        uint256 feeRecipientBalanceAfter = IERC20(facet).balanceOf(feeRecipient);

        // Calculate expected fee (10% of assets)
        uint256 expectedFee = (assets * withdrawalFee) / 10000;
        uint256 expectedNetAmount = assets - expectedFee;
        console.log("expectedFee", expectedFee);
        console.log("expectedNetAmount", expectedNetAmount);

        assertEq(userBalanceAfter - userBalanceBefore, expectedNetAmount);
        assertGt(feeRecipientBalanceAfter, feeRecipientBalanceBefore);
    }

    function test_previewWithdraw_ShouldAccountForWithdrawalFee() public {
        // Setup withdrawal fee
        uint96 withdrawalFee = 1000; // 10%
        vm.prank(owner);
        MoreVaultsStorageHelper.setWithdrawalFee(facet, withdrawalFee);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 withdrawAmount = 100 ether;
        uint256 expectedShares = VaultFacet(facet).previewWithdraw(withdrawAmount);

        // The preview should account for the fee
        assertTrue(expectedShares > 0);
    }

    function test_previewRedeem_ShouldAccountForWithdrawalFee() public {
        // Setup withdrawal fee
        uint96 withdrawalFee = 1000; // 10%
        vm.prank(owner);
        MoreVaultsStorageHelper.setWithdrawalFee(facet, withdrawalFee);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 redeemShares = shares / 10; // Redeem 10% of shares
        uint256 expectedAssets = VaultFacet(facet).previewRedeem(redeemShares);

        // Calculate expected fee
        uint256 totalAssets = (redeemShares * 1000 ether) / shares; // Approximate

        // The preview should account for the fee
        assertTrue(expectedAssets > 0);
        assertTrue(expectedAssets < totalAssets); // Should be less due to fee
    }

    function test_requestRedeem_ShouldRevertWhenQueueDisabled() public {
        // Ensure queue is disabled
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false);

        uint256 shares = 100 ether;
        vm.prank(user);
        vm.expectRevert(VaultFacet.WithdrawalQueueDisabled.selector);
        VaultFacet(facet).requestRedeem(shares);
    }

    function test_requestWithdraw_ShouldRevertWhenQueueDisabled() public {
        // Ensure queue is disabled
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false);

        uint256 assets = 100 ether;
        vm.prank(user);
        vm.expectRevert(VaultFacet.WithdrawalQueueDisabled.selector);
        VaultFacet(facet).requestWithdraw(assets);
    }

    // ============ Preview Function Tests ============

    function test_previewDeposit_ShouldCalculateCorrectShares() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        uint256 assets = 100 ether;
        uint256 expectedShares = VaultFacet(facet).previewDeposit(assets);

        // Should return a positive number
        assertTrue(expectedShares > 0);

        // Should be consistent with actual deposit
        MockERC20(asset).mint(user, assets);
        vm.startPrank(user);
        IERC20(asset).approve(facet, assets);
        uint256 actualShares = VaultFacet(facet).deposit(assets, user);
        vm.stopPrank();

        // Preview should match actual (within rounding)
        assertApproxEqRel(expectedShares, actualShares, 0.01e18);
    }

    function test_previewMint_ShouldCalculateCorrectAssets() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        uint256 shares = 100 ether;
        uint256 expectedAssets = VaultFacet(facet).previewMint(shares);

        // Should return a positive number
        assertTrue(expectedAssets > 0);

        // Should be consistent with actual mint
        uint256 depositAmount = expectedAssets + 100 ether; // Extra for minting
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user); // First deposit to initialize

        // Mint additional tokens for the mint operation
        MockERC20(asset).mint(user, expectedAssets);
        IERC20(asset).approve(facet, expectedAssets);
        uint256 actualAssets = VaultFacet(facet).mint(shares, user);
        vm.stopPrank();

        // Preview should match actual (within rounding)
        assertApproxEqRel(expectedAssets, actualAssets, 0.01e18);
    }

    function test_previewWithdraw_ShouldCalculateCorrectShares() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // First deposit to initialize vault
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 assets = 100 ether;
        uint256 expectedShares = VaultFacet(facet).previewWithdraw(assets);

        // Should return a positive number
        assertTrue(expectedShares > 0);
    }

    function test_previewRedeem_ShouldCalculateCorrectAssets() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // First deposit to initialize vault
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 redeemShares = shares / 10; // Redeem 10% of shares
        uint256 expectedAssets = VaultFacet(facet).previewRedeem(redeemShares);

        // Should return a positive number
        assertTrue(expectedAssets > 0);
    }

    // ============ Edge Case Tests ============

    function test_maxDeposit_ShouldReturnCorrectValue() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Test with deposit capacity
        uint256 maxDeposit = VaultFacet(facet).maxDeposit(user);
        assertEq(maxDeposit, DEPOSIT_CAPACITY);

        // Test after partial deposit
        uint256 depositAmount = 100 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 newMaxDeposit = VaultFacet(facet).maxDeposit(user);
        assertEq(newMaxDeposit, DEPOSIT_CAPACITY - depositAmount);
    }

    function test_maxMint_ShouldReturnCorrectValue() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Test with deposit capacity
        uint256 maxMint = VaultFacet(facet).maxMint(user);
        assertTrue(maxMint > 0);

        // Test after partial deposit
        uint256 depositAmount = 100 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 newMaxMint = VaultFacet(facet).maxMint(user);
        assertTrue(newMaxMint > 0);
        assertTrue(newMaxMint < maxMint);
    }

    function test_clearRequest_ShouldClearWithdrawalRequest() public {
        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // First deposit to get shares
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Create a withdrawal request
        uint256 shares = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestRedeem(shares);

        // Check request exists
        (uint256 requestShares, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(requestShares, shares);
        assertTrue(timelockEndsAt > 0);

        // Clear request
        vm.prank(user);
        VaultFacet(facet).clearRequest();

        // Check request is cleared
        (requestShares, timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(requestShares, 0);
        assertEq(timelockEndsAt, 0);
    }

    // ============ Additional Edge Case Tests ============

    function test_withdraw_ShouldNotApplyFeeWhenZero() public {
        // Ensure withdrawal fee is 0
        assertEq(MoreVaultsStorageHelper.getWithdrawalFee(facet), 0);

        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Request withdrawal
        uint256 withdrawAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount);

        // Fast forward past timelock
        vm.warp(block.timestamp + 1 days + 1);

        // Check balances before withdrawal
        uint256 userBalanceBefore = IERC20(asset).balanceOf(user);

        // Execute withdrawal
        vm.prank(user);
        VaultFacet(facet).withdraw(withdrawAmount, user, user);

        // Check balances after withdrawal - should receive full amount
        uint256 userBalanceAfter = IERC20(asset).balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, withdrawAmount);
    }

    function test_redeem_ShouldNotApplyFeeWhenZero() public {
        // Ensure withdrawal fee is 0
        assertEq(MoreVaultsStorageHelper.getWithdrawalFee(facet), 0);

        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Request redeem
        uint256 redeemShares = shares / 10; // Redeem 10% of shares
        vm.prank(user);
        VaultFacet(facet).requestRedeem(redeemShares);

        // Fast forward past timelock
        vm.warp(block.timestamp + 1 days + 1);

        // Check balances before redeem
        uint256 userBalanceBefore = IERC20(asset).balanceOf(user);

        // Execute redeem
        vm.prank(user);
        uint256 assets = VaultFacet(facet).redeem(redeemShares, user, user);

        // Check balances after redeem - should receive full amount
        uint256 userBalanceAfter = IERC20(asset).balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, assets);
    }

    function test_maxDeposit_ShouldReturnZeroWhenCapacityExceeded() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Fill up the vault to capacity
        uint256 depositAmount = DEPOSIT_CAPACITY;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Now maxDeposit should be 0
        uint256 maxDeposit = VaultFacet(facet).maxDeposit(user);
        assertEq(maxDeposit, 0);
    }

    function test_maxMint_ShouldReturnZeroWhenCapacityExceeded() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Fill up the vault to capacity
        uint256 depositAmount = DEPOSIT_CAPACITY;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Now maxMint should be 0
        uint256 maxMint = VaultFacet(facet).maxMint(user);
        assertEq(maxMint, 0);
    }

    function test_facetVersion_ShouldReturnVersion() public view {
        string memory version = VaultFacet(facet).facetVersion();
        assertEq(version, "1.0.0");
    }

    function test_onFacetRemoval_ShouldDisableInterface() public {
        // This tests the onFacetRemoval function
        // It should disable the IVaultFacet interface
        VaultFacet(facet).onFacetRemoval(false);

        // The function should execute without reverting
        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IVaultFacet).interfaceId),
            "Should disable IVaultFacet interface"
        );
    }

    function test_paused_ShouldReturnCorrectState() public {
        // Initially should not be paused
        assertFalse(VaultFacet(facet).paused());

        // Pause the vault
        vm.prank(guardian);
        VaultFacet(facet).pause();
        assertTrue(VaultFacet(facet).paused());

        // Mock factory call for unpause
        vm.mockCall(factory, abi.encodeWithSignature("getRestrictedFacets()"), abi.encode(new address[](0)));

        // Unpause the vault
        vm.prank(guardian);
        VaultFacet(facet).unpause();
        assertFalse(VaultFacet(facet).paused());
    }

    function test_getWithdrawalRequest_ShouldReturnCorrectValues() public {
        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        // Initially should be empty
        (uint256 shares, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(shares, 0);
        assertEq(timelockEndsAt, 0);

        // First deposit to get shares
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.startPrank(user);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, user);
        vm.stopPrank();

        // Create a request
        uint256 requestShares = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestRedeem(requestShares);

        // Check request values
        (shares, timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(shares, requestShares);
        assertTrue(timelockEndsAt > 0); // Should have a valid timelock end time
    }

    function test_getWithdrawalTimelock_ShouldReturnCorrectValue() public {
        uint64 timelock = MoreVaultsStorageHelper.getWithdrawTimelock(facet);
        assertEq(timelock, 0); // Should start at 0

        // Update timelock
        uint64 newTimelock = 2 days;
        vm.prank(curator);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, newTimelock);
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));
        uint64 updatedTimelock = MoreVaultsStorageHelper.getWithdrawTimelock(facet);
        assertEq(updatedTimelock, newTimelock);
    }

    // function test_lockedTokensAmountOfAsset_ShouldReturnCorrectValue() public {
    //     // Test with the main asset
    //     uint256 lockedAmount = VaultFacet(facet).lockedTokensAmountOfAsset(
    //         asset
    //     );
    //     assertEq(lockedAmount, 0); // Should start at 0
    //     uint32[] memory eids = new uint32[](0);
    //     address[] memory vaults = new address[](0);
    //     vm.mockCall(
    //         factory,
    //         abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector),
    //         abi.encode(eids, vaults)
    //     );
    //     // Test with a different asset
    //     address otherAsset = address(0x123);
    //     uint256 otherLockedAmount = VaultFacet(facet).lockedTokensAmountOfAsset(
    //         otherAsset
    //     );
    //     assertEq(otherLockedAmount, 0);
    // }

    // function test_getStakingAddresses_ShouldReturnCorrectValue() public {
    //     bytes32 stakingFacetId = keccak256("TestStakingFacet");
    //     address[] memory addresses = VaultFacet(facet).getStakingAddresses(
    //         stakingFacetId
    //     );
    //     assertEq(addresses.length, 0);
    //     address[] memory newAddresses = new address[](1);
    //     newAddresses[0] = address(0x123);
    //     MoreVaultsStorageHelper.setStakingAddresses(
    //         facet,
    //         stakingFacetId,
    //         newAddresses
    //     );
    //     addresses = VaultFacet(facet).getStakingAddresses(stakingFacetId);
    //     assertEq(addresses.length, 1);
    //     assertEq(addresses[0], address(0x123));
    // }

    // function test_tokensHeld_ShouldReturnCorrectValue() public {
    //     bytes32 tokenId = keccak256("TestTokenId");
    //     address[] memory tokens = VaultFacet(facet).tokensHeld(tokenId);
    //     assertEq(tokens.length, 0);
    //     address[] memory newTokens = new address[](1);
    //     newTokens[0] = address(0x123);
    //     MoreVaultsStorageHelper.setTokensHeld(facet, tokenId, newTokens);
    //     tokens = VaultFacet(facet).tokensHeld(tokenId);
    //     assertEq(tokens.length, 1);
    //     assertEq(tokens[0], address(0x123));
    // }
}
