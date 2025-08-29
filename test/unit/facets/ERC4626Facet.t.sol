// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC4626Facet} from "../../../src/facets/ERC4626Facet.sol";
import {IERC4626Facet} from "../../../src/interfaces/facets/IERC4626Facet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IERC4626, IERC20, IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Test Vault", "TV") {}
}

contract MockAsyncERC4626WithLockOnDeposit is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Test Vault", "TV") {}

    function requestDeposit(uint256 assets, address, address) public {
        IERC20(asset()).transferFrom(msg.sender, address(this), assets);
    }

    function depositFinalize(uint256 shares) public {
        _mint(msg.sender, shares);
    }

    function depositCancel(uint256 assets) public {
        IERC20(asset()).transfer(msg.sender, assets);
    }

    function deposit(
        uint256 assets,
        address
    ) public override returns (uint256) {
        IERC20(asset()).transferFrom(msg.sender, address(this), assets);
        return 0;
    }

    function mint(uint256 shares, address) public override returns (uint256) {
        IERC20(asset()).transferFrom(msg.sender, address(this), shares);
        return 0;
    }
}

contract MockAsyncERC4626WithLockOnWithdraw is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Test Vault", "TV") {}

    function mintShares(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function withdraw(
        uint256 shares,
        address,
        address
    ) public override returns (uint256) {
        transfer(address(this), shares);
        return shares;
    }

    function redeem(
        uint256 shares,
        address,
        address
    ) public override returns (uint256) {
        transfer(address(this), shares);
        return shares;
    }

    function requestWithdraw(uint256 shares, address, address) public {
        transfer(address(this), shares);
    }

    function withdrawFinalize(uint256 assets) public {
        MockERC20(asset()).transfer(address(this), msg.sender, assets);
        _burn(address(this), assets);
    }

    function withdrawCancel(uint256 shares) public {
        _transfer(address(this), msg.sender, shares);
    }
}

contract MockAsyncERC4626WithoutLocks is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Test Vault", "TV") {}

    function mintShares(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function requestDeposit(
        uint256 assets,
        address receiver,
        address owner
    ) public {}

    function depositFinalize(uint256 shares) public {
        IERC20(asset()).transferFrom(msg.sender, address(this), shares);
        _mint(msg.sender, shares);
    }

    function depositCancel(uint256 assets) public {}

    function requestWithdraw(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256 assets) {}

    function withdrawFinalize(uint256 assets) public {
        MockERC20(asset()).transfer(address(this), msg.sender, assets);
        _burn(msg.sender, assets);
    }

    function withdrawCancel(uint256 shares) public {}
}

contract MockMaliciousERC4626 is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Test Vault", "TV") {}

    function requestDeposit(uint256 assets, address, address) public {
        _mint(msg.sender, assets);
        MockERC20(asset()).transfer(address(this), msg.sender, assets);
    }
}

