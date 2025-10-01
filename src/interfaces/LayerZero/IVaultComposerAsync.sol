// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC4626, IVaultFacet} from "../facets/IVaultFacet.sol";

import {IOAppComposer} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

interface IVaultComposerAsync is IOAppComposer {
    /// ========================== EVENTS =====================================
    event Sent(bytes32 indexed guid); // 0x27b5aea9
    event Refunded(bytes32 indexed guid); // 0xfe509803

    event Deposited(bytes32 sender, bytes32 recipient, uint32 dstEid, uint256 assetAmt, uint256 shareAmt); // 0xa53b96f2

    /// ========================== Error Messages =====================================
    error ShareOFTNotAdapter(address shareOFT); // 0xfc1514ae
    error ShareTokenNotVault(address shareERC20, address vault); // 0x0e178ab6
    error AssetTokenNotVaultAsset(address assetERC20, address vaultAsset); // 0xba9d665f
    error NotImplemented(); //
    error OnlyEndpoint(address caller);
    // 0x91ac5e4f
    error OnlySelf(address caller); // 0xa19dbf00
    error OnlyValidComposeCaller(address caller); // 0x84fb3f0d
    error OnlyVault(address caller); // custom
    error DepositNotFound(bytes32 guid); // custom

    error InsufficientMsgValue(uint256 expectedMsgValue, uint256 actualMsgValue); // 0x7cb769dc
    error NoMsgValueExpected(); // 0x7578d2bd

    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD); // 0x71c4efed

    /// ========================== GLOBAL VARIABLE FUNCTIONS =====================================
    function VAULT() external view returns (IVaultFacet);

    function SHARE_OFT() external view returns (address);

    function SHARE_ERC20() external view returns (address);

    function ENDPOINT() external view returns (address);

    function VAULT_EID() external view returns (uint32);

    /// ========================== Proxy OFT (deposit-only) =====================================

    /**
     * @notice Quotes the send operation for the given OFT and SendParam
     * @param from The "sender address" used for the quote
     * @param targetOft The OFT contract address to quote
     * @param vaultInAmount The amount of tokens to send to the vault
     * @param sendParam The parameters for the send operation
     * @return MessagingFee The estimated fee for the send operation
     * @dev This function can be overridden to implement custom quoting logic
     */
    function quoteSend(address from, address targetOft, uint256 vaultInAmount, SendParam memory sendParam)
        external
        view
        returns (MessagingFee memory);

    function completeDeposit(bytes32 guid) external;

    function refundDeposit(bytes32 guid) external payable;

    /// ========================== Receive =====================================
    receive() external payable;
}
