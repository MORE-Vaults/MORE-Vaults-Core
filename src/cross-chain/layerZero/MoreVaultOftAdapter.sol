// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice OFTAdapter uses a deployed ERC-20 token and SafeERC20 to interact with the OFTCore contract.
contract MoreVaultOftAdapter is OFTAdapter {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the caller is not the owner of the inner token
    error Unauthorized();

    /// @notice Event emitted when tokens are rescued
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Error thrown when attempting to rescue to zero address
    error ZeroAddress();

    /// @notice Error thrown when attempting to rescue more tokens than available
    error InsufficientBalance();

    /// @notice Error thrown when native currency transfer fails
    error NativeTransferFailed();

    constructor(address _token, address _lzEndpoint, address _owner)
        OFTAdapter(_token, _lzEndpoint, _owner)
        Ownable(_owner)
    {}

    /**
     * @notice Rescue accumulated dust tokens that remain locked due to LayerZero's decimal normalization
     * @dev LayerZero normalizes token amounts to sharedDecimals (6 decimals), which truncates
     *      the least significant digits for tokens with higher precision (e.g., 18 decimals).
     *      This dust accumulates in the adapter contract and cannot be recovered through normal operations.
     * @param _token The address of the token to rescue (use address(0) for native currency/ETH)
     * @param _to The address to send the rescued tokens to
     * @param _amount The amount of tokens to rescue (use type(uint256).max to rescue all available balance)
     */
    function rescue(address _token, address payable _to, uint256 _amount) external {
        if (Ownable(address(innerToken)).owner() != msg.sender) revert Unauthorized();
        if (_to == address(0)) revert ZeroAddress();

        if (_token == address(0)) {
            // Rescue native currency (ETH)
            uint256 balance = address(this).balance;
            uint256 amountToRescue = _amount == type(uint256).max ? balance : _amount;
            if (amountToRescue > balance) revert InsufficientBalance();

            (bool success,) = _to.call{value: amountToRescue}("");
            if (!success) revert NativeTransferFailed();
            emit Rescued(address(0), _to, amountToRescue);
        } else {
            // Rescue ERC20 token
            uint256 balance = IERC20(_token).balanceOf(address(this));
            uint256 amountToRescue = _amount == type(uint256).max ? balance : _amount;
            if (amountToRescue > balance) revert InsufficientBalance();

            IERC20(_token).safeTransfer(_to, amountToRescue);
            emit Rescued(_token, _to, amountToRescue);
        }
    }
}
