// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC7540Facet} from "../../../src/facets/ERC7540Facet.sol";
import {IERC7540Facet} from "../../../src/interfaces/facets/IERC7540Facet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockERC7540Vault is ERC4626 {
    mapping(uint256 => bool) public requests;
    uint256 public requestIdCounter;

    constructor(address _asset) ERC4626(IERC20(_asset)) ERC20("MockERC7540Vault", "MKV") {
        requestIdCounter = 1;
    }

    function mintShares(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function requestDeposit(uint256 assets, address, address) external returns (uint256) {
        require(assets > 0, "Zero assets");
        IERC20(asset()).transferFrom(msg.sender, address(this), assets);
        return requestIdCounter++;
    }

    function requestRedeem(uint256 sharesToRedeem, address, address) external returns (uint256) {
        require(sharesToRedeem > 0, "Zero shares");
        transfer(address(this), sharesToRedeem);
        return requestIdCounter++;
    }

    function deposit(uint256 assets, address receiver, address) external returns (uint256) {
        require(assets > 0, "Zero assets");
        return super.deposit(assets, receiver);
    }

    function mint(uint256 sharesToMint, address receiver, address) external returns (uint256) {
        require(sharesToMint > 0, "Zero shares");

        return super.mint(sharesToMint, receiver);
    }

    function withdraw(uint256 assets, address receiver, address controller) public override returns (uint256) {
        require(assets > 0, "Zero assets");

        return super.withdraw(assets, receiver, controller);
    }

    function redeem(uint256 sharesToRedeem, address receiver, address controller) public override returns (uint256) {
        require(sharesToRedeem > 0, "Zero shares");

        return super.redeem(sharesToRedeem, receiver, controller);
    }

    function convertToAssets(uint256 shares) public pure override returns (uint256) {
        return shares; // 1:1 ratio for simplicity
    }

    function convertToShares(uint256 assets) public pure override returns (uint256) {
        return assets; // 1:1 ratio for simplicity
    }
}

