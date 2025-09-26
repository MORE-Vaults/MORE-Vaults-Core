// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {AddressCast} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import {ReadCodecV1, EVMCallRequestV1, EVMCallComputeV1} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import {IBridgeAdapter} from "../../interfaces/IBridgeAdapter.sol";
import {IMoreVaultsRegistry} from "../../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../interfaces/IVaultsFactory.sol";
import {MessagingFee, MessagingReceipt, ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IVaultFacet} from "../../interfaces/facets/IVaultFacet.sol";
import {IBridgeFacet} from "../../interfaces/facets/IBridgeFacet.sol";
import {ILzComposer} from "../../interfaces/ILzComposer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MoreVaultsLib} from "../../libraries/MoreVaultsLib.sol";

contract LzAdapter is
    IBridgeAdapter,
    OAppRead,
    OAppOptionsType3,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;
    using Math for uint256;

    error InvalidOFTToken();
    error InvalidLayerZeroEid();
    error NoResponses();
    error UnsupportedChain(uint16);
    error ZeroAddress();
    error ArrayLengthMismatch();

    struct CallInfo {
        address vault;
        address initiator;
    }

    /// @notice Emitted when the data is received.
    /// @param data The value of the public state variable.
    event DataReceived(uint256 data);

    event ComposerUpdated(address indexed composer);

    event ChainIdToEidUpdated(uint16 indexed chainId, uint32 indexed eid);

    event TrustedOFTUpdated(address indexed oft, bool trusted);

    event BridgeExecuted(
        address indexed sender,
        uint256 indexed destChainId,
        address indexed destVault,
        address oftToken,
        uint256 amount,
        uint256 fee,
        uint32 layerZeroEid
    );

    IVaultsFactory public immutable vaultsFactory;
    IMoreVaultsRegistry public immutable vaultsRegistry;

    /// @notice LayerZero read channel ID.
    uint32 public READ_CHANNEL;

    /// @notice Message type for the read operation.
    uint16 public constant READ_TYPE = 1;

    mapping(uint16 => uint32) private _chainIdToEid;
    mapping(uint64 => CallInfo) private _nonceToCallInfo;

    address public composer;

    // Security configurations
    uint256 public slippageBps = 100; // 1% default slippage

    // Chain management
    mapping(uint256 => bool) public chainPaused;

    // OFT management
    mapping(address => bool) private _trustedOFTs;
    address[] private _trustedOFTsList;

    /**
     * @notice Constructor to initialize the OAppRead contract.
     *
     * @param _endpoint The LayerZero endpoint contract address.
     * @param _delegate The address that will have ownership privileges.
     * @param _readChannel The LayerZero read channel ID.
     * @param _composer The composer contract address.
     */
    constructor(
        address _endpoint,
        address _delegate,
        uint32 _readChannel,
        address _composer,
        address _vaultsFactory,
        address _vaultsRegistry
    ) OAppRead(_endpoint, _delegate) Ownable(_delegate) {
        READ_CHANNEL = _readChannel;
        _setPeer(_readChannel, AddressCast.toBytes32(address(this)));
        composer = _composer;

        vaultsFactory = IVaultsFactory(_vaultsFactory);
        vaultsRegistry = IMoreVaultsRegistry(_vaultsRegistry);
    }

    /**
     * @notice Return if the adapter is paused
     */
    function paused()
        public
        view
        override(IBridgeAdapter, Pausable)
        returns (bool)
    {
        return super.paused();
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function chainIdToEid(uint16 chainId) external view returns (uint32) {
        return _chainIdToEid[chainId];
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function getSupportedChains()
        external
        view
        returns (uint256[] memory chains, bool[] memory statuses)
    {
        // We need to track configured chains for efficiency
        // For now, iterate through common chain IDs
        uint256[] memory commonChainIds = new uint256[](10);
        commonChainIds[0] = 1; // Ethereum
        commonChainIds[1] = 137; // Polygon
        commonChainIds[2] = 56; // BSC
        commonChainIds[3] = 43114; // Avalanche
        commonChainIds[4] = 250; // Fantom
        commonChainIds[5] = 42161; // Arbitrum
        commonChainIds[6] = 10; // Optimism
        commonChainIds[7] = 8453; // Base
        commonChainIds[8] = 324; // zkSync
        commonChainIds[9] = 59144; // Linea

        // Count supported chains
        uint256 count = 0;
        for (uint256 i = 0; i < commonChainIds.length; i++) {
            if (_chainIdToEid[uint16(commonChainIds[i])] != 0) {
                count++;
            }
        }

        uint256[] memory allChains = new uint256[](count);
        bool[] memory allStatuses = new bool[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < commonChainIds.length; i++) {
            if (_chainIdToEid[uint16(commonChainIds[i])] != 0) {
                allChains[index] = commonChainIds[i];
                allStatuses[index] = !chainPaused[commonChainIds[i]];
                index++;
            }
        }

        return (allChains, allStatuses);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function getChainConfig(
        uint256 chainId
    )
        external
        view
        returns (bool supported, bool isPaused, string memory additionalInfo)
    {
        bool isSupported = _chainIdToEid[uint16(chainId)] != 0;
        return (isSupported, chainPaused[chainId], "");
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function quoteBridgeFee(
        bytes calldata bridgeSpecificParams
    ) external view returns (uint256 nativeFee) {
        (
            address oftTokenAddress,
            uint256 dstChainId,
            uint32 lzEid,
            uint256 amount,
            address dstVaultAddress
        ) = abi.decode(
                bridgeSpecificParams,
                (address, uint256, uint32, uint256, address)
            );
        return
            _quoteFee(
                oftTokenAddress,
                dstChainId,
                lzEid,
                amount,
                dstVaultAddress
            );
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function quoteReadFee(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions
    ) external view returns (MessagingFee memory fee) {
        return
            _quote(
                READ_CHANNEL,
                _getCmd(vaultInfos),
                combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions),
                false
            );
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function pauseChain(uint256 chainId) external onlyOwner {
        chainPaused[chainId] = true;
        emit ChainPausedEvent(chainId);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function unpauseChain(uint256 chainId) external onlyOwner {
        chainPaused[chainId] = false;
        emit ChainUnpausedEvent(chainId);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setSupportedChain(
        uint256 chainId,
        bool supported
    ) external onlyOwner {
        if (supported) {
            // Chain is supported if it has an EID, nothing to set here
            // Use setChainIdToEid instead to enable chains
            return;
        } else {
            // To remove support, set EID to 0
            _chainIdToEid[uint16(chainId)] = 0;
            emit ChainIdToEidUpdated(uint16(chainId), 0);
        }
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setSlippage(uint256 newSlippageBps) external onlyOwner {
        require(newSlippageBps <= 10000, "Slippage too high");
        slippageBps = newSlippageBps;
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setReadChannel(
        uint32 _channelId,
        bool _active
    ) public override(IBridgeAdapter, OAppRead) onlyOwner {
        _setPeer(
            _channelId,
            _active ? AddressCast.toBytes32(address(this)) : bytes32(0)
        );
        READ_CHANNEL = _channelId;
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setChainIdToEid(uint16 chainId, uint32 eid) external onlyOwner {
        _chainIdToEid[chainId] = eid;
        emit ChainIdToEidUpdated(chainId, eid);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setComposer(address _composer) external onlyOwner {
        composer = _composer;

        emit ComposerUpdated(composer);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function executeBridging(
        bytes calldata bridgeSpecificParams
    ) external payable whenNotPaused nonReentrant {
        (
            address oftTokenAddress,
            uint256 dstChainId,
            uint32 lzEid,
            uint256 amount,
            address dstVaultAddress
        ) = abi.decode(
                bridgeSpecificParams,
                (address, uint256, uint32, uint256, address)
            );
        _executeBridging(
            oftTokenAddress,
            dstChainId,
            lzEid,
            amount,
            dstVaultAddress
        );
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function initiateCrossChainAccounting(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt) {
        bytes memory cmd = _getCmd(vaultInfos);

        _nonceToCallInfo[receipt.nonce] = CallInfo({
            vault: msg.sender,
            initiator: _initiator
        });

        receipt = _lzSend(
            READ_CHANNEL,
            cmd,
            combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions),
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );
    }

    /// @notice Reduces multiple mapped responses to a single average value.
    /// @param _responses Array of encoded totalAssetsUsd responses from each chain.
    /// @return Encoded sum of all responses.
    function lzReduce(
        bytes calldata,
        bytes[] calldata _responses
    ) external pure returns (bytes memory) {
        if (_responses.length == 0) revert NoResponses();
        uint256 sum;
        for (uint i = 0; i < _responses.length; ) {
            sum += abi.decode(_responses[i], (uint256));
        }
        return abi.encode(sum);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function rescueToken(
        address token,
        address payable to,
        uint256 amount
    ) external onlyOwner {
        if (token != address(0)) {
            to.transfer(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Batch set trust status for multiple OFT tokens
     * @param ofts Array of OFT token addresses
     * @param trusted Array of trust statuses (must match ofts length)
     */
    function setTrustedOFTs(
        address[] calldata ofts,
        bool[] calldata trusted
    ) external onlyOwner {
        if (ofts.length != trusted.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < ofts.length; ) {
            _setTrustedOFT(ofts[i], trusted[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Check if an OFT token is trusted for bridging
     * @param oft Address of the OFT token to check
     * @return bool True if the token is trusted, false otherwise
     */
    function isTrustedOFT(address oft) external view returns (bool) {
        return _trustedOFTs[oft];
    }

    /**
     * @notice Get all trusted OFT tokens
     * @return address[] Array of trusted OFT addresses
     */
    function getTrustedOFTs() external view returns (address[] memory) {
        return _trustedOFTsList;
    }

    function _getCmd(
        IVaultsFactory.VaultInfo[] memory vaultInfos
    ) internal view returns (bytes memory cmd) {
        // 1. Define WHAT function to call on the target contract
        //    Using the interface selector ensures type safety and correctness
        //    You can replace this with any public/external function or state variable
        bytes memory callData = abi.encodeWithSelector(
            IVaultFacet.totalAssetsUsd.selector
        );
        EVMCallRequestV1[] memory readRequests = new EVMCallRequestV1[](
            vaultInfos.length
        );

        // 2. Build the read request specifying WHERE and HOW to fetch the data
        for (uint256 i = 0; i < vaultInfos.length; ) {
            uint32 eid = _chainIdToEid[vaultInfos[i].chainId];
            if (eid == 0) {
                revert UnsupportedChain(vaultInfos[i].chainId);
            }
            readRequests[i] = EVMCallRequestV1({
                appRequestLabel: uint16(i + 1), // Label for tracking this specific request
                targetEid: eid, // WHICH chain to read from
                isBlockNum: false, // Use timestamp (not block number)
                blockNumOrTimestamp: uint64(block.timestamp), // WHEN to read the state (current time)
                confirmations: 15, // HOW many confirmations to wait for
                to: vaultInfos[i].vault, // WHERE - the contract address to call
                callData: callData // WHAT - the function call to execute
            });
            unchecked {
                ++i;
            }
        }

        EVMCallComputeV1 memory compute = EVMCallComputeV1({
            computeSetting: 1,
            targetEid: ILayerZeroEndpointV2(endpoint).eid(),
            isBlockNum: false,
            blockNumOrTimestamp: uint64(block.timestamp),
            confirmations: 15,
            to: address(this)
        });

        // 3. Encode the complete read command
        //    No compute logic needed for simple data reading
        //    The appLabel (0) can be used to identify different types of read operations
        cmd = ReadCodecV1.encode(0, readRequests, compute);
    }

    /// @notice Handles the final averaged quote from LayerZero and emits the result.
    /// @dev _origin LayerZero origin metadata (unused).
    /// @dev _guid Unique message identifier (unused).
    /// @param _message Encoded sum of totalAssetsUsd bytes.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override {
        uint256 sum = abi.decode(_message, (uint256));

        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = IBridgeFacet(
            _nonceToCallInfo[_origin.nonce].vault
        ).getRequestInfo(_origin.nonce);
        MoreVaultsLib.ActionType actionType = requestInfo.actionType;
        if (
            actionType == MoreVaultsLib.ActionType.REQUEST_WITHDRAW ||
            actionType == MoreVaultsLib.ActionType.REQUEST_REDEEM
        ) {
            IBridgeFacet(_nonceToCallInfo[_origin.nonce].vault).finalizeRequest(
                _origin.nonce
            );
        } else {
            IBridgeFacet(_nonceToCallInfo[_origin.nonce].vault)
                .updateAccountingInfoForRequest(_origin.nonce, sum);
            if (_nonceToCallInfo[_origin.nonce].initiator == composer) {
                _callbackToComposer(_origin.nonce);
            }
        }
    }

    function _callbackToComposer(uint64 nonce) internal {
        ILzComposer(composer).completeDeposit(nonce); // calling finalizeRequest in composer, TODO:may be we should do request creation through composer
        // and finalizeRequest automatically after receiving data from all spoke vaults. But in this case assets could be stucked on composer if accounting failed.
    }

    /// @dev Consolidated validation logic
    function _validateBridgeParams(
        uint256 destChainId,
        address oftToken,
        uint32 layerZeroEid,
        uint256 amount
    ) internal view {
        // Input validation
        if (amount == 0) revert InvalidAmount();
        if (destChainId == 0) revert InvalidDestChain();
        if (oftToken == address(0) || oftToken.code.length == 0)
            revert InvalidOFTToken();
        if (layerZeroEid == 0) revert InvalidLayerZeroEid();

        // Chain conditions
        if (_chainIdToEid[uint16(destChainId)] == 0)
            revert UnsupportedChain(uint16(destChainId));
        if (chainPaused[destChainId]) revert ChainPaused();
    }

    /// @dev Internal bridge logic
    function _executeBridging(
        address oftTokenAddress,
        uint256 dstChainId,
        uint32 lzEid,
        uint256 amount,
        address dstVaultAddress
    ) internal {
        // Validate caller is authorized vault (calculate initiatorIsHub internally)
        if (!vaultsFactory.isVault(msg.sender)) revert UnauthorizedVault();

        // Validate OFT token is trusted
        if (!_trustedOFTs[oftTokenAddress])
            revert UntrustedOFT();

        _validateBridgeParams(dstChainId, oftTokenAddress, lzEid, amount);

        IERC20(oftTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        uint256 actualFee = _executeOFTSend(
            oftTokenAddress,
            lzEid,
            amount,
            dstVaultAddress
        );

        emit BridgeExecuted(
            msg.sender,
            dstChainId,
            dstVaultAddress,
            oftTokenAddress,
            amount,
            actualFee,
            lzEid
        );
    }

    /// @dev Internal quote logic
    function _quoteFee(
        address oftTokenAddress,
        uint256 dstChainId,
        uint32 lzEid,
        uint256 amount,
        address dstVaultAddress
    ) internal view returns (uint256 nativeFee) {
        _validateBridgeParams(dstChainId, oftTokenAddress, lzEid, amount);

        IOFT oft = IOFT(oftTokenAddress);

        uint256 minAmountOut = (amount * (10000 - slippageBps)) / 10000;

        SendParam memory sendParam = SendParam({
            dstEid: lzEid,
            to: bytes32(uint256(uint160(dstVaultAddress))),
            amountLD: amount,
            minAmountLD: minAmountOut,
            extraOptions: OptionsBuilder
                .newOptions()
                .addExecutorLzReceiveOption(200000, 0),
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        return fee.nativeFee;
    }

    function _executeOFTSend(
        address oftToken,
        uint32 layerZeroEid,
        uint256 amount,
        address recipient
    ) internal returns (uint256 actualFee) {
        IOFT oft = IOFT(oftToken);

        uint256 minAmountOut = (amount * (10000 - slippageBps)) / 10000;

        SendParam memory sendParam = SendParam({
            dstEid: layerZeroEid,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: amount,
            minAmountLD: minAmountOut,
            extraOptions: OptionsBuilder
                .newOptions()
                .addExecutorLzReceiveOption(200000, 0),
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        if (msg.value < fee.nativeFee) revert BridgeFailed();

        IERC20(oftToken).forceApprove(oftToken, amount);
        oft.send{value: fee.nativeFee}(sendParam, fee, payable(msg.sender));

        if (msg.value > fee.nativeFee) {
            payable(msg.sender).transfer(msg.value - fee.nativeFee);
        }

        return fee.nativeFee;
    }

    /**
     * @notice Internal function to set trusted OFT status
     * @param oft Address of the OFT
     * @param trusted True to trust the OFT, false to remove trust
     */
    function _setTrustedOFT(address oft, bool trusted) internal {
        if (oft == address(0)) revert ZeroAddress();

        bool currentlyTrusted = _trustedOFTs[oft];
        if (currentlyTrusted == trusted) {
            return; // No change needed
        }

        _trustedOFTs[oft] = trusted;

        if (trusted) {
            _trustedOFTsList.push(oft);
        } else {
            // Remove from list
            for (uint256 i = 0; i < _trustedOFTsList.length; ) {
                if (_trustedOFTsList[i] == oft) {
                    _trustedOFTsList[i] = _trustedOFTsList[
                        _trustedOFTsList.length - 1
                    ];
                    _trustedOFTsList.pop();
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }

        emit TrustedOFTUpdated(oft, trusted);
    }
}
