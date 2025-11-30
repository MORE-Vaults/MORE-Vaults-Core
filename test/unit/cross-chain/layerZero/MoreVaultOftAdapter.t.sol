// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MoreVaultOftAdapter} from "../../../../src/cross-chain/layerZero/MoreVaultOftAdapter.sol";
import {MockEndpointV2} from "../../../../test/mocks/MockEndpointV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple ERC20 token with IERC20Metadata for testing
contract TestERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MoreVaultOftAdapterTest is Test {
    uint32 public localEid = uint32(101);
    
    MockEndpointV2 endpoint;
    TestERC20 token;
    MoreVaultOftAdapter adapter;
    address owner = address(0x1);
    address user = address(0xBEEF);
    address recipient = address(0xCAFE);

    function setUp() public {
        endpoint = new MockEndpointV2(localEid);
        token = new TestERC20("Test Token", "TEST", 18);
        
        vm.prank(owner);
        adapter = new MoreVaultOftAdapter(address(token), address(endpoint), owner);
        
        // Mint some tokens to the adapter to simulate dust accumulation
        token.mint(address(adapter), 1000e18);
        vm.deal(address(adapter), 5 ether);
    }

    // ============ Rescue ERC20 Token Tests ============
    
    function test_rescue_ERC20_success() public {
        uint256 dustAmount = 123e18;
        uint256 initialBalance = token.balanceOf(recipient);
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MoreVaultOftAdapter.Rescued(address(token), recipient, dustAmount);
        
        adapter.rescue(address(token), payable(recipient), dustAmount);
        
        assertEq(token.balanceOf(recipient), initialBalance + dustAmount, "Recipient should receive tokens");
        assertEq(token.balanceOf(address(adapter)), 1000e18 - dustAmount, "Adapter balance should decrease");
    }

    function test_rescue_ERC20_allTokens() public {
        uint256 adapterBalance = token.balanceOf(address(adapter));
        uint256 initialBalance = token.balanceOf(recipient);
        
        vm.prank(owner);
        adapter.rescue(address(token), payable(recipient), type(uint256).max);
        
        assertEq(token.balanceOf(recipient), initialBalance + adapterBalance, "Recipient should receive all tokens");
        assertEq(token.balanceOf(address(adapter)), 0, "Adapter balance should be zero");
    }

    function test_rescue_ERC20_reverts_whenNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.rescue(address(token), payable(recipient), 100e18);
    }

    function test_rescue_ERC20_reverts_whenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MoreVaultOftAdapter.ZeroAddress.selector);
        adapter.rescue(address(token), payable(address(0)), 100e18);
    }

    function test_rescue_ERC20_reverts_whenInsufficientBalance() public {
        uint256 excessiveAmount = token.balanceOf(address(adapter)) + 1;
        
        vm.prank(owner);
        vm.expectRevert(MoreVaultOftAdapter.InsufficientBalance.selector);
        adapter.rescue(address(token), payable(recipient), excessiveAmount);
    }

    // ============ Rescue Native Currency Tests ============
    
    function test_rescue_nativeCurrency_success() public {
        uint256 dustAmount = 2 ether;
        uint256 initialBalance = recipient.balance;
        
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MoreVaultOftAdapter.Rescued(address(0), recipient, dustAmount);
        
        adapter.rescue(address(0), payable(recipient), dustAmount);
        
        assertEq(recipient.balance, initialBalance + dustAmount, "Recipient should receive ETH");
        assertEq(address(adapter).balance, 5 ether - dustAmount, "Adapter balance should decrease");
    }

    function test_rescue_nativeCurrency_allBalance() public {
        uint256 adapterBalance = address(adapter).balance;
        uint256 initialBalance = recipient.balance;
        
        vm.prank(owner);
        adapter.rescue(address(0), payable(recipient), type(uint256).max);
        
        assertEq(recipient.balance, initialBalance + adapterBalance, "Recipient should receive all ETH");
        assertEq(address(adapter).balance, 0, "Adapter balance should be zero");
    }

    function test_rescue_nativeCurrency_reverts_whenNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.rescue(address(0), payable(recipient), 1 ether);
    }

    function test_rescue_nativeCurrency_reverts_whenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MoreVaultOftAdapter.ZeroAddress.selector);
        adapter.rescue(address(0), payable(address(0)), 1 ether);
    }

    function test_rescue_nativeCurrency_reverts_whenInsufficientBalance() public {
        uint256 excessiveAmount = address(adapter).balance + 1;
        
        vm.prank(owner);
        vm.expectRevert(MoreVaultOftAdapter.InsufficientBalance.selector);
        adapter.rescue(address(0), payable(recipient), excessiveAmount);
    }

    // ============ Edge Cases ============
    
    function test_rescue_zeroAmount() public {
        uint256 initialBalance = token.balanceOf(recipient);
        
        vm.prank(owner);
        adapter.rescue(address(token), payable(recipient), 0);
        
        assertEq(token.balanceOf(recipient), initialBalance, "Recipient balance should not change");
    }

    function test_rescue_multipleTokens() public {
        // Create another token
        TestERC20 token2 = new TestERC20("Token 2", "T2", 18);
        token2.mint(address(adapter), 500e18);
        
        vm.prank(owner);
        adapter.rescue(address(token), payable(recipient), 100e18);
        
        vm.prank(owner);
        adapter.rescue(address(token2), payable(recipient), 200e18);
        
        assertEq(token.balanceOf(recipient), 100e18, "Should rescue first token");
        assertEq(token2.balanceOf(recipient), 200e18, "Should rescue second token");
    }
}

