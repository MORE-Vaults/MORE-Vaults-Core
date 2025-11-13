// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

/**
 * @title IDexAggregatorFacet
 * @notice Interface for generic DEX aggregator swap functionality
 * @dev Enables vault curators to execute token swaps through any whitelisted DEX aggregator
 */
interface IDexAggregatorFacet is IGenericMoreVaultFacetInitializable {
    // ==================== STRUCTS ====================

    /**
     * @notice Parameters for executing a single swap
     * @param targetContract Address of the DEX aggregator contract (must be whitelisted)
     * @param tokenIn Address of the token to sell
     * @param tokenOut Address of the token to buy
     * @param amountIn Exact amount of tokenIn to swap
     * @param minAmountOut Minimum acceptable amount of tokenOut (slippage protection)
     * @param swapCallData Complete calldata to execute on the target contract
     */
    struct SwapParams {
        address targetContract;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes swapCallData;
    }

    /**
     * @notice Parameters for executing multiple swaps in a batch
     * @param swaps Array of individual swap parameters
     */
    struct BatchSwapParams {
        SwapParams[] swaps;
    }

    // ==================== ERRORS ====================

    /**
     * @notice Thrown when target contract is not whitelisted in registry
     * @param target Address of the invalid target contract
     */
    error InvalidSwapTarget(address target);

    /**
     * @notice Thrown when tokenIn is not an available asset in the vault
     * @param token Address of the invalid input token
     */
    error InvalidTokenIn(address token);

    /**
     * @notice Thrown when tokenOut is not an available asset in the vault
     * @param token Address of the invalid output token
     */
    error InvalidTokenOut(address token);

    /**
     * @notice Thrown when tokenIn and tokenOut are the same
     * @param token Address of the token
     */
    error SameToken(address token);

    /**
     * @notice Thrown when amountIn is zero
     */
    error ZeroAmount();

    /**
     * @notice Thrown when minAmountOut is zero
     */
    error ZeroMinAmount();

    /**
     * @notice Thrown when actual output is less than minimum expected
     * @param received Actual amount received
     * @param minExpected Minimum amount expected
     */
    error SlippageExceeded(uint256 received, uint256 minExpected);

    /**
     * @notice Thrown when the swap call to aggregator fails
     * @param reason Revert reason from the aggregator
     */
    error SwapFailed(bytes reason);

    /**
     * @notice Thrown when actual amountIn spent differs from expected
     * @param expected Expected amount to spend
     * @param actual Actual amount spent
     */
    error UnexpectedAmountIn(uint256 expected, uint256 actual);

    /**
     * @notice Thrown when quote call to quoter contract fails
     * @param reason Revert reason from the quoter
     */
    error QuoteFailed(bytes reason);

    /**
     * @notice Thrown when global slippage exceeds maximum allowed
     * @param slippagePercent Actual slippage percentage (basis points)
     * @param maxSlippagePercent Maximum allowed slippage percentage (basis points)
     */
    error GlobalSlippageExceeded(uint256 slippagePercent, uint256 maxSlippagePercent);

    // ==================== EVENTS ====================

    /**
     * @notice Emitted when a swap is executed successfully
     * @param curator Address of the curator who executed the swap
     * @param tokenIn Address of the token sold
     * @param tokenOut Address of the token bought
     * @param amountIn Amount of tokenIn sold
     * @param amountOut Amount of tokenOut received
     * @param targetContract Address of the aggregator used
     */
    event SwapExecuted(
        address indexed curator,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address targetContract
    );

    /**
     * @notice Emitted when a batch of swaps is executed successfully
     * @param curator Address of the curator who executed the batch
     * @param swapCount Number of swaps executed
     * @param totalValueBefore Total vault value before batch (in underlying)
     * @param totalValueAfter Total vault value after batch (in underlying)
     */
    event BatchSwapExecuted(
        address indexed curator,
        uint256 swapCount,
        uint256 totalValueBefore,
        uint256 totalValueAfter
    );

    // ==================== FUNCTIONS ====================

    /**
     * @notice Returns the name of this facet
     * @return The facet name
     */
    function facetName() external pure returns (string memory);

    /**
     * @notice Accounting function for totalAssets calculation
     * @dev Always returns (0, true) since swaps are atomic and facet does not hold assets
     * @return sum Always 0
     * @return isPositive Always true
     */
    function accountingDexAggregatorFacet() external view returns (uint256 sum, bool isPositive);

    /**
     * @notice Get quote from any quoter contract using generic staticcall
     * @dev Returns raw bytes - caller must decode based on quoter's interface
     * @param quoter Address of the quoter contract (must be whitelisted)
     * @param quoteCallData Complete calldata for the quote function
     * @return quoteResult Raw bytes returned by the quoter
     */
    function getGenericQuote(address quoter, bytes calldata quoteCallData)
        external
        view
        returns (bytes memory quoteResult);

    /**
     * @notice Execute a single swap through any DEX aggregator
     * @dev Only callable by curator or owner
     * @dev Validates all inputs and checks balance changes
     * @param params Swap parameters
     * @return amountOut Actual amount of tokenOut received
     */
    function executeSwap(SwapParams calldata params) external returns (uint256 amountOut);

    /**
     * @notice Execute multiple swaps atomically with global slippage check
     * @dev Only callable by curator or owner
     * @dev Validates that total vault value does not decrease beyond maxSlippagePercent
     * @param params Batch swap parameters
     * @return amountsOut Array of actual amounts received for each swap
     */
    function executeBatchSwap(BatchSwapParams calldata params) external returns (uint256[] memory amountsOut);
}