contract ERC7540FacetTest is Test {
    ERC7540Facet public facet;
    MockERC20 public asset;
    MockERC7540Vault public vault;

    address public owner = address(1);
    address public diamond = address(2);
    address public unauthorized = address(3);
    address public user = address(4);
    address public controller = address(5);
    address public registry = address(6);
    address public oracle = address(7);

    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant DEPOSIT_AMOUNT = 100e18;
    uint256 public constant MINT_SHARES = 50e18;

    // Storage slot for AccessControlStorage struct
    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION = AccessControlLib.ACCESS_CONTROL_STORAGE_POSITION;

    // Storage slot for ERC7540 operations
    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    function setUp() public {
        // Deploy facet
        facet = new ERC7540Facet();

        // Deploy mock asset and vault
        asset = new MockERC20("Test Asset", "TST");
        vault = new MockERC7540Vault(address(asset));

        // Set registry
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);
        MoreVaultsStorageHelper.setUnderlyingAsset(address(facet), address(asset));

        // Mock registry calls
        vm.mockCall(address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector), abi.encode(oracle));

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(asset)),
            abi.encode(address(1000), uint96(1000))
        );

        // Initialize facet
        bytes32 facetSelector = bytes4(keccak256(abi.encodePacked("accountingERC7540Facet()")));
        bytes memory initData = abi.encode(facetSelector);
        facet.initialize(initData);

        // Mint initial tokens to facet
        asset.mint(address(facet), INITIAL_BALANCE);
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "ERC7540Facet", "Facet name should be correct");
    }

    function test_facetVersion_ShouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0", "Facet version should be correct");
    }

    function test_initialize_ShouldSetCorrectValues() public view {
        // Test that supported interface is set
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IERC7540Facet).interfaceId),
            "Supported interface should be set"
        );

        bytes32[] memory facetsForAccounting = MoreVaultsStorageHelper.getFacetsForAccounting(address(facet));
        assertTrue(facetsForAccounting.length == 1, "Facets for accounting should be set");
    }

    function test_erc7540RequestDeposit_ShouldCreateRequestSuccessfully() public {
        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );
        facet.erc7540RequestDeposit(address(vault), DEPOSIT_AMOUNT);

        uint256 balanceAfter = asset.balanceOf(address(facet));

        assertEq(balanceAfter, balanceBefore - DEPOSIT_AMOUNT, "Asset balance should decrease");
        assertEq(IERC20(asset).allowance(address(facet), address(vault)), 0, "Allowance should be 0");

        vm.stopPrank();
    }

    function test_erc7540RequestDeposit_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540RequestDeposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540RequestDeposit_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540RequestDeposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540RequestDeposit_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540RequestDeposit(address(vault), 0);
    }

    function test_erc7540RequestRedeem_ShouldCreateRequestSuccessfully() public {
        vm.startPrank(address(facet));

        vault.mintShares(address(facet), MINT_SHARES);

        uint256 sharesBefore = vault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );
        facet.erc7540RequestRedeem(address(vault), MINT_SHARES);

        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(sharesAfter, sharesBefore - MINT_SHARES, "Shares balance should decrease");

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540RequestRedeem(address(vault), MINT_SHARES);
    }

    function test_erc7540RequestRedeem_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540RequestRedeem(address(vault), MINT_SHARES);
    }

    function test_erc7540RequestRedeem_ShouldRevertWhenAmountIsZero() public {
        vm.prank(diamond);

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540RequestRedeem(address(vault), 0);
    }

    function test_erc7540Deposit_ShouldDepositSuccessfully() public {
        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );
        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(shares, DEPOSIT_AMOUNT, "Should return correct shares amount");
        assertEq(balanceAfter, balanceBefore - DEPOSIT_AMOUNT, "Asset balance should decrease");
        assertEq(sharesAfter, sharesBefore + DEPOSIT_AMOUNT, "Shares balance should increase");

        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(address(facet), ERC7540_ID);
        assertTrue(tokensHeld.length == 1, "Vault should be added to tokensHeld");
        assertEq(tokensHeld[0], address(vault), "Vault should be in tokensHeld");

        vm.stopPrank();
    }

    function test_erc7540Deposit_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540Deposit_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540Deposit_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540Deposit(address(vault), 0);
    }

    function test_erc7540Mint_ShouldMintSuccessfully() public {
        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );
        IERC20(asset).approve(address(vault), MINT_SHARES);
        uint256 assets = facet.erc7540Mint(address(vault), MINT_SHARES);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(assets, MINT_SHARES, "Should return correct assets amount");
        assertEq(balanceAfter, balanceBefore - MINT_SHARES, "Asset balance should decrease");
        assertEq(sharesAfter, sharesBefore + MINT_SHARES, "Shares balance should increase");

        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(address(facet), ERC7540_ID);
        assertTrue(tokensHeld.length == 1, "Vault should be added to tokensHeld");
        assertEq(tokensHeld[0], address(vault), "Vault should be in tokensHeld");

        vm.stopPrank();
    }

    function test_erc7540Mint_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540Mint(address(vault), MINT_SHARES);
    }

    function test_erc7540Mint_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540Mint(address(vault), MINT_SHARES);
    }

    function test_erc7540Mint_ShouldRevertWhenAmountIsZero() public {
        vm.prank(diamond);

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540Mint(address(vault), 0);
    }

    function test_erc7540Withdraw_ShouldWithdrawSuccessfully() public {
        vm.startPrank(address(facet));

        vault.mintShares(address(facet), DEPOSIT_AMOUNT);
        MockERC20(asset).mint(address(vault), DEPOSIT_AMOUNT);
        uint256 sharesBefore = vault.balanceOf(address(facet));
        uint256 balanceBefore = asset.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        uint256 shares = facet.erc7540Withdraw(address(vault), DEPOSIT_AMOUNT);

        uint256 sharesAfter = vault.balanceOf(address(facet));
        uint256 balanceAfter = asset.balanceOf(address(facet));

        assertEq(shares, DEPOSIT_AMOUNT, "Should return correct shares amount");
        assertEq(sharesAfter, sharesBefore - DEPOSIT_AMOUNT, "Shares balance should decrease");
        assertEq(balanceAfter, balanceBefore + DEPOSIT_AMOUNT, "Asset balance should increase");

        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(address(facet), ERC7540_ID);
        assertTrue(tokensHeld.length == 0, "Vault should be removed from tokensHeld");

        vm.stopPrank();
    }

    function test_erc7540Withdraw_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540Withdraw(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540Withdraw_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540Withdraw(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc7540Withdraw_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540Withdraw(address(vault), 0);
    }

    function test_erc7540Redeem_ShouldRedeemSuccessfully() public {
        vm.startPrank(address(facet));

        vault.mintShares(address(facet), MINT_SHARES);
        MockERC20(asset).mint(address(vault), MINT_SHARES);
        uint256 sharesBefore = vault.balanceOf(address(facet));
        uint256 balanceBefore = asset.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        uint256 assets = facet.erc7540Redeem(address(vault), MINT_SHARES);

        uint256 sharesAfter = vault.balanceOf(address(facet));
        uint256 balanceAfter = asset.balanceOf(address(facet));

        assertEq(assets, MINT_SHARES, "Should return correct assets amount");
        assertEq(sharesAfter, sharesBefore - MINT_SHARES, "Shares balance should decrease");
        assertEq(balanceAfter, balanceBefore + MINT_SHARES, "Asset balance should increase");

        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(address(facet), ERC7540_ID);
        assertTrue(tokensHeld.length == 0, "Vault should be removed from tokensHeld");

        vm.stopPrank();
    }

    function test_erc7540Redeem_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(abi.encodeWithSelector(AccessControlLib.UnauthorizedAccess.selector, unauthorized));
        facet.erc7540Redeem(address(vault), MINT_SHARES);
    }

    function test_erc7540Redeem_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedProtocol.selector, address(vault)));
        facet.erc7540Redeem(address(vault), MINT_SHARES);
    }

    function test_erc7540Redeem_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(IERC7540Facet.ZeroAmount.selector);
        facet.erc7540Redeem(address(vault), 0);
    }

    function test_accountingERC7540Facet_ShouldReturnCorrectValues() public {
        // First deposit to have shares
        vm.startPrank(address(facet));
        vm.mockCall(
            address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector), abi.encode(true)
        );
        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);

        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        (uint256 sum, bool isPositive) = facet.accountingERC7540Facet();

        assertEq(sum, DEPOSIT_AMOUNT, "Should return correct sum");
        assertTrue(isPositive, "Should return positive");
    }

    function test_accountingERC7540Facet_ShouldNotAccountIfSharesAreAvailableAssets() public {
        vm.startPrank(address(facet));
        vm.mockCall(
            address(registry), abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector), abi.encode(true)
        );

        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), assets);
        (uint256 sum, bool isPositive) = facet.accountingERC7540Facet();

        assertEq(sum, 0, "Should return correct sum");
        assertTrue(isPositive, "Should return positive");
    }

    function test_onFacetRemoval_ShouldCleanupCorrectly() public {
        // Remove facet
        facet.onFacetRemoval(false);

        // Check that supported interface is removed
        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(address(facet), type(IERC7540Facet).interfaceId),
            "Supported interface should be removed"
        );

        bytes32[] memory facets = MoreVaultsStorageHelper.getFacetsForAccounting(address(facet));
        assertTrue(facets.length == 0, "Facets should be removed");
    }
}
