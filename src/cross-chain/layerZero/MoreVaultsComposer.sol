// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IOFT, SendParam, MessagingFee, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMoreVaultsComposer} from "../../interfaces/LayerZero/IMoreVaultsComposer.sol";
import {IBridgeFacet} from "../../interfaces/facets/IBridgeFacet.sol";
import {MoreVaultsLib} from "../../libraries/MoreVaultsLib.sol";
import {LzAdapter} from "./LzAdapter.sol";
import {IConfigurationFacet} from "../../interfaces/facets/IConfigurationFacet.sol";
import {IVaultFacet} from "../../interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../interfaces/IVaultsFactory.sol";

/**
 * @title MoreVaultsComposer - MoreVaults Composer (deposit-only)
 * @notice Cross-chain composer that supports only cross chain deposits of assets from spoke chains to the hub vault.
 * @dev Refunds are enabled to EOA addresses only on the source chain.
 */
contract MoreVaultsComposer is IMoreVaultsComposer, ReentrancyGuard, Initializable {
    using OFTComposeMsgCodec for bytes;
    using OFTComposeMsgCodec for bytes32;
    using SafeERC20 for IERC20;

    IVaultFacet public VAULT;
    IVaultsFactory public VAULT_FACTORY;
    address public SHARE_OFT;
    address public SHARE_ERC20;

    address public ENDPOINT;
    uint32 public VAULT_EID;

    /// @dev Structure to store pending async deposit information
    struct PendingDeposit {
        bytes32 depositor;
        address tokenAddress;
        address oftAddress;
        uint256 assetAmount;
        address refundAddress;
        uint256 msgValue;
        uint32 srcEid;
        SendParam sendParam;
    }

    /// @dev Mapping from deposit ID to pending deposit info
    mapping(bytes32 => PendingDeposit) public pendingDeposits;

    // Async deposit lifecycle is tracked via callbacks and the Deposited event in the interface
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with vault and OFT token addresses
     * @param _vault The address of the MoreVaults vault contract
     * @param _shareOFT The address of the share OFT contract (must be an adapter)
     * @param _vaultFactory The address of the vault factory contract
     *
     * Requirements:
     * - Share token must be the vault itself
     * - Share OFT must be an adapter (approvalRequired() returns true)
     */
    function initialize(address _vault, address _shareOFT, address _vaultFactory) external initializer {
        VAULT = IVaultFacet(_vault);
        SHARE_OFT = _shareOFT;
        SHARE_ERC20 = IOFT(SHARE_OFT).token();
        VAULT_FACTORY = IVaultsFactory(_vaultFactory);
        ENDPOINT = address(IOAppCore(SHARE_OFT).endpoint());
        VAULT_EID = ILayerZeroEndpointV2(ENDPOINT).eid();

        // Validate initialization
        if (SHARE_ERC20 != address(VAULT)) {
            revert ShareTokenNotVault(SHARE_ERC20, address(VAULT));
        }

        /// @dev ShareOFT must be an OFT adapter. We can infer this by checking 'approvalRequired()'.
        /// @dev burn() on tokens when a user sends changes totalSupply() which the asset:share ratio depends on.
        if (!IOFT(SHARE_OFT).approvalRequired()) {
            revert ShareOFTNotAdapter(SHARE_OFT);
        }

        /// @dev Approve the share adapter with the share tokens held by this contract
        IERC20(SHARE_ERC20).forceApprove(_shareOFT, type(uint256).max);
    }

    /**
     * @notice Quotes the send operation for the given OFT and SendParam
     * @dev Revert on slippage will be thrown by the OFT and not _assertSlippage
     * @param _from The "sender address" used for the quote
     * @param _targetOFT The OFT contract address to quote
     * @param _vaultInAmount The amount of tokens to send to the vault
     * @param _sendParam The parameters for the send operation
     * @return MessagingFee The estimated fee for the send operation
     * @dev This function can be overridden to implement custom quoting logic
     */
    function quoteSend(address _from, address _targetOFT, uint256 _vaultInAmount, SendParam memory _sendParam)
        external
        view
        virtual
        returns (MessagingFee memory)
    {
        /// @dev Only deposit flow is supported; quoting is only valid for SHARE_OFT (hub → destination hop)
        if (_targetOFT != SHARE_OFT) revert NotImplemented();

        uint256 maxDeposit = VAULT.maxDeposit(_from);
        if (_vaultInAmount > maxDeposit) {
            revert ERC4626.ERC4626ExceededMaxDeposit(_from, _vaultInAmount, maxDeposit);
        }

        _sendParam.amountLD = VAULT.previewDeposit(_vaultInAmount);
        return IOFT(_targetOFT).quoteSend(_sendParam, false);
    }

    /**
     * @notice Handles LayerZero compose operations for vault transactions with automatic refund functionality
     * @dev This composer is designed to handle refunds to an EOA address and not a contract
     * @dev Any revert in handleCompose() causes a refund back to the src EXCEPT for InsufficientMsgValue
     * @param _composeSender The OFT contract address used for refunds, must OFT that registered on the LZ_ADAPTER and corresponds to an asset that is depositable
     * @param _guid LayerZero's unique tx id (created on the source tx)
     * @param _message Decomposable bytes object into [composeHeader][composeMessage]
     */
    function lzCompose(
        address _composeSender, // The OFT used on refund, also the vaultIn token.
        bytes32 _guid,
        bytes calldata _message, // expected to contain a composeMessage = abi.encode(SendParam hopSendParam,uint256 minMsgValue)
        address, /*_executor*/
        bytes calldata /*_extraData*/
    )
        external
        payable
        virtual
        override
    {
        if (msg.sender != ENDPOINT) revert OnlyEndpoint(msg.sender);
        if (
            !LzAdapter(VAULT_FACTORY.lzAdapter()).isTrustedOFT(_composeSender)
                || !IConfigurationFacet(address(VAULT)).isAssetDepositable(IOFT(_composeSender).token())
        ) {
            revert InvalidComposeCaller(_composeSender);
        }

        bytes32 composeFrom = _message.composeFrom();
        uint256 amount = _message.amountLD();
        bytes memory composeMsg = _message.composeMsg();
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);

        /// @dev try...catch to handle the compose operation. if it fails we refund the user
        try this.handleCompose{value: msg.value}(_composeSender, composeFrom, composeMsg, amount, srcEid) {
            emit Sent(_guid);
        } catch (bytes memory _err) {
            /// @dev A revert where the msg.value passed is lower than the min expected msg.value is handled separately
            /// This is because it is possible to re-trigger from the endpoint the compose operation with the right msg.value
            if (bytes4(_err) == InsufficientMsgValue.selector) {
                assembly {
                    revert(add(32, _err), mload(_err))
                }
            }

            _refund(_composeSender, _message, amount, tx.origin);
            emit Refunded(_guid);
        }
    }

    /**
     * @notice Handles the compose operation for OFT (Omnichain Fungible Token) transactions
     * @dev This function can only be called by the contract itself (self-call restriction)
     *      Decodes the compose message to extract SendParam and minimum message value
     *      Routes to either deposit or redeem flow based on the input OFT token type
     * @param _oftIn The OFT token whose funds have been received in the lzReceive associated with this lzTx
     * @param _composeFrom The bytes32 identifier of the compose sender
     * @param _composeMsg The encoded message containing SendParam and minMsgValue
     * @param _amount The amount of tokens received in the lzReceive associated with this lzTx
     */
    function handleCompose(
        address _oftIn,
        bytes32 _composeFrom,
        bytes memory _composeMsg,
        uint256 _amount,
        uint32 _srcEid
    ) external payable {
        /// @dev Can only be called by self
        if (msg.sender != address(this)) revert OnlySelf(msg.sender);

        /// @dev SendParam defines how the composer will handle the user's funds
        /// @dev The minMsgValue is the minimum amount of msg.value that must be sent, failing to do so will revert and the transaction will be retained in the endpoint for future retries
        (SendParam memory sendParam, uint256 minMsgValue) = abi.decode(_composeMsg, (SendParam, uint256));
        if (msg.value < minMsgValue) {
            revert InsufficientMsgValue(minMsgValue, msg.value);
        }
        if (IVaultFacet(address(VAULT)).paused()) {
            revert VaultIsPaused();
        }
        // Check if this is a cross-chain vault and oracle accounting is disabled
        // If oracle accounting is enabled, use sync path even for cross-chain vaults
        bool isCrossChainVault = VAULT_FACTORY.isCrossChainVault(uint32(VAULT_EID), address(VAULT));
        bool useAsyncFlow = isCrossChainVault && !IBridgeFacet(address(VAULT)).oraclesCrossChainAccounting();

        if (useAsyncFlow) {
            _initDeposit(_composeFrom, IOFT(_oftIn).token(), _oftIn, _amount, sendParam, tx.origin, _srcEid);
        } else {
            _depositAndSend(_composeFrom, IOFT(_oftIn).token(), _amount, sendParam, tx.origin);
        }
    }

    /**
     * @notice Sends deposit shares after successful request execution
     * @param _guid The unique identifier of the pending deposit
     * @dev This function is called after the request action has been executed successfully
     * @dev Retrieves the execution result (shares) and sends them to the destination
     */
    function sendDepositShares(bytes32 _guid) external virtual nonReentrant {
        if (msg.sender != address(VAULT) && msg.sender != address(VAULT_FACTORY.lzAdapter())) {
            revert OnlyVaultOrLzAdapter(msg.sender);
        }

        PendingDeposit memory deposit = pendingDeposits[_guid];
        if (deposit.assetAmount == 0) revert DepositNotFound(_guid);

        // Request action already executed in executeRequest
        // Slippage check was already performed in _executeRequest
        // Get execution result (number of shares)
        uint256 shares = IBridgeFacet(address(VAULT)).getFinalizationResult(_guid);
        deposit.sendParam.amountLD = shares;
        deposit.sendParam.minAmountLD = 0;

        delete pendingDeposits[_guid];

        uint256 amountSentLD = _send(SHARE_OFT, deposit.sendParam, deposit.refundAddress, deposit.msgValue);
        emit Deposited(
            deposit.depositor, deposit.sendParam.to, deposit.sendParam.dstEid, deposit.assetAmount, amountSentLD
        );
    }

    function refundDeposit(bytes32 _guid) external payable virtual nonReentrant {
        if (msg.sender != address(VAULT) && msg.sender != address(VAULT_FACTORY.lzAdapter())) {
            revert OnlyVaultOrLzAdapter(msg.sender);
        }
        PendingDeposit memory deposit = pendingDeposits[_guid];
        if (deposit.assetAmount == 0) revert DepositNotFound(_guid);

        delete pendingDeposits[_guid];

        // Decrease approve for vault by deposit amount (supports parallel deposits)
        // If request execution didn't occur, approve wasn't used and should be decreased
        // If request execution occurred, approve was already automatically decreased via safeTransferFrom
        uint256 currentAllowance = IERC20(deposit.tokenAddress).allowance(address(this), address(VAULT));
        if (currentAllowance >= deposit.assetAmount) {
            IERC20(deposit.tokenAddress).safeDecreaseAllowance(address(VAULT), deposit.assetAmount);
        } else if (currentAllowance > 0) {
            // If approve is less than expected (partially used), decrease by available amount
            IERC20(deposit.tokenAddress).safeDecreaseAllowance(address(VAULT), currentAllowance);
        }

        // cross-chain refund back to origin
        SendParam memory refundSendParam;
        refundSendParam.dstEid = deposit.srcEid;
        refundSendParam.to = deposit.depositor;
        refundSendParam.amountLD = deposit.assetAmount;

        // Combine stored msgValue with additional msg.value to handle fee volatility
        uint256 totalMsgValue = deposit.msgValue + msg.value;

        IERC20(deposit.tokenAddress).forceApprove(deposit.oftAddress, deposit.assetAmount);
        IOFT(deposit.oftAddress).send{value: totalMsgValue}(
            refundSendParam, MessagingFee(totalMsgValue, 0), deposit.refundAddress
        );
        IERC20(deposit.tokenAddress).forceApprove(deposit.oftAddress, 0);
        emit Refunded(_guid);
    }

    function depositAndSend(
        address _tokenAddress,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress
    ) external payable virtual nonReentrant {
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _assetAmount);
        _depositAndSend(
            OFTComposeMsgCodec.addressToBytes32(msg.sender), _tokenAddress, _assetAmount, _sendParam, _refundAddress
        );
    }

    /**
     * @param _amountLD The amount of tokens to send
     * @param _minAmountLD The minimum amount of tokens that must be sent to avoid slippage
     * @notice This function checks if the amount sent is less than the minimum amount
     *         If it is, it reverts with SlippageExceeded error
     * @notice This function can be overridden to implement custom slippage logic
     */
    function _assertSlippage(uint256 _amountLD, uint256 _minAmountLD) internal view virtual {
        if (_amountLD < _minAmountLD) {
            revert SlippageExceeded(_amountLD, _minAmountLD);
        }
    }

    /**
     * @dev Internal function to sync deposit assets into the vault and send shares to the destination
     * @param _depositor The depositor (bytes32 format to account for non-evm addresses)
     * @param _tokenAddress The address of the token to deposit
     * @param _assetAmount The number of assets to deposit
     * @param _sendParam Parameter that defines how to send the shares
     */
    function _depositAndSend(
        bytes32 _depositor,
        address _tokenAddress,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress
    ) internal virtual {
        uint256 shareAmount;
        IERC20(_tokenAddress).forceApprove(address(VAULT), _assetAmount);
        if (_tokenAddress == IERC4626(VAULT).asset()) {
            shareAmount = VAULT.deposit(_assetAmount, address(this));
        } else {
            address[] memory tokens = new address[](1);
            tokens[0] = _tokenAddress;
            uint256[] memory assets = new uint256[](1);
            assets[0] = _assetAmount;
            shareAmount = VAULT.deposit(tokens, assets, address(this));
        }
        IERC20(_tokenAddress).forceApprove(address(VAULT), 0);
        _assertSlippage(shareAmount, _sendParam.minAmountLD);

        _sendParam.amountLD = shareAmount;
        _sendParam.minAmountLD = 0;

        uint256 amountSentLD = _send(SHARE_OFT, _sendParam, _refundAddress, msg.value);
        emit Deposited(_depositor, _sendParam.to, _sendParam.dstEid, _assetAmount, amountSentLD);
    }

    function initDeposit(
        bytes32 _depositor,
        address _tokenAddress,
        address _oftAddress,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint32 _srcEid
    ) external payable virtual nonReentrant {
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _assetAmount);
        _initDeposit(_depositor, _tokenAddress, _oftAddress, _assetAmount, _sendParam, _refundAddress, _srcEid);
    }

    /**
     * @dev Internal function that initiates an async deposit operation
     * @param _depositor The depositor (bytes32 format to account for non-evm addresses)
     * @param _tokenAddress The address of the token to deposit
     * @param _oftAddress The address of the OFT contract to use for sending
     * @param _assetAmount The number of assets to deposit
     * @param _sendParam Parameter that defines how to send the shares
     * @param _refundAddress Address to receive excess payment of the LZ fees
     * @param _srcEid The source endpoint ID
     * @notice This function first deposits the assets to mint shares, validates the shares meet minimum slippage requirements,
     *         then sends the minted shares cross-chain using the OFT (Omnichain Fungible Token) protocol
     * @notice The _sendParam.amountLD is updated to the actual share amount minted, and minAmountLD is reset to 0 for the send operation
     */
    function _initDeposit(
        bytes32 _depositor,
        address _tokenAddress,
        address _oftAddress,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint32 _srcEid
    ) internal virtual {
        uint256 readFee = IBridgeFacet(address(VAULT)).quoteAccountingFee("");
        if (msg.value < readFee) {
            revert InsufficientMsgValue(readFee, msg.value);
        }
        if (IOFT(_oftAddress).token() != _tokenAddress) {
            revert NotATokenOfOFT();
        }

        // Increase approve BEFORE creating request so it's available for request execution
        // Use safeIncreaseAllowance to support parallel deposits
        // Request execution occurs in executeRequest and calls deposit,
        // which takes tokens via safeTransferFrom using approve
        IERC20(_tokenAddress).safeIncreaseAllowance(address(VAULT), _assetAmount);

        MoreVaultsLib.ActionType actionType;
        bytes memory actionCallData;
        if (_tokenAddress == IERC4626(VAULT).asset()) {
            actionType = MoreVaultsLib.ActionType.DEPOSIT;
            actionCallData = abi.encode(uint256(_assetAmount), address(this));
        } else {
            actionType = MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT;
            address[] memory tokens = new address[](1);
            tokens[0] = _tokenAddress;
            uint256[] memory assets = new uint256[](1);
            assets[0] = _assetAmount;
            actionCallData = abi.encode(tokens, assets, address(this));
        }
        // Pass minAmountOut for slippage check in _executeRequest
        bytes32 guid = IBridgeFacet(address(VAULT)).initVaultActionRequest{value: readFee}(
            actionType, actionCallData, _sendParam.minAmountLD, ""
        );
        pendingDeposits[guid] = PendingDeposit(
            _depositor,
            _tokenAddress,
            _oftAddress,
            _assetAmount,
            _refundAddress,
            msg.value - readFee,
            _srcEid,
            _sendParam
        );
    }

    /**
     * @dev Internal function that handles token transfer to the recipient
     * @dev If the destination eid is the same as the current eid, it transfers the tokens directly to the recipient
     * @dev If the destination eid is different, it sends a LayerZero cross-chain transaction
     * @param _oft The OFT contract address to use for sending
     * @param _sendParam The parameters for the send operation
     * @param _refundAddress Address to receive excess payment of the LZ fees
     * @return amountSentLD The amount actually sent (after LayerZero normalization for cross-chain, equal to amountLD for local)
     */
    function _send(address _oft, SendParam memory _sendParam, address _refundAddress, uint256 _msgValue)
        internal
        returns (uint256 amountSentLD)
    {
        if (_sendParam.dstEid == VAULT_EID) {
            if (msg.value > 0) revert NoMsgValueExpected();
            IERC20(SHARE_ERC20).safeTransfer(_sendParam.to.bytes32ToAddress(), _sendParam.amountLD);
            return _sendParam.amountLD;
        } else {
            // crosschain send - LayerZero normalizes the amount, so we get the actual sent amount from the receipt
            (, OFTReceipt memory oftReceipt) =
                IOFT(_oft).send{value: _msgValue}(_sendParam, MessagingFee(_msgValue, 0), _refundAddress);
            return oftReceipt.amountSentLD;
        }
    }

    /**
     * @dev Internal function to refund input tokens to sender on source during a failed transaction
     * @param _oft The OFT contract address used for refunding
     * @param _message The original message that was sent
     * @param _amount The amount of tokens to refund
     * @param _refundAddress Address to receive the refund
     */
    function _refund(address _oft, bytes calldata _message, uint256 _amount, address _refundAddress) internal virtual {
        /// @dev Extracted from the _message header. Will always be part of the _message since it is created by lzReceive
        SendParam memory refundSendParam;
        refundSendParam.dstEid = OFTComposeMsgCodec.srcEid(_message);
        refundSendParam.to = OFTComposeMsgCodec.composeFrom(_message);
        refundSendParam.amountLD = _amount;

        IERC20(IOFT(_oft).token()).forceApprove(_oft, _amount);
        IOFT(_oft).send{value: msg.value}(refundSendParam, MessagingFee(msg.value, 0), _refundAddress);
        IERC20(IOFT(_oft).token()).forceApprove(_oft, 0);
    }

    receive() external payable {}
}
