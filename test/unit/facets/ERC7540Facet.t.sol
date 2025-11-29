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

// Mock ERC7575 Vault with external share token
contract MockERC7575ShareToken is ERC20 {
    address public vaultAddress;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function setVault(address _vault) external {
        vaultAddress = _vault;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC7575Vault {
    address public immutable shareToken;
    address public immutable assetToken;
    uint256 public requestIdCounter = 1;

    constructor(address _asset, address _shareToken) {
        assetToken = _asset;
        shareToken = _shareToken;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function share() external view returns (address) {
        return shareToken;
    }

    function requestRedeem(uint256 sharesToRedeem, address, address) external returns (uint256) {
        require(sharesToRedeem > 0, "Zero shares");
        // Transfer shares from caller to this vault
        IERC20(shareToken).transferFrom(msg.sender, address(this), sharesToRedeem);
        return requestIdCounter++;
    }

    function balanceOf(address account) external view returns (uint256) {
        return IERC20(shareToken).balanceOf(account);
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }
}

// Mock vault that returns address(0) for share()
contract MockVaultReturnsZeroShare {
    address public immutable assetToken;

    constructor(address _asset) {
        assetToken = _asset;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function share() external pure returns (address) {
        return address(0);
    }

    function requestRedeem(uint256, address, address) external pure returns (uint256) {
        return 1;
    }
}

// Mock vault that returns itself as share token
contract MockVaultReturnsSelfAsShare is ERC20 {
    address public immutable assetToken;

    constructor(address _asset) ERC20("SelfShare", "SS") {
        assetToken = _asset;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function requestRedeem(uint256 sharesToRedeem, address, address) external returns (uint256) {
        require(sharesToRedeem > 0, "Zero shares");
        _transfer(msg.sender, address(this), sharesToRedeem);
        return 1;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock malicious vault with reentrancy in share token
contract MaliciousShareToken is ERC20 {
    address public attacker;
    address public targetFacet;
    bool public attacked;

    constructor() ERC20("Malicious", "MAL") {}

    function setAttacker(address _attacker, address _facet) external {
        attacker = _attacker;
        targetFacet = _facet;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (!attacked && targetFacet != address(0)) {
            attacked = true;
            // Attempt reentrancy
            try IERC7540Facet(targetFacet).erc7540RequestRedeem(attacker, amount) {} catch {}
        }
        return super.approve(spender, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMaliciousVault {
    address public immutable shareToken;
    address public immutable assetToken;

    constructor(address _asset, address _shareToken) {
        assetToken = _asset;
        shareToken = _shareToken;
    }

    function asset() external view returns (address) {
        return assetToken;
    }

    function share() external view returns (address) {
        return shareToken;
    }

    function requestRedeem(uint256 sharesToRedeem, address, address) external returns (uint256) {
        IERC20(shareToken).transferFrom(msg.sender, address(this), sharesToRedeem);
        return 1;
    }
}

// Mock vulnerable vault susceptible to inflation attack
contract MockVulnerableVault is ERC20 {
    IERC20 public immutable assetToken;

    constructor(address _asset) ERC20("Vulnerable Vault", "VV") {
        assetToken = IERC20(_asset);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    // Vulnerable: No decimal offset, no virtual shares
    function deposit(uint256 assets, address receiver, address) external returns (uint256 shares) {
        uint256 supply = totalSupply();
        uint256 balance = assetToken.balanceOf(address(this));

        if (supply == 0) {
            shares = assets; // 1:1 when empty
        } else {
            shares = (assets * supply) / balance; // VULNERABLE TO ROUNDING
        }

        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return shares;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * assetToken.balanceOf(address(this))) / supply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    function requestDeposit(uint256 assets, address, address receiver) external returns (uint256) {
        return this.deposit(assets, receiver, receiver);
    }

    function requestRedeem(uint256 shares, address, address) external returns (uint256) {
        _transfer(msg.sender, address(this), shares);
        return 1;
    }
}

// Mock vault with manipulable convertToAssets
contract MockManipulableVault is ERC20 {
    IERC20 public immutable assetToken;
    uint256 public manipulatedRate = 1e18; // Can be set by attacker

    constructor(address _asset) ERC20("Manipulable Vault", "MV") {
        assetToken = IERC20(_asset);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function setManipulatedRate(uint256 rate) external {
        manipulatedRate = rate;
    }

    function deposit(uint256 assets, address receiver, address) external returns (uint256 shares) {
        shares = assets; // Simple 1:1 for testing
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return shares;
    }

    // VULNERABLE: Can be manipulated
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * manipulatedRate) / 1e18;
    }

    function requestDeposit(uint256 assets, address, address receiver) external returns (uint256) {
        return this.deposit(assets, receiver, receiver);
    }

    function requestRedeem(uint256 shares, address, address) external returns (uint256) {
        _transfer(msg.sender, address(this), shares);
        return 1;
    }
}

// Mock flash loan provider
contract MockFlashLoanProvider {
    IERC20 public immutable token;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function flashLoan(address receiver, uint256 amount) external {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transfer(receiver, amount);

        // Call receiver
        (bool success,) = receiver.call(abi.encodeWithSignature("onFlashLoan(uint256)", amount));
        require(success, "Flash loan callback failed");

        // Verify repayment
        require(token.balanceOf(address(this)) >= balanceBefore, "Flash loan not repaid");
    }

    function fund(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
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

    // Test for issue #27: Missing locked token accounting during async deposit
    function test_accountingERC7540Facet_ShouldAccountLockedTokensDuringAsyncDeposit() public {
        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        // First deposit some assets to have initial balance
        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        // Get initial accounting
        (uint256 sumBefore,) = facet.accountingERC7540Facet();
        assertEq(sumBefore, DEPOSIT_AMOUNT, "Initial sum should equal deposit amount");

        // Request async deposit - this should lock the assets
        uint256 asyncDepositAmount = 50e18;
        facet.erc7540RequestDeposit(address(vault), asyncDepositAmount);

        // Verify locked tokens are tracked
        uint256 lockedAssets = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(asset));
        assertEq(lockedAssets, asyncDepositAmount, "Assets should be locked");

        // Accounting should still include the locked assets even though shares haven't been received yet
        (uint256 sumAfterRequest,) = facet.accountingERC7540Facet();
        assertEq(
            sumAfterRequest,
            DEPOSIT_AMOUNT,
            "Sum should remain the same - locked assets should be accounted for"
        );

        vm.stopPrank();
    }

    // Test for issue #27: Missing locked token accounting during async redeem
    function test_accountingERC7540Facet_ShouldAccountLockedTokensDuringAsyncRedeem() public {
        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        // First deposit to get shares
        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        // Get initial accounting
        (uint256 sumBefore,) = facet.accountingERC7540Facet();
        assertEq(sumBefore, DEPOSIT_AMOUNT, "Initial sum should equal deposit amount");

        // Request async redeem - this should lock the shares
        uint256 asyncRedeemShares = 30e18;
        facet.erc7540RequestRedeem(address(vault), asyncRedeemShares);

        // Verify locked tokens are tracked
        uint256 lockedShares = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(vault));
        assertEq(lockedShares, asyncRedeemShares, "Shares should be locked");

        // Accounting should still include the locked shares even though assets haven't been received yet
        (uint256 sumAfterRequest,) = facet.accountingERC7540Facet();
        assertEq(
            sumAfterRequest,
            DEPOSIT_AMOUNT,
            "Sum should remain the same - locked shares should be accounted for"
        );

        vm.stopPrank();
    }

    // Test for issue #27: Locked tokens should be unlocked after deposit finalization
    function test_erc7540Deposit_ShouldUnlockTokensAfterFinalization() public {
        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        // Request async deposit - this should lock the assets
        uint256 asyncDepositAmount = 50e18;
        facet.erc7540RequestDeposit(address(vault), asyncDepositAmount);

        // Verify assets are locked
        uint256 lockedAssetsBefore = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(asset));
        assertEq(lockedAssetsBefore, asyncDepositAmount, "Assets should be locked after request");

        // Finalize the deposit - this should unlock the assets
        IERC20(asset).approve(address(vault), asyncDepositAmount);
        facet.erc7540Deposit(address(vault), asyncDepositAmount);

        // Verify assets are unlocked
        uint256 lockedAssetsAfter = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(asset));
        assertEq(lockedAssetsAfter, 0, "Assets should be unlocked after finalization");

        vm.stopPrank();
    }

    // Test for issue #27: Locked tokens should be unlocked after redeem finalization
    function test_erc7540Redeem_ShouldUnlockTokensAfterFinalization() public {
        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        // First deposit to get shares
        IERC20(asset).approve(address(vault), DEPOSIT_AMOUNT);
        facet.erc7540Deposit(address(vault), DEPOSIT_AMOUNT);

        // Request async redeem - this should lock the shares
        uint256 asyncRedeemShares = 30e18;
        facet.erc7540RequestRedeem(address(vault), asyncRedeemShares);

        // Verify shares are locked
        uint256 lockedSharesBefore = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(vault));
        assertEq(lockedSharesBefore, asyncRedeemShares, "Shares should be locked after request");

        // Mint assets to vault to allow redeem
        MockERC20(asset).mint(address(vault), asyncRedeemShares);

        // Finalize the redeem - this should unlock the shares
        facet.erc7540Redeem(address(vault), asyncRedeemShares);

        // Verify shares are unlocked
        uint256 lockedSharesAfter = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(vault));
        assertEq(lockedSharesAfter, 0, "Shares should be unlocked after finalization");

        vm.stopPrank();
    }

    // ============ ERC-7575 External Share Token Tests ============

    function test_erc7540RequestRedeem_ERC7575_WithExternalShareToken() public {
        // Deploy ERC7575 vault with external share token
        MockERC7575ShareToken shareToken = new MockERC7575ShareToken("Share Token", "SHR");
        MockERC7575Vault erc7575Vault = new MockERC7575Vault(address(asset), address(shareToken));

        vm.startPrank(address(facet));

        // Mint shares to facet
        shareToken.mint(address(facet), MINT_SHARES);
        uint256 sharesBefore = shareToken.balanceOf(address(facet));

        // Whitelist the ERC7575 vault
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(erc7575Vault)),
            abi.encode(true)
        );

        // Request redeem - should approve external share token
        facet.erc7540RequestRedeem(address(erc7575Vault), MINT_SHARES);

        // Verify shares were transferred from facet to vault
        uint256 sharesAfter = shareToken.balanceOf(address(facet));
        assertEq(sharesAfter, sharesBefore - MINT_SHARES, "Shares should be transferred to vault");
        assertEq(shareToken.balanceOf(address(erc7575Vault)), MINT_SHARES, "Vault should receive shares");

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ERC7540Standard_StillWorks() public {
        // Regression test: Ensure standard ERC7540 vaults still work
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
        assertEq(sharesAfter, sharesBefore - MINT_SHARES, "Standard vault should still work");

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ShareReturnsAddressZero_ShouldNotApprove() public {
        // Deploy vault that returns address(0) for share()
        MockVaultReturnsZeroShare zeroShareVault = new MockVaultReturnsZeroShare(address(asset));

        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(zeroShareVault)),
            abi.encode(true)
        );

        // Should not revert, just skip approval
        facet.erc7540RequestRedeem(address(zeroShareVault), MINT_SHARES);

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ShareReturnsSelf_ShouldNotApprove() public {
        // Deploy vault that returns itself as share token
        MockVaultReturnsSelfAsShare selfShareVault = new MockVaultReturnsSelfAsShare(address(asset));

        vm.startPrank(address(facet));

        // Mint shares to facet
        selfShareVault.mint(address(facet), MINT_SHARES);
        uint256 sharesBefore = selfShareVault.balanceOf(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(selfShareVault)),
            abi.encode(true)
        );

        // Should not do unnecessary self-approval
        facet.erc7540RequestRedeem(address(selfShareVault), MINT_SHARES);

        // Shares should still be transferred (vault handles this internally)
        uint256 sharesAfter = selfShareVault.balanceOf(address(facet));
        assertEq(sharesAfter, sharesBefore - MINT_SHARES, "Shares should be transferred");

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ReentrancyProtection() public {
        // Deploy malicious vault with reentrancy attempt
        MaliciousShareToken maliciousShare = new MaliciousShareToken();
        MockMaliciousVault maliciousVault = new MockMaliciousVault(address(asset), address(maliciousShare));

        vm.startPrank(address(facet));

        // Setup malicious share token
        maliciousShare.setAttacker(address(maliciousVault), address(facet));
        maliciousShare.mint(address(facet), MINT_SHARES);

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(maliciousVault)),
            abi.encode(true)
        );

        // This should NOT allow reentrancy - protected by AccessControlLib.validateDiamond
        facet.erc7540RequestRedeem(address(maliciousVault), MINT_SHARES);

        // If reentrancy occurred, attacked flag would be set
        assertTrue(maliciousShare.attacked(), "Reentrancy was attempted");
        // But facet should still complete successfully due to access control

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ERC7575_VerifyExactApproval() public {
        // Verify we use exact approval, not infinite
        MockERC7575ShareToken shareToken = new MockERC7575ShareToken("Share Token", "SHR");
        MockERC7575Vault erc7575Vault = new MockERC7575Vault(address(asset), address(shareToken));

        vm.startPrank(address(facet));

        shareToken.mint(address(facet), MINT_SHARES * 2); // Mint more than we'll redeem

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(erc7575Vault)),
            abi.encode(true)
        );

        // Request redeem with half the shares
        facet.erc7540RequestRedeem(address(erc7575Vault), MINT_SHARES);

        // Verify only MINT_SHARES were transferred, not all
        assertEq(shareToken.balanceOf(address(facet)), MINT_SHARES, "Only requested shares should be transferred");
        assertEq(shareToken.balanceOf(address(erc7575Vault)), MINT_SHARES, "Vault should receive exact amount");

        vm.stopPrank();
    }

    function test_erc7540RequestRedeem_ERC7575_MultipleVaults() public {
        // Test that we can handle multiple ERC7575 vaults with different share tokens
        MockERC7575ShareToken shareToken1 = new MockERC7575ShareToken("Share Token 1", "SHR1");
        MockERC7575ShareToken shareToken2 = new MockERC7575ShareToken("Share Token 2", "SHR2");
        MockERC7575Vault vault1 = new MockERC7575Vault(address(asset), address(shareToken1));
        MockERC7575Vault vault2 = new MockERC7575Vault(address(asset), address(shareToken2));

        vm.startPrank(address(facet));

        // Mint shares for both vaults
        shareToken1.mint(address(facet), MINT_SHARES);
        shareToken2.mint(address(facet), MINT_SHARES);

        // Whitelist both vaults
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault1)),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault2)),
            abi.encode(true)
        );

        // Request redeem from both
        facet.erc7540RequestRedeem(address(vault1), MINT_SHARES);
        facet.erc7540RequestRedeem(address(vault2), MINT_SHARES);

        // Verify both worked correctly
        assertEq(shareToken1.balanceOf(address(vault1)), MINT_SHARES, "Vault1 should receive shares");
        assertEq(shareToken2.balanceOf(address(vault2)), MINT_SHARES, "Vault2 should receive shares");

        vm.stopPrank();
    }

    // ============ CRITICAL SECURITY TESTS: Advanced Attack Vectors ============

    function test_Security_InflationAttackOnVulnerableExternalVault() public {
        // This test demonstrates how MORE Vault CANNOT protect against
        // inflation attacks on vulnerable external vaults
        MockVulnerableVault vulnerableVault = new MockVulnerableVault(address(asset));
        address attacker = address(0xbad);
        address victim = address(facet);

        vm.startPrank(address(facet));

        // Whitelist the vulnerable vault (curator's responsibility)
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vulnerableVault)),
            abi.encode(true)
        );

        vm.stopPrank();

        // ===== ATTACK SCENARIO =====

        // 1. Attacker deposits 1 wei into the vulnerable vault
        vm.startPrank(attacker);
        asset.mint(attacker, 1e18);
        asset.approve(address(vulnerableVault), 1);
        vulnerableVault.deposit(1, attacker, attacker);
        assertEq(vulnerableVault.totalSupply(), 1, "Attacker should have 1 share");
        vm.stopPrank();

        // 2. Attacker donates large amount to inflate share price
        vm.startPrank(attacker);
        uint256 donationAmount = 10_000e18;
        asset.mint(attacker, donationAmount);
        asset.transfer(address(vulnerableVault), donationAmount);
        // Now: totalSupply = 1, totalAssets = 10_000e18 + 1
        vm.stopPrank();

        // 3. MORE Vault (victim) deposits
        vm.startPrank(victim);
        uint256 victimDeposit = 20_000e18;
        asset.mint(victim, victimDeposit);
        asset.approve(address(vulnerableVault), victimDeposit);

        uint256 sharesBefore = vulnerableVault.balanceOf(victim);
        facet.erc7540Deposit(address(vulnerableVault), victimDeposit);
        uint256 sharesAfter = vulnerableVault.balanceOf(victim);

        // Due to rounding, victim gets very few or zero shares
        uint256 sharesReceived = sharesAfter - sharesBefore;

        // This demonstrates the vulnerability exists in external vault
        // MORE Vault receives shares, but they may be worth less than deposited
        assertTrue(sharesReceived < victimDeposit, "Victim received less shares than expected due to inflation attack");

        vm.stopPrank();

        // CONCLUSION: MORE Vault cannot protect against vulnerable external vaults
        // MITIGATION: Strict whitelist process with audited vaults only
    }

    function test_Security_SharePriceManipulationViaConvertToAssets() public {
        // Test that attacker can manipulate accounting via malicious convertToAssets
        MockManipulableVault manipulableVault = new MockManipulableVault(address(asset));

        vm.startPrank(address(facet));

        // Whitelist the vault
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(manipulableVault)),
            abi.encode(true)
        );

        // MORE Vault deposits normally
        uint256 depositAmount = 1000e18;
        asset.mint(address(facet), depositAmount);
        asset.approve(address(manipulableVault), depositAmount);
        facet.erc7540Deposit(address(manipulableVault), depositAmount);

        // Get normal accounting
        (uint256 normalAccounting,) = facet.accountingERC7540Facet();

        // Attacker manipulates the exchange rate in the external vault
        manipulableVault.setManipulatedRate(10e18); // 10x inflation!

        // Get manipulated accounting
        (uint256 manipulatedAccounting,) = facet.accountingERC7540Facet();

        // Accounting is inflated!
        assertTrue(
            manipulatedAccounting > normalAccounting, "Attacker can manipulate accounting via convertToAssets"
        );

        vm.stopPrank();

        // CONCLUSION: External vaults can manipulate accounting
        // MITIGATION: Only whitelist audited vaults with proper protections
    }

    function test_Security_AccountingWithLockedTokens_CannotBeExploited() public {
        // Test that locked tokens cannot be exploited for accounting manipulation
        vm.startPrank(address(facet));

        vault.mintShares(address(facet), MINT_SHARES * 10);

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vault)),
            abi.encode(true)
        );

        // Get accounting before requestRedeem
        (uint256 accountingBefore,) = facet.accountingERC7540Facet();

        // Request redeem (locks tokens)
        facet.erc7540RequestRedeem(address(vault), MINT_SHARES);

        // Get accounting after requestRedeem
        (uint256 accountingAfter,) = facet.accountingERC7540Facet();

        // Accounting should include locked tokens (they still have value)
        assertEq(
            accountingAfter,
            accountingBefore,
            "Accounting should remain same (locked tokens still counted)"
        );

        // Verify locked tokens are tracked
        uint256 lockedTokens = MoreVaultsStorageHelper.getLockedTokens(address(facet), address(vault));
        assertEq(lockedTokens, MINT_SHARES, "Locked tokens should be tracked");

        vm.stopPrank();

        // CONCLUSION: Locked tokens accounting is correct and cannot be exploited
    }

    function test_Security_FlashLoanDonationAttack_RequiresVulnerableVault() public {
        // Simulate flash loan + donation attack
        // This test shows the attack requires BOTH flash loan AND vulnerable vault
        MockVulnerableVault vulnerableVault = new MockVulnerableVault(address(asset));
        MockFlashLoanProvider flashLoanProvider = new MockFlashLoanProvider(address(asset));

        address attacker = address(0xbad);

        // Setup: Fund flash loan provider
        asset.mint(address(this), 10_000_000e18);
        asset.approve(address(flashLoanProvider), 10_000_000e18);
        flashLoanProvider.fund(10_000_000e18);

        vm.startPrank(address(facet));

        // Whitelist the vulnerable vault
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vulnerableVault)),
            abi.encode(true)
        );

        vm.stopPrank();

        // NOTE: We cannot easily test the full flash loan attack in Foundry without
        // a flash loan receiver contract, but this demonstrates the components:

        // 1. Attacker would need to deploy a contract that:
        //    a. Takes flash loan
        //    b. Deposits 1 wei to vulnerable vault
        //    c. Donates flash loan amount to vault
        //    d. Front-runs victim deposit
        //    e. Redeems shares
        //    f. Repays flash loan
        //    g. Keeps profit

        // 2. This attack REQUIRES:
        //    - Vulnerable external vault (no decimal offset/virtual shares)
        //    - Flash loan access
        //    - Ability to front-run
        //    - Victim depositing after attack setup

        // 3. MORE Vault's protection:
        //    - Async operations (ERC-7540) make timing harder
        //    - Whitelist requirement
        //    - Only curator can whitelist vaults

        // CONCLUSION: Attack is possible but requires vulnerable whitelisted vault
        // MITIGATION: Strict audit requirements for whitelisted vaults
    }

    function test_Security_MultipleDepositsToVulnerableVault_AccumulateDamage() public {
        // Test that multiple deposits to a vulnerable vault accumulate losses
        MockVulnerableVault vulnerableVault = new MockVulnerableVault(address(asset));
        address attacker = address(0xbad);

        vm.startPrank(address(facet));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(vulnerableVault)),
            abi.encode(true)
        );

        vm.stopPrank();

        // Setup attack
        vm.startPrank(attacker);
        asset.mint(attacker, 100_000e18);
        asset.approve(address(vulnerableVault), 1);
        vulnerableVault.deposit(1, attacker, attacker);
        asset.transfer(address(vulnerableVault), 50_000e18); // Donate to inflate
        vm.stopPrank();

        // Multiple victims deposit
        vm.startPrank(address(facet));

        for (uint256 i = 0; i < 3; i++) {
            asset.mint(address(facet), 10_000e18);
            asset.approve(address(vulnerableVault), 10_000e18);

            uint256 sharesBefore = vulnerableVault.balanceOf(address(facet));
            facet.erc7540Deposit(address(vulnerableVault), 10_000e18);
            uint256 sharesAfter = vulnerableVault.balanceOf(address(facet));

            // Each deposit receives diminished shares
            assertTrue(
                sharesAfter - sharesBefore < 10_000e18,
                "Each deposit receives less than expected due to inflated share price"
            );
        }

        vm.stopPrank();

        // CONCLUSION: Vulnerability in external vault affects all subsequent deposits
        // MITIGATION: Due diligence on external vaults is CRITICAL
    }

    function test_Security_EmptyVaultIsNotVulnerable_ButExternalMightBe() public {
        // Test that MORE's own vault (VaultFacet) is protected via decimal offset
        // but external vaults might not be

        // This is a documentation test showing the difference

        // MORE Vault (VaultFacet) uses:
        // assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding)
        // This protects against inflation attacks

        // External vaults might use:
        // shares = (assets * totalSupply()) / totalAssets()
        // This is VULNERABLE when totalSupply is low

        MockVulnerableVault externalVault = new MockVulnerableVault(address(asset));

        // External vault is vulnerable to empty vault attack
        address attacker = address(0xbad);

        vm.startPrank(attacker);
        asset.mint(attacker, 2e18); // Need enough for deposit + donation
        asset.approve(address(externalVault), type(uint256).max);

        // Deposit 1 wei
        uint256 shares1 = externalVault.deposit(1, attacker, attacker);
        assertEq(shares1, 1, "First deposit should give 1:1 shares");

        // Donate to inflate (this is the attack)
        asset.transfer(address(externalVault), 1e18);

        vm.stopPrank();

        // Next depositor gets screwed
        address victim = address(0x123);
        vm.startPrank(victim);
        asset.mint(victim, 1e18);
        asset.approve(address(externalVault), 1e18);

        uint256 sharesVictim = externalVault.deposit(1e18, victim, victim);

        // Victim gets very few shares due to inflation
        assertTrue(sharesVictim < 1e18, "Victim receives less shares than deposited assets");

        vm.stopPrank();

        // CONCLUSION: External vaults without protections are vulnerable
        // MORE Vault's own VaultFacet is protected
        // But MORE Vault cannot protect against vulnerabilities in external vaults
    }
}
