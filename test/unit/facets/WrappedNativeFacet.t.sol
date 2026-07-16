// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WrappedNativeFacet} from "../../../src/facets/WrappedNativeFacet.sol";
import {IWrappedNativeFacet} from "../../../src/interfaces/facets/IWrappedNativeFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IWrappedToken} from "../../../src/interfaces/IWrappedToken.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract MockWrappedNative is MockERC20, IWrappedToken {
    constructor() MockERC20("WFLOW", "WFLOW") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "native transfer failed");
    }

    receive() external payable {}
}

contract WrappedNativeFacetHarness is WrappedNativeFacet {
    receive() external payable {}
}

contract WrappedNativeFacetTest is Test {
    WrappedNativeFacetHarness public facet;
    MockWrappedNative public wflow;

    address public unauthorized = address(4);

    function setUp() public {
        facet = new WrappedNativeFacetHarness();
        wflow = new MockWrappedNative();

        MoreVaultsStorageHelper.setWrappedNative(address(facet), address(wflow));

        address[] memory availableAssets = new address[](1);
        availableAssets[0] = address(wflow);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "WrappedNativeFacet");
    }

    function test_facetVersion_ShouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0");
    }

    function test_wrapNative_ShouldMintWrappedTokens() public {
        uint256 amount = 5 ether;
        vm.deal(address(facet), amount);

        vm.prank(address(facet));
        vm.expectEmit(true, false, false, true);
        emit IWrappedNativeFacet.NativeWrapped(address(wflow), amount);
        facet.wrapNative(amount);

        assertEq(IERC20(address(wflow)).balanceOf(address(facet)), amount);
        assertEq(address(facet).balance, 0);
    }

    function test_unwrapNative_ShouldReturnNativeTokens() public {
        uint256 amount = 3 ether;
        vm.deal(address(wflow), amount);
        wflow.deposit{value: amount}();
        wflow.transfer(address(facet), amount);

        vm.prank(address(facet));
        vm.expectEmit(true, false, false, true);
        emit IWrappedNativeFacet.NativeUnwrapped(address(wflow), amount);
        facet.unwrapNative(amount);

        assertEq(IERC20(address(wflow)).balanceOf(address(facet)), 0);
        assertEq(address(facet).balance, amount);
    }

    function test_wrapNative_ShouldRevertIfNotDiamond() public {
        vm.deal(address(facet), 1 ether);

        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.wrapNative(1 ether);
    }

    function test_unwrapNative_ShouldRevertIfNotDiamond() public {
        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.unwrapNative(1 ether);
    }

    function test_wrapNative_ShouldRevertIfZeroAmount() public {
        vm.prank(address(facet));
        vm.expectRevert(IWrappedNativeFacet.ZeroAmount.selector);
        facet.wrapNative(0);
    }

    function test_unwrapNative_ShouldRevertIfZeroAmount() public {
        vm.prank(address(facet));
        vm.expectRevert(IWrappedNativeFacet.ZeroAmount.selector);
        facet.unwrapNative(0);
    }

    function test_wrapNative_ShouldRevertIfWrappedNativeNotSet() public {
        MoreVaultsStorageHelper.setWrappedNative(address(facet), address(0));
        vm.deal(address(facet), 1 ether);

        vm.prank(address(facet));
        vm.expectRevert(IWrappedNativeFacet.WrappedNativeNotSet.selector);
        facet.wrapNative(1 ether);
    }

    function test_wrapNative_ShouldRevertIfAssetNotAvailable() public {
        MoreVaultsStorageHelper.setMappingValue(
            address(facet),
            MoreVaultsStorageHelper.ASSET_AVAILABLE,
            bytes32(uint256(uint160(address(wflow)))),
            bytes32(uint256(0))
        );
        vm.deal(address(facet), 1 ether);

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(MoreVaultsLib.UnsupportedAsset.selector, address(wflow)));
        facet.wrapNative(1 ether);
    }

    function test_wrapNative_ShouldRevertIfInsufficientNativeBalance() public {
        vm.deal(address(facet), 1 ether);

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IWrappedNativeFacet.InsufficientNativeBalance.selector, 2 ether, 1 ether));
        facet.wrapNative(2 ether);
    }

    function test_unwrapNative_ShouldRevertIfInsufficientWrappedBalance() public {
        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IWrappedNativeFacet.InsufficientWrappedBalance.selector, 1 ether, 0));
        facet.unwrapNative(1 ether);
    }
}
