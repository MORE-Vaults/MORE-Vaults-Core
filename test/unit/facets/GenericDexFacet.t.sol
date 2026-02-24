// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GenericDexFacet} from "../../../src/facets/GenericDexFacet.sol";
import {IGenericDexFacet} from "../../../src/interfaces/facets/IGenericDexFacet.sol";
import {AccessControlLib} from "../../../src/libraries/AccessControlLib.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockAggregator {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address receiver) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20Mock(tokenOut).mint(receiver, amountOut);
    }
}

contract MockQuoter {
    function getQuote(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn * 2;
    }
}

contract GenericDexFacetTest is Test {
    GenericDexFacet public facet;
    MockAggregator public aggregator;
    MockQuoter public quoter;
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;

    address public owner = address(1);
    address public curator = address(2);
    address public guardian = address(3);
    address public unauthorized = address(4);
    address public mockRegistry = address(5);

    function setUp() public {
        facet = new GenericDexFacet();
        aggregator = new MockAggregator();
        quoter = new MockQuoter();
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();

        MoreVaultsStorageHelper.setOwner(address(facet), owner);
        MoreVaultsStorageHelper.setCurator(address(facet), curator);
        MoreVaultsStorageHelper.setGuardian(address(facet), guardian);
        MoreVaultsStorageHelper.setMoreVaultsRegistry(address(facet), mockRegistry);

        address[] memory availableAssets = new address[](2);
        availableAssets[0] = address(tokenA);
        availableAssets[1] = address(tokenB);
        MoreVaultsStorageHelper.setAvailableAssets(address(facet), availableAssets);

        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(aggregator)),
            abi.encode(true)
        );
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(IMoreVaultsRegistry.isWhitelisted.selector, address(quoter)),
            abi.encode(true)
        );

        tokenA.mint(address(facet), 1000e18);
        tokenB.mint(address(aggregator), 1000e18);
    }

    function test_facetName_ShouldReturnCorrectName() public view {
        assertEq(facet.facetName(), "GenericDexFacet");
    }

    function test_facetVersion_ShouldReturnCorrectVersion() public view {
        assertEq(facet.facetVersion(), "1.0.0");
    }

    function test_getGenericQuote_ShouldReturnQuote() public view {
        bytes memory quoteCall =
            abi.encodeWithSelector(MockQuoter.getQuote.selector, address(tokenA), address(tokenB), 100e18);

        bytes memory result = facet.getGenericQuote(address(quoter), quoteCall);
        uint256 quote = abi.decode(result, (uint256));

        assertEq(quote, 200e18);
    }

    function test_getGenericQuote_ShouldRevertIfQuoterNotWhitelisted() public {
        address notWhitelisted = address(0x999);
        bytes memory quoteCall = abi.encodeWithSelector(MockQuoter.getQuote.selector, address(tokenA), address(tokenB), 100e18);

        vm.expectRevert();
        facet.getGenericQuote(notWhitelisted, quoteCall);
    }

    function test_executeSwap_ShouldSwapSuccessfully() public {
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 90e18;

        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenB), amountIn, 95e18, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: amountIn,
            minAmountOut: minAmountOut,
            swapCallData: swapCall
        });

        uint256 balanceABefore = tokenA.balanceOf(address(facet));
        uint256 balanceBBefore = tokenB.balanceOf(address(facet));

        vm.prank(address(facet));
        uint256 amountOut = facet.executeSwap(params);

        assertEq(tokenA.balanceOf(address(facet)), balanceABefore - amountIn);
        assertEq(tokenB.balanceOf(address(facet)), balanceBBefore + amountOut);
        assertGe(amountOut, minAmountOut);
    }

    function test_executeSwap_ShouldRevertIfNotCurator() public {
        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: 100e18,
            minAmountOut: 90e18,
            swapCallData: ""
        });

        vm.prank(unauthorized);
        vm.expectRevert(AccessControlLib.UnauthorizedAccess.selector);
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfTargetNotWhitelisted() public {
        address notWhitelisted = address(0x999);

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: notWhitelisted,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: 100e18,
            minAmountOut: 90e18,
            swapCallData: ""
        });

        vm.prank(curator);
        vm.expectRevert();
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfTokenInNotAvailable() public {
        ERC20Mock tokenC = new ERC20Mock();

        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenC), address(tokenB), 100e18, 95e18, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenC),
            tokenOut: address(tokenB),
            maxAmountIn: 100e18,
            minAmountOut: 90e18,
            swapCallData: swapCall
        });

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.InvalidTokenIn.selector, address(tokenC)));
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfTokenOutNotAvailable() public {
        ERC20Mock tokenC = new ERC20Mock();

        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenC), 100e18, 95e18, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenC),
            maxAmountIn: 100e18,
            minAmountOut: 90e18,
            swapCallData: swapCall
        });

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.InvalidTokenOut.selector, address(tokenC)));
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfSameToken() public {
        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenA), 100e18, 95e18, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenA),
            maxAmountIn: 100e18,
            minAmountOut: 90e18,
            swapCallData: swapCall
        });

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.SameToken.selector, address(tokenA)));
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfZeroAmount() public {
        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenB), 0, 0, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: 0,
            minAmountOut: 0,
            swapCallData: swapCall
        });

        vm.prank(address(facet));
        vm.expectRevert(IGenericDexFacet.ZeroAmount.selector);
        facet.executeSwap(params);
    }

    function test_executeSwap_ShouldRevertIfSlippageExceeded() public {
        uint256 amountIn = 100e18;
        uint256 minAmountOut = 100e18;

        bytes memory swapCall = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenB), amountIn, 95e18, address(facet)
        );

        IGenericDexFacet.SwapParams memory params = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: amountIn,
            minAmountOut: minAmountOut,
            swapCallData: swapCall
        });

        vm.prank(address(facet));
        vm.expectRevert(abi.encodeWithSelector(IGenericDexFacet.SlippageExceeded.selector, 95e18, 100e18));
        facet.executeSwap(params);
    }

    function test_executeBatchSwap_ShouldExecuteMultipleSwaps() public {
        IGenericDexFacet.SwapParams[] memory swaps = new IGenericDexFacet.SwapParams[](2);

        bytes memory swapCall1 = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenB), 50e18, 45e18, address(facet)
        );

        swaps[0] = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: 50e18,
            minAmountOut: 40e18,
            swapCallData: swapCall1
        });

        bytes memory swapCall2 = abi.encodeWithSelector(
            MockAggregator.swap.selector, address(tokenA), address(tokenB), 30e18, 27e18, address(facet)
        );

        swaps[1] = IGenericDexFacet.SwapParams({
            targetContract: address(aggregator),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            maxAmountIn: 30e18,
            minAmountOut: 25e18,
            swapCallData: swapCall2
        });

        IGenericDexFacet.BatchSwapParams memory batchParams =
            IGenericDexFacet.BatchSwapParams({swaps: swaps});

        vm.mockCall(address(facet), abi.encodeWithSignature("totalAssets()"), abi.encode(1000e18));

        vm.prank(address(facet));
        uint256[] memory amountsOut = facet.executeBatchSwap(batchParams);

        assertEq(amountsOut.length, 2);
        assertGe(amountsOut[0], 40e18);
        assertGe(amountsOut[1], 25e18);
    }
}
