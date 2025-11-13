// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IDexAggregatorFacet} from "../interfaces/facets/IDexAggregatorFacet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DexAggregatorFacet
 * @notice Facet for executing token swaps through any DEX aggregator
 * @dev Provides generic swap functionality that works with any whitelisted aggregator
 */
contract DexAggregatorFacet is BaseFacetInitializer, IDexAggregatorFacet {
    using SafeERC20 for IERC20;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.DexAggregatorFacet");
    }

    function facetName() external pure returns (string memory) {
        return "DexAggregatorFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Initialize the facet
     * @param data Encoded facet selector for accounting
     */
    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        bytes32 facetSelector = abi.decode(data, (bytes32));
        ds.facetsForAccounting.push(facetSelector);
        ds.supportedInterfaces[type(IDexAggregatorFacet).interfaceId] = true;
    }

    /**
     * @notice Handle facet removal
     * @param isReplacing Whether the facet is being replaced
     */
    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IDexAggregatorFacet).interfaceId] = false;
        MoreVaultsLib.removeFromFacetsForAccounting(
            ds, IDexAggregatorFacet.accountingDexAggregatorFacet.selector, isReplacing
        );
    }

    /**
     * @inheritdoc IDexAggregatorFacet
     */
    function accountingDexAggregatorFacet() external pure returns (uint256, bool) {
        return (0, true);
    }

    /**
     * @inheritdoc IDexAggregatorFacet
     */
    function getGenericQuote(address quoter, bytes calldata quoteCallData)
        external
        view
        returns (bytes memory quoteResult)
    {
        MoreVaultsLib.validateAddressWhitelisted(quoter);

        (bool success, bytes memory result) = quoter.staticcall(quoteCallData);

        if (!success) {
            revert QuoteFailed(result);
        }

        return result;
    }

    /**
     * @inheritdoc IDexAggregatorFacet
     */
    function executeSwap(SwapParams calldata params) external returns (uint256 amountOut) {
        MoreVaultsLib.validateNotMulticall();
        AccessControlLib.validateCurator(msg.sender);

        _validateSwapParams(params);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 tokenInBalanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
        uint256 tokenOutBalanceBefore = IERC20(params.tokenOut).balanceOf(address(this));

        IERC20(params.tokenIn).forceApprove(params.targetContract, params.amountIn);

        (bool success, bytes memory result) = params.targetContract.call(params.swapCallData);

        IERC20(params.tokenIn).forceApprove(params.targetContract, 0);

        if (!success) {
            revert SwapFailed(result);
        }

        uint256 tokenInBalanceAfter = IERC20(params.tokenIn).balanceOf(address(this));
        uint256 tokenOutBalanceAfter = IERC20(params.tokenOut).balanceOf(address(this));

        uint256 actualAmountIn = tokenInBalanceBefore - tokenInBalanceAfter;
        if (actualAmountIn != params.amountIn) {
            revert UnexpectedAmountIn(params.amountIn, actualAmountIn);
        }

        amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
        if (amountOut < params.minAmountOut) {
            revert SlippageExceeded(amountOut, params.minAmountOut);
        }

        emit SwapExecuted(msg.sender, params.tokenIn, params.tokenOut, actualAmountIn, amountOut, params.targetContract);

        return amountOut;
    }

    /**
     * @inheritdoc IDexAggregatorFacet
     */
    function executeBatchSwap(BatchSwapParams calldata params) external returns (uint256[] memory amountsOut) {
        MoreVaultsLib.validateNotMulticall();
        AccessControlLib.validateCurator(msg.sender);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        uint256 totalBefore = _getTotalAssets();

        amountsOut = new uint256[](params.swaps.length);

        for (uint256 i = 0; i < params.swaps.length;) {
            amountsOut[i] = _executeSwapInternal(params.swaps[i]);
            unchecked {
                ++i;
            }
        }

        uint256 totalAfter = _getTotalAssets();

        if (totalBefore > totalAfter) {
            uint256 slippagePercent = ((totalBefore - totalAfter) * 10_000) / totalBefore;
            if (slippagePercent > ds.maxSlippagePercent) {
                revert GlobalSlippageExceeded(slippagePercent, ds.maxSlippagePercent);
            }
        }

        emit BatchSwapExecuted(msg.sender, params.swaps.length, totalBefore, totalAfter);

        return amountsOut;
    }

    /**
     * @notice Internal function to execute a single swap
     * @param params Swap parameters
     * @return amountOut Actual amount received
     */
    function _executeSwapInternal(SwapParams calldata params) private returns (uint256 amountOut) {
        _validateSwapParams(params);

        uint256 tokenInBalanceBefore = IERC20(params.tokenIn).balanceOf(address(this));
        uint256 tokenOutBalanceBefore = IERC20(params.tokenOut).balanceOf(address(this));

        IERC20(params.tokenIn).forceApprove(params.targetContract, params.amountIn);

        (bool success, bytes memory result) = params.targetContract.call(params.swapCallData);

        IERC20(params.tokenIn).forceApprove(params.targetContract, 0);

        if (!success) {
            revert SwapFailed(result);
        }

        uint256 tokenInBalanceAfter = IERC20(params.tokenIn).balanceOf(address(this));
        uint256 tokenOutBalanceAfter = IERC20(params.tokenOut).balanceOf(address(this));

        uint256 actualAmountIn = tokenInBalanceBefore - tokenInBalanceAfter;
        if (actualAmountIn != params.amountIn) {
            revert UnexpectedAmountIn(params.amountIn, actualAmountIn);
        }

        amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
        if (amountOut < params.minAmountOut) {
            revert SlippageExceeded(amountOut, params.minAmountOut);
        }

        emit SwapExecuted(msg.sender, params.tokenIn, params.tokenOut, actualAmountIn, amountOut, params.targetContract);

        return amountOut;
    }

    /**
     * @notice Validate swap parameters
     * @param params Swap parameters to validate
     */
    function _validateSwapParams(SwapParams calldata params) private view {
        MoreVaultsLib.validateAddressWhitelisted(params.targetContract);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        if (!ds.isAssetAvailable[params.tokenIn]) {
            revert InvalidTokenIn(params.tokenIn);
        }

        if (!ds.isAssetAvailable[params.tokenOut]) {
            revert InvalidTokenOut(params.tokenOut);
        }

        if (params.tokenIn == params.tokenOut) {
            revert SameToken(params.tokenIn);
        }

        if (params.amountIn == 0) {
            revert ZeroAmount();
        }

        if (params.minAmountOut == 0) {
            revert ZeroMinAmount();
        }
    }

    /**
     * @notice Get total assets of the vault
     * @return Total assets in underlying
     */
    function _getTotalAssets() private view returns (uint256) {
        (bool success, bytes memory result) = address(this).staticcall(abi.encodeWithSignature("totalAssets()"));

        if (!success) {
            revert("TotalAssetsFailed");
        }

        return abi.decode(result, (uint256));
    }
}
