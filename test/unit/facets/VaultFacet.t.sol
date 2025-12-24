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
import {ERC20Upgradeable, IERC20Errors} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IConfigurationFacet} from "../../../src/interfaces/facets/IConfigurationFacet.sol";
import {MaliciousAccountingFacet} from "../../mocks/MaliciousAccountingFacet.sol";

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
    address public router = address(1002);

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
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));

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
        VaultFacet(facet).deposit(tokens, amounts, user, 0);

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
        VaultFacet(facet).deposit(tokens, amounts, user, 0);
    }

    function test_deposit_ShouldRevertWhenSlippageExceeded() public {
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

        // Set minAmountOut to a very large value that will definitely exceed actual shares
        // This simulates a scenario where user expects more shares than they will receive
        uint256 minAmountOut = type(uint256).max;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IVaultFacet.SlippageExceeded.selector, (depositAmount + depositAmount2) * 1e2, minAmountOut));
        VaultFacet(facet).deposit(tokens, amounts, user, minAmountOut);
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
        VaultFacet(facet).deposit{value: depositAmountInNative}(tokens, amounts, user, 0);

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

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector,
                user,
                1000001 * 10 ** IERC20Metadata(asset).decimals(),
                1000000 * 10 ** IERC20Metadata(asset).decimals()
            )
        );
        VaultFacet(facet).mint(mintAmount, user);
        vm.stopPrank();
    }

    function test_withdraw_ShouldBurnShares() public {
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 110);
        assertEq(MoreVaultsStorageHelper.getWithdrawTimelock(facet), 110, "Should set correct timelock duration");
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
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
        
        // Get HWMpS before requestWithdraw
        uint256 hwmBefore = _getHWMpS(user);
        
        // Get current price per share
        uint256 totalAssetsBefore = IVaultFacet(facet).totalAssets();
        uint256 totalSupplyBefore = IERC20(facet).totalSupply();
        uint256 currentPricePerShare = _calculatePricePerShare(totalAssetsBefore, totalSupplyBefore);
        
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);
        
        // Verify HWMpS was updated if current price is higher
        uint256 hwmAfter = _getHWMpS(user);
        if (currentPricePerShare > hwmBefore) {
            assertEq(hwmAfter, currentPricePerShare, "HWMpS should be updated to current price per share");
        } else {
            assertEq(hwmAfter, hwmBefore, "HWMpS should remain unchanged if price didn't increase");
        }
        
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
        VaultFacet(facet).requestWithdraw(100 ether, address(facet));
    }

    function test_redeem_ShouldBurnShares() public {
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 110);
        assertEq(MoreVaultsStorageHelper.getWithdrawTimelock(facet), 110, "Should set correct timelock duration");
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
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
        VaultFacet(facet).requestRedeem(shares, user);
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
        vm.expectRevert(IVaultFacet.InvalidSharesAmount.selector);
        VaultFacet(facet).requestRedeem(0, user);
    }

    function test_requestRedeem_ShouldRevertInMulticall() public {
        MoreVaultsStorageHelper.setIsMulticall(address(facet), true);
        vm.prank(address(facet));
        vm.expectRevert(MoreVaultsLib.RestrictedActionInsideMulticall.selector);
        VaultFacet(facet).requestRedeem(100 ether, address(facet));
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
        vm.expectRevert(abi.encodeWithSelector(IVaultFacet.VaultIsUsingRestrictedFacet.selector, address(101)));
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
        VaultFacet(facet).deposit(tokens, amounts, user, 0);
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
        VaultFacet(facet).deposit(tokens, amounts, user, 0);
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
        VaultFacet(facet).deposit(tokens, corruptedAmounts, user, 0);
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
        VaultFacet(facet).deposit(tokens, amounts, user, 0);
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

        // Add interest to vault (price increase)
        uint256 totalInterest = 10 ether; // 10% of 100 ether
        MockERC20(asset).mint(facet, totalInterest);

        // Get state before second deposit
        uint256 userSharesBefore = IERC20(facet).balanceOf(user);
        uint256 totalSupplyBefore = IERC20(facet).totalSupply();
        uint256 totalAssetsBeforeInterest = 100 ether; // Initial deposit amount

        vm.prank(user);
        uint256 newShares = VaultFacet(facet).deposit(1, user);

        // Get balances after deposit
        uint256 protocolFeeBalance = IERC20(facet).balanceOf(protocolFeeRecipient);
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        uint256 totalFeeShares = protocolFeeBalance + vaultFeeBalance;

        // Calculate expected fee based on user's profit above HWMpS
        // HWMpS was set at price after first deposit: totalAssetsBeforeInterest / (totalSupplyBefore + 10^decimalsOffset)
        // Current price after interest: (totalAssetsBeforeInterest + totalInterest) / (totalSupplyBefore + 10^decimalsOffset)
        // User's profit = userSharesBefore * (currentPrice - HWMpS)
        uint256 hwmPrice = (10 ** IVaultFacet(facet).decimals()).mulDiv(
            totalAssetsBeforeInterest + 1, totalSupplyBefore + 10 ** decimalsOffset, Math.Rounding.Floor
        );
        uint256 currentPrice = (10 ** IVaultFacet(facet).decimals()).mulDiv((totalAssetsBeforeInterest + totalInterest + 1), totalSupplyBefore + 10 ** decimalsOffset, Math.Rounding.Floor);

        uint256 userProfit = userSharesBefore.mulDiv(currentPrice - hwmPrice, 10 ** IVaultFacet(facet).decimals(), Math.Rounding.Floor);

        // Expected fee assets
        uint256 expectedFeeAssets = userProfit.mulDiv(FEE, FEE_BASIS_POINT);
        uint256 expectedProtocolFeeAssets = expectedFeeAssets.mulDiv(protocolFee, FEE_BASIS_POINT);
        uint256 expectedVaultFeeAssets = expectedFeeAssets - expectedProtocolFeeAssets;

        // Check fee distribution (using approximate comparison as fee shares calculation may have rounding)
        assertGt(protocolFeeBalance, 0, "Should distribute protocol fee");
        assertGt(vaultFeeBalance, 0, "Should distribute vault fee");
        assertApproxEqRel(
            protocolFeeBalance + vaultFeeBalance,
            VaultFacet(facet).convertToShares(expectedFeeAssets),
            1e15, // 0.1% tolerance
            "Should distribute correct total fee"
        );
        assertApproxEqAbs(
            IERC20(facet).totalSupply(),
            shares + newShares + totalFeeShares,
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

        // Add interest to vault (price increase)
        uint256 totalInterest = 10 ether; // 10% of 100 ether
        MockERC20(asset).mint(facet, totalInterest);

        // Get state before second deposit
        uint256 userSharesBefore = IERC20(facet).balanceOf(user);
        uint256 totalSupplyBefore = IERC20(facet).totalSupply();
        uint256 totalAssetsBeforeInterest = depositAmount; // Initial deposit amount

        // Trigger interest accrual
        vm.prank(user);
        uint256 newShares = VaultFacet(facet).deposit(1, user);

        // Get fee balance after deposit
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Calculate expected fee based on user's profit above HWMpS
        uint256 hwmPrice = (10 ** IVaultFacet(facet).decimals()).mulDiv(
            totalAssetsBeforeInterest + 1, totalSupplyBefore + 10 ** decimalsOffset, Math.Rounding.Floor
        );
        uint256 currentPrice = (10 ** IVaultFacet(facet).decimals()).mulDiv((totalAssetsBeforeInterest + totalInterest + 1), totalSupplyBefore + 10 ** decimalsOffset, Math.Rounding.Floor);

        uint256 userProfit = userSharesBefore.mulDiv(currentPrice - hwmPrice, 10 ** IVaultFacet(facet).decimals(), Math.Rounding.Floor);

        // Expected fee assets
        uint256 expectedFeeAssets = userProfit.mulDiv(FEE, FEE_BASIS_POINT);
        // Check fee distribution (using approximate comparison as fee shares calculation may have rounding)
        assertGt(vaultFeeBalance, 0, "Should distribute fees to vault fee recipient");
        assertApproxEqRel(
            vaultFeeBalance,
            VaultFacet(facet).convertToShares(expectedFeeAssets),
            1e15, // 0.1% tolerance
            "Should distribute correct fee amount"
        );
        assertApproxEqAbs(
            IERC20(facet).totalSupply(),
            depositAmount * 10 ** decimalsOffset + newShares + vaultFeeBalance,
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
        address testUser2 = address(114);
        depositors[0] = testUser2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser2, 10 ether);
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
        vm.startPrank(testUser2);
        MockERC20(asset).mint(testUser2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, testUser2, 100 ether, 10 ether)
        );

        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        VaultFacet(facet).deposit(100 ether, testUser2);
        vm.stopPrank();
    }

    function test_mint_ShouldRevertWhenDepositWhitelistIsExceeded() public {
        address[] memory depositors = new address[](1);
        address testUser2 = address(114);
        depositors[0] = testUser2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser2, 10 ether);
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

        vm.startPrank(testUser2);
        MockERC20(asset).mint(testUser2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, testUser2, 100 ether, 10 ether)
        );
        VaultFacet(facet).mint(10_000 ether, testUser2);
        vm.stopPrank();
    }

    function test_multiAssetDeposit_ShouldRevertWhenDeposit_WhitelistIsExceeded() public {
        address[] memory depositors = new address[](1);
        address testUser2 = address(114);
        depositors[0] = testUser2;
        uint256[] memory undelyingAssetCaps = new uint256[](1);
        undelyingAssetCaps[0] = 10 ether;
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser2, 10 ether);
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MockERC20 mockAsset2 = new MockERC20("Test Asset 2", "TA2");
        address asset2 = address(mockAsset2);
        uint256 depositAmount = 100 ether;
        uint256 depositAmount2 = 200 ether;

        MockERC20(asset2).mint(testUser2, depositAmount2);
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
        vm.startPrank(testUser2);
        MockERC20(asset).mint(testUser2, 100 ether);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, testUser2, 300 ether, 10 ether)
        );
        VaultFacet(facet).deposit(tokens, amounts, testUser2, 0);
        vm.stopPrank();
    }

    // ============ Issue #40: Whitelist Consistency Tests ============

    /**
     * @notice Issue #40 - Whitelisted caller can deposit for non-whitelisted receiver
     * @dev The whitelist controls who can deposit (caller), not who receives shares (receiver)
     */
    function test_deposit_WhitelistedCallerCanDepositForNonWhitelistedReceiver() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256 aliceCap = 100 ether;
        uint256 depositAmount = 50 ether;

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, alice, aliceCap);

        MockERC20(asset).mint(alice, depositAmount);
        vm.prank(alice);
        IERC20(asset).approve(facet, type(uint256).max);

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

        vm.startPrank(alice);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, bob);
        vm.stopPrank();

        assertGt(shares, 0, "Should have received shares");
        assertEq(IERC20(facet).balanceOf(bob), shares, "Bob should have received the shares");

        uint256 aliceCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, alice);
        assertEq(aliceCapAfter, aliceCap - depositAmount, "Alice's cap should be deducted");
    }

    /**
     * @notice Issue #40 - Whitelist cap deduction consistency
     * @dev Both validation and deduction should use the caller (depositor) address
     */
    function test_deposit_WhitelistCapDeductedFromCaller() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256 aliceCap = 100 ether;
        uint256 bobCap = 200 ether;
        uint256 depositAmount = 50 ether;

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, alice, aliceCap);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, bob, bobCap);

        MockERC20(asset).mint(alice, depositAmount);
        vm.prank(alice);
        IERC20(asset).approve(facet, type(uint256).max);

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

        uint256 aliceCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, alice);
        uint256 bobCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, bob);

        vm.prank(alice);
        VaultFacet(facet).deposit(depositAmount, bob);

        uint256 aliceCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, alice);
        uint256 bobCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, bob);

        assertEq(aliceCapAfter, aliceCapBefore - depositAmount, "Alice's cap should be deducted (she's the depositor)");
        assertEq(bobCapAfter, bobCapBefore, "Bob's cap should not change (he's just the receiver)");
    }

    /**
     * @notice Issue #40 - Whitelisted caller can mint for non-whitelisted receiver
     * @dev The whitelist controls who can deposit (caller), not who receives shares (receiver)
     */
    function test_mint_WhitelistedCallerCanMintForNonWhitelistedReceiver() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        uint256 aliceCap = 100 ether;
        uint256 sharesToMint = 5000 ether;

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, alice, aliceCap);

        MockERC20(asset).mint(alice, 100 ether);
        vm.prank(alice);
        IERC20(asset).approve(facet, type(uint256).max);

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

        vm.startPrank(alice);
        uint256 assets = VaultFacet(facet).mint(sharesToMint, bob);
        vm.stopPrank();

        assertGt(assets, 0, "Should have used some assets");
        assertEq(IERC20(facet).balanceOf(bob), sharesToMint, "Bob should have received the shares");

        uint256 aliceCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, alice);
        assertEq(aliceCapAfter, aliceCap - assets, "Alice's cap should be deducted");
    }

    /**
     * @notice Test that deposit decreases availableToDeposit correctly
     */
    function test_changeDepositCap_Deposit_DecreasesAvailableToDeposit() public {
        address testUser = address(0xD000);
        uint256 initialCap = 100 ether;
        uint256 depositAmount = 30 ether;

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser, initialCap);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, testUser, initialCap);

        MockERC20(asset).mint(testUser, depositAmount);
        vm.prank(testUser);
        IERC20(asset).approve(facet, type(uint256).max);

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

        uint256 availableToDepositBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        assertEq(availableToDepositBefore, initialCap, "Initial availableToDeposit should be set correctly");

        vm.prank(testUser);
        VaultFacet(facet).deposit(depositAmount, testUser);

        uint256 availableToDepositAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        assertEq(
            availableToDepositAfter,
            initialCap - depositAmount,
            "availableToDeposit should be decreased by depositAmount"
        );
    }

    /**
     * @notice Test that withdrawal increases availableToDeposit but not more than initialDepositCapPerUser
     */
    function test_changeDepositCap_Withdrawal_IncreasesAvailableToDepositUpToInitialCap() public {
        address testUser = address(0xD001);
        uint256 initialCap = 100 ether;
        uint256 depositAmount = 50 ether;
        uint256 withdrawAmount = 20 ether;

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser, initialCap);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, testUser, initialCap);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false); // Disable withdrawal queue for direct withdraw

        MockERC20(asset).mint(testUser, depositAmount);
        vm.prank(testUser);
        IERC20(asset).approve(facet, type(uint256).max);

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

        // Deposit first
        vm.prank(testUser);
        VaultFacet(facet).deposit(depositAmount, testUser);

        uint256 availableToDepositAfterDeposit = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        assertEq(
            availableToDepositAfterDeposit,
            initialCap - depositAmount,
            "availableToDeposit should be decreased after deposit"
        );

        // Withdraw
        vm.prank(testUser);
        VaultFacet(facet).withdraw(withdrawAmount, testUser, testUser);

        uint256 availableToDepositAfterWithdraw = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        uint256 expectedAvailable = availableToDepositAfterDeposit + withdrawAmount;
        assertEq(
            availableToDepositAfterWithdraw,
            expectedAvailable,
            "availableToDeposit should be increased by withdrawAmount"
        );
        assertLe(
            availableToDepositAfterWithdraw,
            initialCap,
            "availableToDeposit should not exceed initialDepositCapPerUser"
        );
    }

    /**
     * @notice Test that withdrawal caps availableToDeposit to initialDepositCapPerUser when sum exceeds it
     */
    function test_changeDepositCap_Withdrawal_CapsToInitialDepositCapPerUser() public {
        address testUser = address(0xD002);
        uint256 initialCap = 100 ether;
        uint256 depositAmount = 50 ether;
        uint256 withdrawAmount = 60 ether; // This would exceed initialCap if added

        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, testUser, initialCap);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, testUser, initialCap);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false); // Disable withdrawal queue for direct withdraw

        MockERC20(asset).mint(testUser, depositAmount);
        vm.prank(testUser);
        IERC20(asset).approve(facet, type(uint256).max);

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

        // Deposit first
        vm.prank(testUser);
        VaultFacet(facet).deposit(depositAmount, testUser);

        uint256 availableToDepositAfterDeposit = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        assertEq(
            availableToDepositAfterDeposit,
            initialCap - depositAmount,
            "availableToDeposit should be decreased after deposit"
        );
        MockERC20(asset).mint(facet, depositAmount);

        // Withdraw more than would fit in the cap
        vm.prank(testUser);
        VaultFacet(facet).withdraw(withdrawAmount, testUser, testUser);

        uint256 availableToDepositAfterWithdraw = MoreVaultsStorageHelper.getAvailableToDeposit(facet, testUser);
        // Should be capped to initialCap, not availableToDepositAfterDeposit + withdrawAmount
        assertEq(
            availableToDepositAfterWithdraw,
            initialCap,
            "availableToDeposit should be capped to initialDepositCapPerUser"
        );
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
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

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

        // Get HWMpS and price before requestWithdraw
        uint256 hwmBefore = _getHWMpS(user);
        uint256 totalAssetsBefore = IVaultFacet(facet).totalAssets();
        uint256 totalSupplyBefore = IERC20(facet).totalSupply();
        uint256 currentPricePerShare = _calculatePricePerShare(totalAssetsBefore, totalSupplyBefore);

        // Request withdrawal
        uint256 withdrawAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);

        // Verify HWMpS was updated if current price is higher
        uint256 hwmAfter = _getHWMpS(user);
        if (currentPricePerShare > hwmBefore) {
            assertEq(hwmAfter, currentPricePerShare, "HWMpS should be updated to current price per share");
        } else {
            assertEq(hwmAfter, hwmBefore, "HWMpS should remain unchanged if price didn't increase");
        }

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
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

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
        VaultFacet(facet).requestRedeem(redeemShares, user);

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
        vm.expectRevert(IVaultFacet.WithdrawalQueueDisabled.selector);
        VaultFacet(facet).requestRedeem(shares, user);
    }

    function test_requestWithdraw_ShouldRevertWhenQueueDisabled() public {
        // Ensure queue is disabled
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false);

        uint256 assets = 100 ether;
        vm.prank(user);
        vm.expectRevert(IVaultFacet.WithdrawalQueueDisabled.selector);
        VaultFacet(facet).requestWithdraw(assets, user);
    }

    /**
     * @notice Test that requestWithdraw updates HWMpS when current price is higher
     */
    function test_requestWithdraw_ShouldUpdateHWMpSWhenPriceIncreased() public {
        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Get initial HWMpS (should be set to current price per share)
        uint256 initialHWMpS = _getHWMpS(user);
        assertGt(initialHWMpS, 0, "Initial HWMpS should be set");

        // Simulate price increase by minting assets to vault
        MockERC20(asset).mint(facet, 100 ether);


        // Verify price increased
        // Get current price per share before requestWithdraw
        uint256 totalAssets = IVaultFacet(facet).totalAssets();
        uint256 totalSupply = IERC20(facet).totalSupply();
        uint256 pricePerShareBeforeRequest = _calculatePricePerShare(totalAssets, totalSupply);
        assertGt(pricePerShareBeforeRequest, initialHWMpS, "Price should have increased");

        // Request withdrawal - this should update HWMpS
        uint256 withdrawAmount = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);

        // Price should decrease because of fee shares minted
        // Get current price per share before requestWithdraw
        totalAssets = IVaultFacet(facet).totalAssets();
        totalSupply = IERC20(facet).totalSupply();
        uint256 pricePerShareAfterRequest = _calculatePricePerShare(totalAssets, totalSupply);
        assertGt(pricePerShareBeforeRequest, pricePerShareAfterRequest, "Price should have decreased");

        // Verify HWMpS was updated to current price per share
        uint256 updatedHWMpS = _getHWMpS(user);
        assertEq(updatedHWMpS, pricePerShareAfterRequest, "HWMpS should be updated to current price per share");
        assertGt(updatedHWMpS, initialHWMpS, "HWMpS should have increased");
    }

    /**
     * @notice Test that requestWithdraw does not update HWMpS when current price is lower
     */
    function test_requestWithdraw_ShouldNotUpdateHWMpSWhenPriceDecreased() public {
        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Simulate price increase first
        MockERC20(asset).mint(facet, 100 ether);
        
        // Request withdrawal to update HWMpS to higher value
        uint256 withdrawAmount1 = 50 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount1, user);

        // Get HWMpS after first request (should be updated)
        uint256 hwmAfterFirstRequest = _getHWMpS(user);
        assertGt(hwmAfterFirstRequest, 0, "HWMpS should be set after first request");

        // Simulate price decrease (burn assets from vault - this is not realistic but for testing)
        // Note: In reality, we can't easily decrease totalAssets, but we can test with a scenario
        // where the price doesn't increase further
        uint256 totalAssetsBefore = IVaultFacet(facet).totalAssets();
        
        // Request another withdrawal - price should be same or lower relative to HWMpS
        uint256 withdrawAmount2 = 50 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount2, user);

        // HWMpS should remain the same (not decrease)
        uint256 hwmAfterSecondRequest = _getHWMpS(user);
        assertEq(hwmAfterSecondRequest, hwmAfterFirstRequest, "HWMpS should not decrease");
    }

    /**
     * @notice Test that requestWithdraw updates HWMpS correctly when called multiple times with price increases
     */
    function test_requestWithdraw_ShouldUpdateHWMpSMultipleTimes() public {
        // Setup withdrawal queue
        vm.prank(owner);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // First request - get initial HWMpS
        uint256 withdrawAmount1 = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount1, user);
        
        // Get price after first request (price decreases due to fee shares minted)
        uint256 totalAssets1 = IVaultFacet(facet).totalAssets();
        uint256 totalSupply1 = IERC20(facet).totalSupply();
        uint256 price1AfterRequest = _calculatePricePerShare(totalAssets1, totalSupply1);
        uint256 hwm1 = _getHWMpS(user);
        assertEq(hwm1, price1AfterRequest, "HWMpS should be updated to price after first request");
        assertGt(hwm1, 0, "HWMpS should be set after first request");

        // Simulate price increase
        MockERC20(asset).mint(facet, 50 ether);
        uint256 totalAssets2BeforeRequest = IVaultFacet(facet).totalAssets();
        uint256 totalSupply2BeforeRequest = IERC20(facet).totalSupply();
        uint256 price2BeforeRequest = _calculatePricePerShare(totalAssets2BeforeRequest, totalSupply2BeforeRequest);
        assertGt(price2BeforeRequest, hwm1, "Price should have increased before second request");

        // Second request - HWMpS should update to price AFTER request
        uint256 withdrawAmount2 = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount2, user);
        
        // Get price after second request (price decreases due to fee shares minted)
        uint256 totalAssets2AfterRequest = IVaultFacet(facet).totalAssets();
        uint256 totalSupply2AfterRequest = IERC20(facet).totalSupply();
        uint256 price2AfterRequest = _calculatePricePerShare(totalAssets2AfterRequest, totalSupply2AfterRequest);
        uint256 hwm2 = _getHWMpS(user);
        assertEq(hwm2, price2AfterRequest, "HWMpS should be updated to price after second request");
        assertGt(hwm2, hwm1, "HWMpS should have increased");

        // Simulate another price increase
        MockERC20(asset).mint(facet, 50 ether);
        uint256 totalAssets3BeforeRequest = IVaultFacet(facet).totalAssets();
        uint256 totalSupply3BeforeRequest = IERC20(facet).totalSupply();
        uint256 price3BeforeRequest = _calculatePricePerShare(totalAssets3BeforeRequest, totalSupply3BeforeRequest);
        assertGt(price3BeforeRequest, hwm2, "Price should have increased before third request");

        // Third request - HWMpS should update to price AFTER request
        uint256 withdrawAmount3 = 100 ether;
        vm.prank(user);
        VaultFacet(facet).requestWithdraw(withdrawAmount3, user);
        
        // Get price after third request (price decreases due to fee shares minted)
        uint256 totalAssets3AfterRequest = IVaultFacet(facet).totalAssets();
        uint256 totalSupply3AfterRequest = IERC20(facet).totalSupply();
        uint256 price3AfterRequest = _calculatePricePerShare(totalAssets3AfterRequest, totalSupply3AfterRequest);
        uint256 hwm3 = _getHWMpS(user);
        assertEq(hwm3, price3AfterRequest, "HWMpS should be updated to price after third request");
        assertGt(hwm3, hwm2, "HWMpS should have increased again");
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
        VaultFacet(facet).requestRedeem(shares, user);

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
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
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
        VaultFacet(facet).requestWithdraw(withdrawAmount, user);

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
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

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
        VaultFacet(facet).requestRedeem(redeemShares, user);

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
        assertEq(version, "1.0.1");
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
        VaultFacet(facet).requestRedeem(requestShares, user);

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

    // Issue #30: Assembly arithmetic lacks overflow protection
    function test_accountingFacetOverflow() public {
        MockERC20(asset).mint(facet, 1000 ether);

        MaliciousAccountingFacet malicious = new MaliciousAccountingFacet();
        bytes4 selector = MaliciousAccountingFacet.accountingMaliciousFacet.selector;

        MoreVaultsStorageHelper.setSelectorToFacetAndPosition(facet, selector, address(malicious), 0);
        MoreVaultsStorageHelper.addFacetForAccounting(facet, bytes32(selector));

        vm.mockCall(facet, abi.encodeWithSelector(selector), abi.encode(type(uint256).max, true));

        vm.expectRevert();
        VaultFacet(facet).totalAssets();
    }

    // ============ Tests for High-Water Mark per Share (HWMpS) ============

    address public user2 = address(2);
    address public user3 = address(3);

    /**
     * @notice Helper function to calculate price per share (with decimals offset)
     * Use same formula as _convertToAssets: (1 share) * (totalAssets + 1) / (totalSupply + 10^decimalsOffset)
     */
    function _calculatePricePerShare(uint256 totalAssets, uint256 totalSupply) internal view returns (uint256) {
        if (totalSupply == 0) return 0;
        // Use same formula as _convertToAssets: (1 share) * (totalAssets + 1) / (totalSupply + 10^decimalsOffset)
        return (10 ** IVaultFacet(facet).decimals()).mulDiv(totalAssets + 1, totalSupply + 10 ** decimalsOffset, Math.Rounding.Floor);
    }

    /**
     * @notice Helper function to get current HWMpS
     */
    function _getHWMpS(address userAddress) internal view returns (uint256) {
        return MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(facet, userAddress);
    }

    /**
     * @notice Test that HWMpS is set to current price per share on first deposit
     */
    function test_updateUserHWMpS_FirstDeposit_SetsHWMpSToCurrentPrice() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        uint256 depositAmount = 1000 ether;
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 totalAssets = IVaultFacet(facet).totalAssets();
        uint256 totalSupply = IERC20(facet).totalSupply();
        uint256 expectedPricePerShare = _calculatePricePerShare(totalAssets, totalSupply);

        uint256 userHWMpS = _getHWMpS(user);
        assertEq(userHWMpS, expectedPricePerShare, "HWMpS should equal current price per share");
    }

    /**
     * @notice Test that HWMpS increases when price per share increases
     */
    function test_updateUserHWMpS_PriceIncrease_UpdatesHWMpS() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);

        // Simulate price increase by minting more assets to vault (simulating yield)
        MockERC20(asset).mint(facet, 100 ether);

        // Another deposit should update HWMpS
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 newTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 newTotalSupply = IERC20(facet).totalSupply();
        uint256 newPricePerShare = _calculatePricePerShare(newTotalAssets, newTotalSupply);

        uint256 finalHWMpS = _getHWMpS(user);
        assertGt(finalHWMpS, initialHWMpS, "HWMpS should increase");
        assertEq(finalHWMpS, newPricePerShare, "HWMpS should equal new price per share");
    }

    /**
     * @notice Test that HWMpS is reset to 0 when user balance becomes 0
     */
    function test_updateUserHWMpS_ZeroBalance_ResetsHWMpSToZero() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 hwmBefore = _getHWMpS(user);
        assertGt(hwmBefore, 0, "HWMpS should be set");

        // Withdraw all
        uint256 shares = IERC20(facet).balanceOf(user);
        vm.prank(user);
        IVaultFacet(facet).redeem(shares, user, user);

        uint256 hwmAfter = _getHWMpS(user);
        assertEq(hwmAfter, 0, "HWMpS should be reset to 0");
    }

    /**
     * @notice Test that new receiver gets sender's HWMpS when receiving tokens
     */
    function test_update_NewReceiver_GetsSenderHWMpS() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup user1
        vm.prank(user);
        IERC20(asset).approve(facet, type(uint256).max);

        // User1 deposits
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 senderHWMpS = _getHWMpS(user);

        // Transfer to user2 (who has no tokens)
        vm.startPrank(user);
        IERC20(facet).transfer(user2, IERC20(facet).balanceOf(user) / 2);
        vm.stopPrank();

        uint256 receiverHWMpS = _getHWMpS(user2);
        assertEq(receiverHWMpS, senderHWMpS, "Receiver should get sender's HWMpS");
    }

    /**
     * @notice Test weighted average HWMpS calculation when receiver already has tokens
     */
    function test_update_ExistingReceiver_CalculatesWeightedAverage() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup user2
        MockERC20(asset).mint(user2, 10000 ether);
        vm.prank(user2);
        IERC20(asset).approve(facet, type(uint256).max);

        // User1 deposits
        uint256 depositAmount1 = 1000 ether;
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount1, user);
        uint256 user1HWMpS = _getHWMpS(user);

        // User2 deposits
        uint256 depositAmount2 = 1000 ether;
        vm.prank(user2);
        IVaultFacet(facet).deposit(depositAmount2, user2);
        uint256 user2HWMpS = _getHWMpS(user2);

        // Get balances before transfer
        uint256 user2BalanceBefore = IERC20(facet).balanceOf(user2);
        uint256 transferShares = IERC20(facet).balanceOf(user) / 2;

        // Transfer from user1 to user2
        vm.prank(user);
        IERC20(facet).transfer(user2, transferShares);

        // Calculate expected weighted average
        uint256 user2BalanceAfter = IERC20(facet).balanceOf(user2);
        uint256 expectedHWMpS = (user2BalanceBefore * user2HWMpS + transferShares * user1HWMpS) / user2BalanceAfter;

        uint256 finalHWMpS = _getHWMpS(user2);
        assertEq(finalHWMpS, expectedHWMpS, "HWMpS should be weighted average");
    }

    /**
     * @notice Test that HWMpS can decrease when receiving tokens with lower HWMpS
     */
    function test_update_ReceivingLowerHWMpS_CanDecreaseHWMpS() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup user2
        MockERC20(asset).mint(user2, 10000 ether);
        vm.prank(user2);
        IERC20(asset).approve(facet, type(uint256).max);

        // User1 deposits early (gets lower HWMpS)
        uint256 depositAmount1 = 1000 ether;
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount1, user);
        uint256 user1HWMpS = _getHWMpS(user);

        // Simulate price increase
        MockERC20(asset).mint(facet, 100 ether);

        // User2 deposits later (gets higher HWMpS)
        uint256 depositAmount2 = 1000 ether;
        vm.prank(user2);
        IVaultFacet(facet).deposit(depositAmount2, user2);
        uint256 user2HWMpS = _getHWMpS(user2);

        assertGt(user2HWMpS, user1HWMpS, "User2 should have higher HWMpS");

        // Transfer from user1 (lower HWMpS) to user2 (higher HWMpS)
        uint256 user2BalanceBefore = IERC20(facet).balanceOf(user2);
        uint256 transferShares = IERC20(facet).balanceOf(user) / 2;

        vm.prank(user);
        IERC20(facet).transfer(user2, transferShares);

        uint256 finalHWMpS = _getHWMpS(user2);
        assertLt(finalHWMpS, user2HWMpS, "HWMpS should decrease");
        assertGt(finalHWMpS, user1HWMpS, "HWMpS should be between sender and receiver");
    }

    /**
     * @notice Test that sender's HWMpS is reset to 0 when balance becomes 0
     */
    function test_update_SenderBalanceZero_ResetsHWMpSToZero() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup user2
        MockERC20(asset).mint(user2, 10000 ether);
        vm.prank(user2);
        IERC20(asset).approve(facet, type(uint256).max);

        // User1 deposits
        uint256 depositAmount = 1000 ether;
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 hwmBefore = _getHWMpS(user);
        assertGt(hwmBefore, 0, "HWMpS should be set");

        // Transfer all tokens
        uint256 balance = IERC20(facet).balanceOf(user);
        vm.prank(user);
        IERC20(facet).transfer(user2, balance);

        uint256 hwmAfter = _getHWMpS(user);
        assertEq(hwmAfter, 0, "HWMpS should be reset to 0");
    }

    /**
     * @notice Test that HWMpS updates correctly after fee accrual
     */
    function test_updateUserHWMpS_AfterFeeAccrual_UpdatesCorrectly() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();

        // Simulate yield by minting assets to vault
        MockERC20(asset).mint(facet, 100 ether);

        // Another deposit should accrue fees and update HWMpS
        vm.prank(user);
        uint256 newShares = IVaultFacet(facet).deposit(depositAmount, user);

        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);

        uint256 finalHWMpS = _getHWMpS(user);

        // Verify fee shares were minted (totalSupply increased more than just deposit)
        assertGt(finalTotalSupply, initialTotalSupply + newShares, "Fee shares should be minted");
        
        // HWMpS should equal current price per share
        assertEq(finalHWMpS, finalPricePerShare, "HWMpS should equal current price per share after fee accrual");
    }

    /**
     * @notice Test that _accruedFeeSharesPerUser returns 0 when userHWMpS is 0
     * @dev For fee recipients HWMpS won't be set automatically, if HWMpS is 0, no fee is accrued
     * This test verifies that even when a user (fee recipient) has shares and currentPricePerShare > 0,
     * if userHWMpS == 0, the function returns 0 fee shares
     */
    function test_accruedFeeSharesPerUser_UserHWMpSZero_ReturnsZero() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit by user
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Simulate yield by minting assets to vault (price increases)
        MockERC20(asset).mint(facet, 100 ether);

        // Another deposit should accrue fees and mint shares to fee recipient
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Verify fee recipient received shares
        uint256 feeRecipientShares = IERC20(facet).balanceOf(feeRecipient);
        assertGt(feeRecipientShares, 0, "Fee recipient should have shares");

        // Verify fee recipient's HWMpS is 0 (not set automatically for fee recipients)
        uint256 feeRecipientHWMpS = _getHWMpS(feeRecipient);
        assertEq(feeRecipientHWMpS, 0, "Fee recipient HWMpS should be 0");

        // Get current state
        uint256 totalAssets = IVaultFacet(facet).totalAssets();
        uint256 totalSupply = IERC20(facet).totalSupply();
        uint256 currentPricePerShare = _calculatePricePerShare(totalAssets, totalSupply);

        // Verify current price per share is greater than 0
        assertGt(currentPricePerShare, 0, "Current price per share should be greater than 0");

        // Simulate further price increase to ensure currentPricePerShare > userHWMpS (which is 0)
        MockERC20(asset).mint(facet, 50 ether);
        uint256 newTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 newPricePerShare = _calculatePricePerShare(newTotalAssets, totalSupply);

        // Verify new price per share is greater than 0 (and greater than userHWMpS which is 0)
        assertGt(newPricePerShare, 0, "New price per share should be greater than 0");
        assertGt(newPricePerShare, feeRecipientHWMpS, "New price per share should be greater than userHWMpS (0)");

        // When fee recipient calls previewDeposit, _accruedFeeSharesPerUser is called internally
        // Since fee recipient has HWMpS == 0, _accruedFeeSharesPerUser should return 0
        // This means simTotalSupply in _getPreviewData should equal totalSupply (no fee shares added)
        vm.prank(feeRecipient);
        uint256 previewShares = IVaultFacet(facet).previewDeposit(100 ether);

        // Calculate expected shares: since _accruedFeeSharesPerUser returns 0 for fee recipient,
        // simTotalSupply = totalSupply (no fee shares added), so:
        // shares = (assets * (totalSupply + 10^decimalsOffset)) / (totalAssets + 1)
        uint256 decimalsOffset = 2;
        uint256 expectedShares = (100 ether * (totalSupply + 10 ** decimalsOffset)) / (newTotalAssets + 1);

        // Verify preview returns expected shares (no fee accrual for fee recipient with HWMpS == 0)
        assertEq(previewShares, expectedShares, "Preview should not include fee shares for fee recipient with HWMpS == 0");
    }

    // ============ Tests for accrueFees function ============

    /**
     * @notice Test that accrueFees correctly accrues fees and updates HWMpS with protocol fee
     */
    function test_accrueFees_WithProtocolFee_AccruesFeesAndUpdatesHWMpS() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(protocolFeeRecipient, protocolFee));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();
        uint256 initialProtocolFeeBalance = IERC20(facet).balanceOf(protocolFeeRecipient);
        uint256 initialVaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Simulate yield by minting assets to vault (price increases)
        MockERC20(asset).mint(facet, 100 ether);

        // Call accrueFees
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        // Verify fees were distributed
        uint256 protocolFeeBalance = IERC20(facet).balanceOf(protocolFeeRecipient);
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        uint256 totalFeeShares = protocolFeeBalance + vaultFeeBalance;

        assertGt(protocolFeeBalance, initialProtocolFeeBalance, "Should distribute protocol fee");
        assertGt(vaultFeeBalance, initialVaultFeeBalance, "Should distribute vault fee");
        assertGt(totalFeeShares, 0, "Should mint fee shares");

        // Verify HWMpS was updated
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);
        uint256 finalHWMpS = _getHWMpS(user);

        assertGt(finalHWMpS, initialHWMpS, "HWMpS should increase");
        assertEq(finalHWMpS, finalPricePerShare, "HWMpS should equal current price per share");

        // Verify total supply increased by fee shares
        assertEq(finalTotalSupply, initialTotalSupply + totalFeeShares, "Total supply should increase by fee shares");
    }

    /**
     * @notice Test that accrueFees correctly accrues fees and updates HWMpS without protocol fee
     */
    function test_accrueFees_WithoutProtocolFee_AccruesFeesAndUpdatesHWMpS() public {
        // Mock protocol fee info (no protocol fee)
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();
        uint256 initialVaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Simulate yield by minting assets to vault (price increases)
        MockERC20(asset).mint(facet, 100 ether);

        // Call accrueFees
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        // Verify fees were distributed
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        assertGt(vaultFeeBalance, initialVaultFeeBalance, "Should distribute vault fee");

        // Verify HWMpS was updated
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);
        uint256 finalHWMpS = _getHWMpS(user);

        assertGt(finalHWMpS, initialHWMpS, "HWMpS should increase");
        assertEq(finalHWMpS, finalPricePerShare, "HWMpS should equal current price per share");

        // Verify total supply increased by fee shares
        assertEq(finalTotalSupply, initialTotalSupply + vaultFeeBalance, "Total supply should increase by fee shares");
    }

    /**
     * @notice Test that accrueFees does not accrue fees when price hasn't increased
     */
    function test_accrueFees_NoPriceIncrease_NoFeesAccrued() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();
        uint256 initialVaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Don't add any yield - price stays the same

        // Call accrueFees
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        // Verify no fees were distributed
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        assertEq(vaultFeeBalance, initialVaultFeeBalance, "Should not distribute fees when price hasn't increased");

        // Verify HWMpS hasn't changed (should remain the same since price didn't increase)
        uint256 finalHWMpS = _getHWMpS(user);
        assertEq(finalHWMpS, initialHWMpS, "HWMpS should remain the same");

        // Verify total supply hasn't changed
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        assertEq(finalTotalSupply, initialTotalSupply, "Total supply should not change");
    }

    /**
     * @notice Test that accrueFees does not accrue fees when fee is set to 0
     */
    function test_accrueFees_ZeroFee_NoFeesAccrued() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Set fee to 0
        MoreVaultsStorageHelper.setFee(facet, 0);

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        uint256 initialHWMpS = _getHWMpS(user);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();
        uint256 initialVaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Simulate yield by minting assets to vault (price increases)
        MockERC20(asset).mint(facet, 100 ether);

        // Call accrueFees
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        // Verify no fees were distributed
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        assertEq(vaultFeeBalance, initialVaultFeeBalance, "Should not distribute fees when fee is 0");

        // Verify HWMpS was still updated (even without fees)
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);
        uint256 finalHWMpS = _getHWMpS(user);

        assertGt(finalHWMpS, initialHWMpS, "HWMpS should still increase");
        assertEq(finalHWMpS, finalPricePerShare, "HWMpS should equal current price per share");

        // Verify total supply hasn't changed (no fee shares minted)
        assertEq(finalTotalSupply, initialTotalSupply, "Total supply should not change");
    }

    /**
     * @notice Test that accrueFees resets HWMpS to 0 when user balance is 0
     */
    function test_accrueFees_ZeroBalance_ResetsHWMpSToZero() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Verify HWMpS is set
        uint256 hwmBefore = _getHWMpS(user);
        assertGt(hwmBefore, 0, "HWMpS should be set");

        // Withdraw all shares
        uint256 shares = IERC20(facet).balanceOf(user);
        vm.prank(user);
        IVaultFacet(facet).redeem(shares, user, user);

        // Verify balance is 0
        assertEq(IERC20(facet).balanceOf(user), 0, "User balance should be 0");

        // Call accrueFees
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        // Verify HWMpS is reset to 0
        uint256 hwmAfter = _getHWMpS(user);
        assertEq(hwmAfter, 0, "HWMpS should be reset to 0 when balance is 0");
    }

    /**
     * @notice Test that accrueFees works correctly for different users
     */
    function test_accrueFees_DifferentUsers_AccruesFeesIndependently() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup user2
        MockERC20(asset).mint(user2, 10000 ether);
        vm.prank(user2);
        IERC20(asset).approve(facet, type(uint256).max);

        // User1 deposits
        uint256 depositAmount1 = 1000 ether;
        MockERC20(asset).mint(user, depositAmount1);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount1, user);

        // User2 deposits
        uint256 depositAmount2 = 1000 ether;
        vm.prank(user2);
        IVaultFacet(facet).deposit(depositAmount2, user2);

        uint256 user1HWMpSBefore = _getHWMpS(user);
        uint256 user2HWMpSBefore = _getHWMpS(user2);
        uint256 initialTotalSupply = IERC20(facet).totalSupply();
        uint256 initialVaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);

        // Simulate yield by minting assets to vault (price increases)
        MockERC20(asset).mint(facet, 100 ether);

        // Call accrueFees for user1
        vm.prank(user);
        IVaultFacet(facet).accrueFees(user);

        uint256 vaultFeeBalanceAfterUser1 = IERC20(facet).balanceOf(feeRecipient);
        assertGt(vaultFeeBalanceAfterUser1, initialVaultFeeBalance, "Should accrue fees for user1");

        uint256 user1HWMpSAfter = _getHWMpS(user);
        assertGt(user1HWMpSAfter, user1HWMpSBefore, "User1 HWMpS should increase");

        // Call accrueFees for user2
        vm.prank(user2);
        IVaultFacet(facet).accrueFees(user2);

        uint256 vaultFeeBalanceAfterUser2 = IERC20(facet).balanceOf(feeRecipient);
        assertGt(vaultFeeBalanceAfterUser2, vaultFeeBalanceAfterUser1, "Should accrue additional fees for user2");

        uint256 user2HWMpSAfter = _getHWMpS(user2);
        assertGt(user2HWMpSAfter, user2HWMpSBefore, "User2 HWMpS should increase");

        // Verify both users' HWMpS are updated correctly
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);

        assertGt(user1HWMpSAfter, finalPricePerShare, "User1 HWMpS should be greater than current price per share");
        assertEq(user2HWMpSAfter, finalPricePerShare, "User2 HWMpS should equal current price");
    }

    /**
     * @notice Test that accrueFees can be called by anyone (public function)
     */
    function test_accrueFees_CanBeCalledByAnyone() public {
        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Initial deposit
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(user, depositAmount);
        vm.prank(user);
        IVaultFacet(facet).deposit(depositAmount, user);

        // Simulate yield
        MockERC20(asset).mint(facet, 100 ether);

        // Call accrueFees from a different address (not the user)
        vm.prank(user2);
        IVaultFacet(facet).accrueFees(user);

        // Verify fees were accrued
        uint256 vaultFeeBalance = IERC20(facet).balanceOf(feeRecipient);
        assertGt(vaultFeeBalance, 0, "Should accrue fees even when called by different address");

        // Verify HWMpS was updated
        uint256 finalTotalAssets = IVaultFacet(facet).totalAssets();
        uint256 finalTotalSupply = IERC20(facet).totalSupply();
        uint256 finalPricePerShare = _calculatePricePerShare(finalTotalAssets, finalTotalSupply);
        uint256 finalHWMpS = _getHWMpS(user);

        assertEq(finalHWMpS, finalPricePerShare, "HWMpS should be updated");
    }

    /**
     * @notice Test requestRedeem with onBehalfOf when caller has allowance
     */
    function test_requestRedeem_OnBehalfOf_WithAllowance() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 13 days);

        address spender = address(0x1234);
        address owner = user;

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, shares);

        // Request redeem on behalf of owner
        uint256 requestShares = shares / 2;
        vm.prank(spender);
        VaultFacet(facet).requestRedeem(requestShares, owner);

        // Verify request was created
        (uint256 requestShares_, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(owner);
        assertEq(requestShares_, requestShares, "Should create request with correct shares");
        assertGt(timelockEndsAt, block.timestamp, "Should set timelock");
    }

    /**
     * @notice Test requestRedeem with onBehalfOf when caller doesn't have allowance
     */
    function test_requestRedeem_OnBehalfOf_WithoutAllowance() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

        address spender = address(0x1234);
        address owner = user;

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Don't approve spender - should revert
        uint256 requestShares = shares / 2;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, requestShares));
        VaultFacet(facet).requestRedeem(requestShares, owner);
    }

    /**
     * @notice Test requestRedeem with onBehalfOf when caller is the owner (no allowance needed)
     */
    function test_requestRedeem_OnBehalfOf_Self() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 13 days);

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

        // Request redeem for self (no allowance needed)
        uint256 requestShares = shares / 2;
        vm.prank(user);
        VaultFacet(facet).requestRedeem(requestShares, user);

        // Verify request was created
        (uint256 requestShares_, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(user);
        assertEq(requestShares_, requestShares, "Should create request with correct shares");
        assertGt(timelockEndsAt, block.timestamp, "Should set timelock");
    }

    /**
     * @notice Test requestWithdraw with onBehalfOf when caller has allowance
     */
    function test_requestWithdraw_OnBehalfOf_WithAllowance() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 13 days);

        address spender = address(0x1234);
        address owner = user;

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, shares);

        // Request withdraw on behalf of owner
        uint256 requestAssets = depositAmount / 2;
        vm.prank(spender);
        VaultFacet(facet).requestWithdraw(requestAssets, owner);

        // Verify request was created
        (uint256 requestShares, uint256 timelockEndsAt) = VaultFacet(facet).getWithdrawalRequest(owner);
        assertGt(requestShares, 0, "Should create request with shares");
        assertGt(timelockEndsAt, block.timestamp, "Should set timelock");
    }

    /**
     * @notice Test requestWithdraw with onBehalfOf when caller doesn't have allowance
     */
    function test_requestWithdraw_OnBehalfOf_WithoutAllowance() public {
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

        address spender = address(0x1234);
        address owner = user;

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Don't approve spender - should revert
        uint256 requestAssets = depositAmount / 2;
        vm.prank(spender);
        // Will revert because shares calculation happens before allowance check, but allowance check will fail
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, requestAssets * 1e2));
        VaultFacet(facet).requestWithdraw(requestAssets, owner);
    }

    /**
     * @notice Test deposit through router - deposit cap should be updated for receiver, not router
     */
    function test_deposit_ThroughRouter_UpdatesDepositCapForReceiver() public {
        address routerAddress = address(0x020202);
        address receiver = user;

        // Set router in registry
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(routerAddress));

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, receiver, 10_000 ether);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(routerAddress, depositAmount);

        // Deposit through router
        vm.startPrank(routerAddress);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, receiver);
        vm.stopPrank();

        // Check that deposit cap was updated for receiver, not router
        uint256 receiverCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, receiver);
        uint256 routerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, routerAddress);

        assertLt(receiverCap, 10_000 ether, "Receiver cap should be decreased");
        assertEq(routerCap, 0, "Router cap should not be changed");
        assertEq(receiverCap, 10_000 ether - depositAmount, "Receiver cap should be decreased by deposit amount");
    }

    /**
     * @notice Test mint through router - deposit cap should be updated for receiver, not router
     */
    function test_mint_ThroughRouter_UpdatesDepositCapForReceiver() public {
        address routerAddress = address(0x020202);
        address receiver = user;

        // Set router in registry
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(routerAddress));

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, receiver, 10_000 ether);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        uint256 sharesToMint = 1000 ether;
        uint256 depositAmount = VaultFacet(facet).previewMint(sharesToMint);
        MockERC20(asset).mint(routerAddress, depositAmount);

        // Mint through router
        vm.startPrank(routerAddress);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).mint(sharesToMint, receiver);
        vm.stopPrank();

        // Check that deposit cap was updated for receiver, not router
        uint256 receiverCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, receiver);
        uint256 routerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, routerAddress);

        assertEq(receiverCap, 10_000 ether - depositAmount, "Receiver cap should be decreased");
        assertEq(routerCap, 0, "Router cap should not be changed");
    }

    /**
     * @notice Test deposit with multiple tokens through router
     */
    function test_deposit_MultipleTokens_ThroughRouter() public {
        address routerAddress = address(0x020202);
        address receiver = user;

        // Set router in registry
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(routerAddress));

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, receiver, 10_000 ether);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 ether;

        MockERC20(asset).mint(routerAddress, amounts[0]);

        // Deposit through router
        vm.startPrank(routerAddress);
        IERC20(asset).approve(facet, amounts[0]);
        VaultFacet(facet).deposit(tokens, amounts, receiver, 0);
        vm.stopPrank();

        // Check that deposit cap was updated for receiver
        uint256 receiverCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, receiver);
        assertLt(receiverCap, 10_000 ether, "Receiver cap should be decreased");
    }

    /**
     * @notice Test withdraw through router - deposit cap should be updated for owner, not router
     */
    function test_withdraw_ThroughRouter_UpdatesDepositCapForOwner() public {
        address routerAddress = address(0x020202);
        address owner = user;
        address receiver = owner;

        // Set router in registry
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(routerAddress));

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Setup withdrawal queue
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, owner);

        // Check that deposit cap was updated for owner (because router -> receiver mapping), not router
        uint256 ownerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 routerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, routerAddress);

        assertEq(ownerCap, 10_000 ether - depositAmount, "Owner cap should be decreased by deposit amount");
        assertEq(routerCap, 0, "Router cap should not be changed");
        vm.stopPrank();

        // Withdraw through router (router calls withdraw, receiver is owner)
        uint256 withdrawAmount = 500 ether;
        vm.prank(owner);
        VaultFacet(facet).requestWithdraw(withdrawAmount, owner);
        vm.warp(block.timestamp + 1 days + 1);

        vm.startPrank(owner);
        VaultFacet(facet).approve(routerAddress, VaultFacet(facet).convertToShares(withdrawAmount));
        vm.stopPrank();
        vm.prank(routerAddress);
        VaultFacet(facet).withdraw(withdrawAmount, receiver, owner);

        // Check that deposit cap was updated for owner (because router -> receiver mapping), not router
        ownerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        routerCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, routerAddress);

        assertEq(ownerCap, 10_000 ether - depositAmount + withdrawAmount, "Owner cap should be increased by withdraw amount");
        assertEq(routerCap, 0, "Router cap should not be changed");
    }

    /**
     * @notice Test withdraw through spender with allowance - deposit cap should be updated for owner, not spender
     */
    function test_withdraw_ThroughSpender_UpdatesDepositCapForOwner() public {
        address spender = address(0x1234);
        address owner = user;
        address receiver = owner;

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Setup withdrawal queue
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Check initial cap
        uint256 ownerCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        assertEq(ownerCapBefore, 10_000 ether - depositAmount, "Owner cap should be decreased after deposit");

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, type(uint256).max);

        // Create withdrawal request
        uint256 withdrawAmount = 500 ether;
        vm.prank(owner);
        VaultFacet(facet).requestWithdraw(withdrawAmount, owner);
        vm.warp(block.timestamp + 1 days + 1);

        // Withdraw through spender
        vm.prank(spender);
        VaultFacet(facet).withdraw(withdrawAmount, receiver, owner);

        // Check that deposit cap was updated for owner, not spender
        uint256 ownerCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 spenderCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, spender);

        assertEq(ownerCapAfter, 10_000 ether - depositAmount + withdrawAmount, "Owner cap should be increased by withdraw amount");
        assertEq(spenderCap, 0, "Spender cap should not be changed");
    }

    /**
     * @notice Test redeem through spender with allowance - deposit cap should be updated for owner, not spender
     */
    function test_redeem_ThroughSpender_UpdatesDepositCapForOwner() public {
        address spender = address(0x1234);
        address owner = user;
        address receiver = owner;

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Setup withdrawal queue
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Check initial cap
        uint256 ownerCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        assertEq(ownerCapBefore, 10_000 ether - depositAmount, "Owner cap should be decreased after deposit");

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, type(uint256).max);

        // Create withdrawal request
        uint256 redeemShares = shares / 2;
        vm.prank(owner);
        VaultFacet(facet).requestRedeem(redeemShares, owner);
        vm.warp(block.timestamp + 1 days + 1);

        // Redeem through spender
        vm.prank(spender);
        uint256 assets = VaultFacet(facet).redeem(redeemShares, receiver, owner);

        // Check that deposit cap was updated for owner, not spender
        uint256 ownerCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 spenderCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, spender);

        assertEq(ownerCapAfter, 10_000 ether - depositAmount + assets, "Owner cap should be increased by redeem assets");
        assertEq(spenderCap, 0, "Spender cap should not be changed");
    }

    /**
     * @notice Test withdraw through spender with allowance when withdrawal queue is disabled
     * @dev When queue is disabled, withdrawFromRequest returns true (synchronous withdrawal)
     * Spender with allowance can withdraw on behalf of owner without request
     * This test verifies that deposit cap updates for owner, not spender
     */
    function test_withdraw_ThroughSpender_WithoutQueue_UpdatesDepositCapForOwner() public {
        address spender = address(0x1234);
        address owner = user;
        address receiver = owner;

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Disable withdrawal queue (allows synchronous withdrawal)
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Check initial cap
        uint256 ownerCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        assertEq(ownerCapBefore, 10_000 ether - depositAmount, "Owner cap should be decreased after deposit");

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, type(uint256).max);

        // Withdraw through spender (synchronous, no request needed when queue is disabled)
        uint256 withdrawAmount = 500 ether;
        vm.prank(spender);
        VaultFacet(facet).withdraw(withdrawAmount, receiver, owner);

        // Check that deposit cap was updated for owner, not spender
        uint256 ownerCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 spenderCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, spender);

        assertEq(ownerCapAfter, 10_000 ether - depositAmount + withdrawAmount, "Owner cap should be increased by withdraw amount");
        assertEq(spenderCap, 0, "Spender cap should not be changed");
    }

    /**
     * @notice Test redeem through spender with allowance when withdrawal queue is disabled
     * @dev When queue is disabled, withdrawFromRequest returns true (synchronous withdrawal)
     * Spender with allowance can redeem on behalf of owner without request
     * This test verifies that deposit cap updates for owner, not spender
     */
    function test_redeem_ThroughSpender_WithoutQueue_UpdatesDepositCapForOwner() public {
        address spender = address(0x1234);
        address owner = user;
        address receiver = owner;

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Disable withdrawal queue (allows synchronous withdrawal)
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        uint256 shares = VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Check initial cap
        uint256 ownerCapBefore = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        assertEq(ownerCapBefore, 10_000 ether - depositAmount, "Owner cap should be decreased after deposit");

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, type(uint256).max);

        // Redeem through spender (synchronous, no request needed when queue is disabled)
        uint256 redeemShares = shares / 2;
        vm.prank(spender);
        uint256 assets = VaultFacet(facet).redeem(redeemShares, receiver, owner);

        // Check that deposit cap was updated for owner, not spender
        uint256 ownerCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 spenderCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, spender);

        assertEq(ownerCapAfter, 10_000 ether - depositAmount + assets, "Owner cap should be increased by redeem assets");
        assertEq(spenderCap, 0, "Spender cap should not be changed");
    }

    /**
     * @notice Test withdraw through spender with different receiver - deposit cap should still be updated for owner
     */
    function test_withdraw_ThroughSpender_DifferentReceiver_UpdatesDepositCapForOwner() public {
        address spender = address(0x1234);
        address owner = user;
        address receiver = address(0x5678); // Different receiver

        // Enable whitelist
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, owner, 10_000 ether);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, owner, 10_000 ether);

        // Setup withdrawal queue
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, true);
        MoreVaultsStorageHelper.setMaxWithdrawalDelay(facet, 14 days);
        MoreVaultsStorageHelper.setWithdrawTimelock(facet, 1 days);

        // Mock protocol fee info
        vm.mockCall(registry, abi.encodeWithSignature("protocolFeeInfo(address)"), abi.encode(address(0), 0));
        uint32[] memory eids = new uint32[](0);
        address[] memory vaults = new address[](0);
        vm.mockCall(factory, abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector), abi.encode(eids, vaults));

        // Deposit first
        uint256 depositAmount = 1000 ether;
        MockERC20(asset).mint(owner, depositAmount);
        vm.startPrank(owner);
        IERC20(asset).approve(facet, depositAmount);
        VaultFacet(facet).deposit(depositAmount, owner);
        vm.stopPrank();

        // Approve spender
        vm.prank(owner);
        IERC20(facet).approve(spender, type(uint256).max);

        // Create withdrawal request
        uint256 withdrawAmount = 500 ether;
        vm.prank(owner);
        VaultFacet(facet).requestWithdraw(withdrawAmount, owner);
        vm.warp(block.timestamp + 1 days + 1);

        // Withdraw through spender to different receiver
        vm.prank(spender);
        VaultFacet(facet).withdraw(withdrawAmount, receiver, owner);

        // Check that deposit cap was updated for owner, not spender or receiver
        uint256 ownerCapAfter = MoreVaultsStorageHelper.getAvailableToDeposit(facet, owner);
        uint256 spenderCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, spender);
        uint256 receiverCap = MoreVaultsStorageHelper.getAvailableToDeposit(facet, receiver);

        assertEq(ownerCapAfter, 10_000 ether - depositAmount + withdrawAmount, "Owner cap should be increased by withdraw amount");
        assertEq(spenderCap, 0, "Spender cap should not be changed");
        assertEq(receiverCap, 0, "Receiver cap should not be changed");
    }

    
    /**
     * @notice Test that withdrawal through approve changes deposit cap only for the owner, not the caller
     * @dev When user2 withdraws on behalf of user1 (via approve), deposit cap should change only for user1 (owner)
     */
    function test_handleWithdrawal_WithApprove_ChangesCapOnlyForOwner() public {
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        uint256 initialCap = 100 ether;
        uint256 depositAmount = 50 ether;
        uint256 withdrawAmount = 20 ether;

        // Enable deposit whitelist and set cap for user1
        MoreVaultsStorageHelper.setIsWhitelistEnabled(facet, true);
        MoreVaultsStorageHelper.setDepositWhitelist(facet, user1, initialCap);
        MoreVaultsStorageHelper.setInitialDepositCapPerUser(facet, user1, initialCap);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(facet, false); // Disable withdrawal queue for direct withdraw

        // Setup mocks
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

        // User1 deposits
        MockERC20(asset).mint(user1, depositAmount);
        vm.prank(user1);
        IERC20(asset).approve(facet, type(uint256).max);
        vm.prank(user1);
        VaultFacet(facet).deposit(depositAmount, user1);

        // Check that user1's cap decreased after deposit
        uint256 user1CapAfterDeposit = MoreVaultsStorageHelper.getAvailableToDeposit(facet, user1);
        assertEq(
            user1CapAfterDeposit,
            initialCap - depositAmount,
            "User1's cap should be decreased after deposit"
        );

        // User1 approves user2 to withdraw on their behalf
        vm.prank(user1);
        IERC20(facet).approve(user2, type(uint256).max);

        // User2 withdraws on behalf of user1
        vm.prank(user2);
        VaultFacet(facet).withdraw(withdrawAmount, user2, user1);

        // Check that only user1's cap changed (increased), not user2's
        uint256 user1CapAfterWithdraw = MoreVaultsStorageHelper.getAvailableToDeposit(facet, user1);
        uint256 user2CapAfterWithdraw = MoreVaultsStorageHelper.getAvailableToDeposit(facet, user2);

        // User1's cap should be increased by withdrawAmount
        uint256 expectedUser1Cap = user1CapAfterDeposit + withdrawAmount;
        assertEq(
            user1CapAfterWithdraw,
            expectedUser1Cap,
            "User1's cap should be increased by withdrawAmount"
        );
        assertLe(
            user1CapAfterWithdraw,
            initialCap,
            "User1's cap should not exceed initialDepositCapPerUser"
        );

        // User2's cap should remain 0 (not set)
        assertEq(
            user2CapAfterWithdraw,
            0,
            "User2's cap should not change (should remain 0 as user2 never deposited)"
        );
    }
}