contract ERC4626FacetTest is Test {
    ERC4626Facet public facet;
    MockERC20 public asset;
    MockERC4626Vault public vault;

    address public owner = address(1);
    address public diamond = address(2);
    address public unauthorized = address(3);
    address public user = address(4);
    address public registry = address(5);
    address public oracle = address(6);

    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant DEPOSIT_AMOUNT = 100e18;
    uint256 public constant MINT_SHARES = 50e18;

    // Storage slot for AccessControlStorage struct
    bytes32 constant ACCESS_CONTROL_STORAGE_POSITION =
        AccessControlLib.ACCESS_CONTROL_STORAGE_POSITION;

    // Storage slot for ERC4626 operations
    bytes32 constant ERC4626_ID = keccak256("ERC4626_ID");

    function setUp() public {
        // Deploy facet
        facet = new ERC4626Facet();

        // Deploy mock asset and vault
        asset = new MockERC20("Test Asset", "TST");
        vault = new MockERC4626Vault(IERC20(address(asset)));

        // Set owner role
        MoreVaultsStorageHelper.setOwner(address(facet), owner);

        // Set registry
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), registry);
        MoreVaultsStorageHelper.setUnderlyingAsset(
            address(facet),
            address(asset)
        );

        // Mock registry calls
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracle)
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(
                IOracleRegistry.getOracleInfo.selector,
                address(asset)
            ),
            abi.encode(address(1000), uint96(1000))
        );

        // Initialize facet
        bytes32 facetSelector = bytes4(
            keccak256(abi.encodePacked("accountingERC4626Facet()"))
        );
        bytes memory initData = abi.encode(facetSelector);
        facet.initialize(initData);

        // Mint initial tokens to facet
        asset.mint(address(facet), INITIAL_BALANCE);
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(
            facet.facetName(),
            "ERC4626Facet",
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

    function test_initialize_ShouldSetCorrectValues() public view {
        // Test that supported interface is set
        assertTrue(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IERC4626Facet).interfaceId
            ),
            "Supported interface should be set"
        );

        bytes32[] memory facetsForAccounting = MoreVaultsStorageHelper
            .getFacetsForAccounting(address(facet));
        assertTrue(
            facetsForAccounting.length == 1,
            "Facets for accounting should be set"
        );
    }

    function test_erc4626Deposit_ShouldDepositSuccessfully() public {
        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        uint256 shares = facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(shares, DEPOSIT_AMOUNT, "Should return correct shares amount");
        assertEq(
            balanceAfter,
            balanceBefore - DEPOSIT_AMOUNT,
            "Asset balance should decrease"
        );
        assertEq(
            sharesAfter,
            sharesBefore + DEPOSIT_AMOUNT,
            "Shares balance should increase"
        );

        // Check that vault is added to tokensHeld
        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(
            address(facet),
            ERC4626_ID
        );
        assertTrue(
            tokensHeld.length == 1,
            "Vault should be added to tokensHeld"
        );
        assertTrue(
            tokensHeld[0] == address(vault),
            "Vault should be added to tokensHeld"
        );

        vm.stopPrank();
    }

    function test_erc4626Deposit_ShouldRevertWhenAsyncBehaviorDetermined()
        public
    {
        vm.startPrank(address(facet));
        MockAsyncERC4626WithLockOnDeposit newVault = new MockAsyncERC4626WithLockOnDeposit(
                IERC20(address(asset))
            );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.AsyncBehaviorProhibited.selector
            )
        );
        facet.erc4626Deposit(address(newVault), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function test_erc4626Deposit_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(
            abi.encodeWithSelector(
                AccessControlLib.UnauthorizedAccess.selector,
                unauthorized
            )
        );
        facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc4626Deposit_ShouldRevertWhenVaultNotWhitelisted() public {
        vm.prank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(false)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MoreVaultsLib.UnsupportedProtocol.selector,
                address(vault)
            )
        );
        facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);
    }

    function test_erc4626Deposit_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(
            abi.encodeWithSelector(IERC4626Facet.ZeroAmount.selector)
        );
        facet.erc4626Deposit(address(vault), 0);
    }

    function test_erc4626Mint_ShouldMintSuccessfully() public {
        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        uint256 assets = facet.erc4626Mint(address(vault), MINT_SHARES);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(assets, MINT_SHARES, "Should return correct assets amount");
        assertEq(
            balanceAfter,
            balanceBefore - MINT_SHARES,
            "Asset balance should decrease"
        );
        assertEq(
            sharesAfter,
            sharesBefore + MINT_SHARES,
            "Shares balance should increase"
        );

        // Check that vault is added to tokensHeld
        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(
            address(facet),
            ERC4626_ID
        );
        assertTrue(
            tokensHeld.length == 1,
            "Vault should be added to tokensHeld"
        );
        assertTrue(
            tokensHeld[0] == address(vault),
            "Vault should be added to tokensHeld"
        );

        vm.stopPrank();
    }

    function test_erc4626Mint_ShouldRevertWhenAsyncBehaviorDetermined() public {
        vm.startPrank(address(facet));
        MockAsyncERC4626WithLockOnDeposit newVault = new MockAsyncERC4626WithLockOnDeposit(
                IERC20(address(asset))
            );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.AsyncBehaviorProhibited.selector
            )
        );
        facet.erc4626Mint(address(newVault), MINT_SHARES);

        vm.stopPrank();
    }

    function test_erc4626Mint_ShouldRevertWhenCalledByUnauthorized() public {
        vm.prank(unauthorized);

        vm.expectRevert(
            abi.encodeWithSelector(
                AccessControlLib.UnauthorizedAccess.selector,
                unauthorized
            )
        );
        facet.erc4626Mint(address(vault), MINT_SHARES);
    }

    function test_erc4626Mint_ShouldRevertWhenAmountIsZero() public {
        vm.prank(address(facet));

        vm.expectRevert(
            abi.encodeWithSelector(IERC4626Facet.ZeroAmount.selector)
        );
        facet.erc4626Mint(address(vault), 0);
    }

    function test_erc4626Withdraw_ShouldWithdrawSuccessfully() public {
        // First deposit to have shares
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);

        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        uint256 shares = facet.erc4626Withdraw(address(vault), DEPOSIT_AMOUNT);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(shares, DEPOSIT_AMOUNT, "Should return correct shares amount");
        assertEq(
            balanceAfter,
            balanceBefore + DEPOSIT_AMOUNT,
            "User asset balance should increase"
        );
        assertEq(
            sharesAfter,
            sharesBefore - DEPOSIT_AMOUNT,
            "Shares balance should decrease"
        );
        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(
            address(facet),
            ERC4626_ID
        );
        assertTrue(
            tokensHeld.length == 0,
            "Vault should be removed from tokensHeld"
        );

        vm.stopPrank();
    }

    function test_erc4626Withdraw_ShouldRevertWhenAsyncBehaviorDetermined()
        public
    {
        // First deposit to have shares
        vm.prank(address(facet));
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        vm.startPrank(address(facet));
        newVault.mintShares(address(facet), MINT_SHARES);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.AsyncBehaviorProhibited.selector
            )
        );
        facet.erc4626Withdraw(address(newVault), MINT_SHARES);

        vm.stopPrank();
    }

    function test_erc4626Withdraw_ShouldRevertWhenZeroAmount() public {
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        vm.startPrank(address(facet));

        vm.expectRevert(
            abi.encodeWithSelector(IERC4626Facet.ZeroAmount.selector)
        );
        facet.erc4626Withdraw(address(vault), 0);

        vm.stopPrank();
    }

    function test_erc4626Redeem_ShouldRedeemSuccessfully() public {
        // First deposit to have shares
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        facet.erc4626Mint(address(vault), MINT_SHARES);

        vm.startPrank(address(facet));

        uint256 balanceBefore = asset.balanceOf(address(facet));
        uint256 sharesBefore = vault.balanceOf(address(facet));

        uint256 assets = facet.erc4626Redeem(address(vault), MINT_SHARES);

        uint256 balanceAfter = asset.balanceOf(address(facet));
        uint256 sharesAfter = vault.balanceOf(address(facet));

        assertEq(assets, MINT_SHARES, "Should return correct assets amount");
        assertEq(
            balanceAfter,
            balanceBefore + MINT_SHARES,
            "User asset balance should increase"
        );
        assertEq(
            sharesAfter,
            sharesBefore - MINT_SHARES,
            "Shares balance should decrease"
        );

        address[] memory tokensHeld = MoreVaultsStorageHelper.getTokensHeld(
            address(facet),
            ERC4626_ID
        );
        assertTrue(
            tokensHeld.length == 0,
            "Vault should be removed from tokensHeld"
        );

        vm.stopPrank();
    }

    function test_erc4626Redeem_ShouldRevertWhenAsyncBehaviorDetermined()
        public
    {
        // First deposit to have shares
        vm.prank(address(facet));
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        vm.startPrank(address(facet));
        newVault.mintShares(address(facet), MINT_SHARES);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.AsyncBehaviorProhibited.selector
            )
        );
        facet.erc4626Redeem(address(newVault), MINT_SHARES);

        vm.stopPrank();
    }

    function test_erc4626Redeem_ShouldRevertWhenZeroAmount() public {
        // First deposit to have shares
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IERC4626Facet.ZeroAmount.selector)
        );
        facet.erc4626Redeem(address(vault), 0);

        vm.stopPrank();
    }

    function test_accountingERC4626Facet_ShouldReturnCorrectValues() public {
        // First deposit to have shares
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);

        (uint256 sum, bool isPositive) = facet.accountingERC4626Facet();

        assertEq(sum, DEPOSIT_AMOUNT, "Should return correct sum");
        assertTrue(isPositive, "Should return positive");
    }

    function test_accountingERC4626Facet_ShouldNotAccountIfSharesAreAvailableAssets()
        public
    {
        // First deposit to have shares
        vm.prank(address(facet));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector),
            abi.encode(true)
        );

        facet.erc4626Deposit(address(vault), DEPOSIT_AMOUNT);

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), assets);
        (uint256 sum, bool isPositive) = facet.accountingERC4626Facet();

        assertEq(sum, 0, "Should return correct sum");
        assertTrue(isPositive, "Should return positive");
    }

    function test_onFacetRemoval_ShouldCleanupCorrectly() public {
        // First deposit to have shares
        vm.prank(address(facet));

        bytes32[] memory facets = MoreVaultsStorageHelper
            .getFacetsForAccounting(address(facet));

        // Remove facet
        facet.onFacetRemoval(address(facet), false);

        // Check that supported interface is removed
        assertFalse(
            MoreVaultsStorageHelper.getSupportedInterface(
                address(facet),
                type(IERC4626Facet).interfaceId
            ),
            "Supported interface should be removed"
        );
        facets = MoreVaultsStorageHelper.getFacetsForAccounting(address(facet));
        assertTrue(facets.length == 0, "Facets should be removed");
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksOnDeposit()
        public
    {
        MockAsyncERC4626WithLockOnDeposit newVault = new MockAsyncERC4626WithLockOnDeposit(
                IERC20(address(asset))
            );
        // Mock registry to allow selector
        bytes4 selector = MockAsyncERC4626WithLockOnDeposit
            .requestDeposit
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );
        // Execute generic async action

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should increase staked amount"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksFinalizationOfDeposit()
        public
    {
        MockAsyncERC4626WithLockOnDeposit newVault = new MockAsyncERC4626WithLockOnDeposit(
                IERC20(address(asset))
            );
        // Mock registry to allow selector
        bytes4 selector = MockAsyncERC4626WithLockOnDeposit
            .requestDeposit
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );
        // Execute generic async action

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should increase staked amount"
        );

        selector = MockAsyncERC4626WithLockOnDeposit.depositFinalize.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, DEPOSIT_AMOUNT);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            DEPOSIT_AMOUNT,
            "Should be equal to deposit amount"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksCancellationOfDeposit()
        public
    {
        MockAsyncERC4626WithLockOnDeposit newVault = new MockAsyncERC4626WithLockOnDeposit(
                IERC20(address(asset))
            );
        // Mock registry to allow selector
        bytes4 selector = MockAsyncERC4626WithLockOnDeposit
            .requestDeposit
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );
        // Execute generic async action

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should increase staked amount"
        );

        selector = MockAsyncERC4626WithLockOnDeposit.depositCancel.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, DEPOSIT_AMOUNT);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            DEPOSIT_AMOUNT,
            "Should be equal to deposit amount"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksOnWithdraw()
        public
    {
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithLockOnWithdraw
            .requestWithdraw
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );
        newVault.mintShares(address(facet), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be greater than 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksFinalizationOfWithdraw()
        public
    {
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithLockOnWithdraw
            .requestWithdraw
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );
        newVault.mintShares(address(facet), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be greater than 0"
        );

        selector = MockAsyncERC4626WithLockOnWithdraw.withdrawFinalize.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, MINT_SHARES);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            MINT_SHARES,
            "Should be equal to mint shares"
        );

        asset.mint(address(newVault), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithLocksCancellationOfWithdraw()
        public
    {
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithLockOnWithdraw
            .requestWithdraw
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );
        newVault.mintShares(address(facet), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertGt(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be greater than 0"
        );

        selector = MockAsyncERC4626WithLockOnWithdraw.withdrawCancel.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, MINT_SHARES);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            MINT_SHARES,
            "Should be equal to mint shares"
        );

        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnDeposit()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestDeposit.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnDepositFinalization()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestDeposit.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        selector = MockAsyncERC4626WithoutLocks.depositFinalize.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, DEPOSIT_AMOUNT);
        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);
        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnDepositCancellation()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestDeposit.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        selector = MockAsyncERC4626WithoutLocks.depositCancel.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, DEPOSIT_AMOUNT);
        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);
        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnWithdraw()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestWithdraw.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(address(facet), address(asset)),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnWithdrawFinalization()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestWithdraw.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);
        newVault.mintShares(address(facet), MINT_SHARES);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        selector = MockAsyncERC4626WithoutLocks.withdrawFinalize.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, MINT_SHARES);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        asset.mint(address(newVault), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldExecuteSuccessfullyWithoutLocksOnWithdrawCancellation()
        public
    {
        MockAsyncERC4626WithoutLocks newVault = new MockAsyncERC4626WithoutLocks(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithoutLocks.requestWithdraw.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        selector = MockAsyncERC4626WithoutLocks.withdrawCancel.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(true, bytes(abi.encode(type(uint256).max)))
        );
        data = abi.encodeWithSelector(selector, MINT_SHARES);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        asset.mint(address(newVault), MINT_SHARES);
        facet.genericAsyncActionExecution(address(newVault), data);

        assertEq(
            MoreVaultsStorageHelper.getStaked(
                address(facet),
                address(newVault)
            ),
            0,
            "Should be 0"
        );

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldRevertWhenSelectorNotAllowed()
        public
    {
        // Mock registry to disallow selector
        bytes4 selector = bytes4(keccak256("test()"));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(vault),
                selector
            ),
            abi.encode(false, bytes(abi.encode(type(uint256).max)))
        );

        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(vault)
            ),
            abi.encode(true)
        );

        // Execute generic async action
        bytes memory data = abi.encodeWithSelector(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.SelectorNotAllowed.selector,
                selector
            )
        );
        facet.genericAsyncActionExecution(address(vault), data);

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldRevertWhenCalledByUnauthorized()
        public
    {
        vm.prank(unauthorized);

        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("test()")));
        vm.expectRevert(
            abi.encodeWithSelector(
                AccessControlLib.UnauthorizedAccess.selector,
                unauthorized
            )
        );
        facet.genericAsyncActionExecution(address(vault), data);
    }

    function test_genericAsyncActionExecution_ShouldRevertWhenVaultNotWhitelisted()
        public
    {
        bytes4 selector = bytes4(keccak256("test()"));
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(vault),
                selector
            ),
            abi.encode(false, bytes(abi.encode(type(uint256).max)))
        );
        vm.prank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(vault)
            ),
            abi.encode(false)
        );

        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("test()")));
        vm.expectRevert();
        facet.genericAsyncActionExecution(address(vault), data);
    }

    function test_genericAsyncActionExecution_ShouldRevertWhenUnexpectedChangeOfState()
        public
    {
        MockMaliciousERC4626 newVault = new MockMaliciousERC4626(
            IERC20(address(asset))
        );
        bytes4 selector = MockMaliciousERC4626.requestDeposit.selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        asset.mint(address(newVault), DEPOSIT_AMOUNT);
        bytes memory data = abi.encodeWithSelector(
            selector,
            DEPOSIT_AMOUNT,
            address(facet),
            address(facet)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IERC4626Facet.UnexpectedState.selector)
        );
        facet.genericAsyncActionExecution(address(newVault), data);

        vm.stopPrank();
    }

    function test_genericAsyncActionExecution_ShouldRevertIfInternalCallFails()
        public
    {
        MockAsyncERC4626WithLockOnWithdraw newVault = new MockAsyncERC4626WithLockOnWithdraw(
                IERC20(address(asset))
            );
        bytes4 selector = MockAsyncERC4626WithLockOnWithdraw
            .requestWithdraw
            .selector;
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorInfo.selector,
                address(newVault),
                selector
            ),
            abi.encode(
                true,
                bytes(abi.encode(type(uint256).max, uint256(0), uint256(0)))
            )
        );

        vm.startPrank(address(facet));

        bytes memory data = abi.encodeWithSelector(
            selector,
            MINT_SHARES,
            address(facet),
            address(facet)
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.isWhitelisted.selector,
                address(newVault)
            ),
            abi.encode(true)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC4626Facet.AsyncActionExecutionFailed.selector,
                hex"e450d38c0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b5e3af16b1880000"
            )
        );
        facet.genericAsyncActionExecution(address(newVault), data);
        vm.stopPrank();
    }
}
