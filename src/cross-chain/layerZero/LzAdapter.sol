// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOFT, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {AddressCast} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import {
    ReadCodecV1,
    EVMCallRequestV1,
    EVMCallComputeV1
} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import {IBridgeAdapter} from "../../interfaces/IBridgeAdapter.sol";
import {IMoreVaultsRegistry} from "../../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../../interfaces/IVaultsFactory.sol";
import {
    MessagingFee,
    MessagingReceipt,
    ILayerZeroEndpointV2
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IVaultFacet} from "../../interfaces/facets/IVaultFacet.sol";
import {IBridgeFacet} from "../../interfaces/facets/IBridgeFacet.sol";
import {ILzComposer} from "../../interfaces/ILzComposer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MoreVaultsLib} from "../../libraries/MoreVaultsLib.sol";
import {IConfigurationFacet} from "../../interfaces/facets/IConfigurationFacet.sol";

contract LzAdapter is IBridgeAdapter, OAppRead, OAppOptionsType3, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;
    using Math for uint256;

    struct CallInfo {
        address vault;
        address initiator;
    }

    /// @notice Emitted when the data is received.
    /// @param data The value of the public state variable.
    event DataReceived(uint256 data);

    event GasLimitUpdated(uint256 gasLimit);

    event TrustedOFTUpdated(address indexed oft, bool trusted);

    event BridgeExecuted(
        address indexed vault,
        address indexed destVault,
        address oftToken,
        uint256 amount,
        uint256 fee,
        uint32 layerZeroEid,
        address refundAddress
    );

    IVaultsFactory public immutable vaultsFactory;
    IMoreVaultsRegistry public immutable vaultsRegistry;

    /// @notice LayerZero read channel ID.
    uint32 public READ_CHANNEL;

    /// @notice Message type for the read operation.
    uint16 public constant READ_TYPE = 1;

    mapping(bytes32 => CallInfo) internal _guidToCallInfo; // primary correlation

    // Security configurations
    uint256 public slippageBps = 100; // 1% default slippage

    // EID-level pause control (EID-only mode)
    mapping(uint32 => bool) public eidPaused;

    // OFT management
    mapping(address => bool) private _trustedOFTs;
    address[] private _trustedOFTsList;

    uint256 public gasLimit = 200000;

    /**
     * @notice Initialize the LayerZero adapter for cross-chain bridge operations
     * @param _endpoint The LayerZero endpoint contract address
     * @param _delegate The address that will have ownership privileges
     * @param _readChannel The LayerZero read channel ID for cross-chain accounting
     * @param _vaultsFactory Factory contract for vault validation
     * @param _vaultsRegistry Registry contract for protocol configuration
     * @dev This adapter uses an EID-only approach for chain management:
     *      - Chain support is determined solely by non-zero EID mappings
     *      - No separate supportedChains mapping for gas efficiency
     *      - Use setChainIdToEid() to enable/disable chains
     */
    constructor(
        address _endpoint,
        address _delegate,
        uint32 _readChannel,
        address _vaultsFactory,
        address _vaultsRegistry
    ) OAppRead(_endpoint, _delegate) Ownable(_delegate) {
        READ_CHANNEL = _readChannel;
        _setPeer(_readChannel, AddressCast.toBytes32(address(this)));
        vaultsFactory = IVaultsFactory(_vaultsFactory);
        vaultsRegistry = IMoreVaultsRegistry(_vaultsRegistry);
    }

    /**
     * @notice Return if the adapter is paused
     */
    function paused() public view override(IBridgeAdapter, Pausable) returns (bool) {
        return super.paused();
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function quoteBridgeFee(bytes calldata bridgeSpecificParams) external view returns (uint256 nativeFee) {
        (address oftTokenAddress, uint32 lzEid, uint256 amount, address dstVaultAddress) =
            abi.decode(bridgeSpecificParams, (address, uint32, uint256, address));
        return _quoteFee(oftTokenAddress, lzEid, amount, dstVaultAddress);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function quoteReadFee(address[] memory vaults, uint32[] memory eids, bytes calldata _extraOptions)
        external
        view
        returns (MessagingFee memory fee)
    {
        return
            _quote(READ_CHANNEL, _getCmd(vaults, eids), combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions), false);
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
    function pauseEid(uint32 eid) external onlyOwner {
        eidPaused[eid] = true;
        emit EidPaused(eid);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function unpauseEid(uint32 eid) external onlyOwner {
        eidPaused[eid] = false;
        emit EidUnpaused(eid);
    }

    function isEidPaused(uint32 eid) external view returns (bool) {
        return eidPaused[eid];
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setSlippage(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps > 10000) revert SlippageTooHigh();
        slippageBps = newSlippageBps;
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function setReadChannel(uint32 _channelId, bool _active) public override(IBridgeAdapter, OAppRead) onlyOwner {
        _setPeer(_channelId, _active ? AddressCast.toBytes32(address(this)) : bytes32(0));
        READ_CHANNEL = _channelId;
    }

    function setGasLimit(uint256 _gasLimit) external onlyOwner {
        gasLimit = _gasLimit;

        emit GasLimitUpdated(gasLimit);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function executeBridging(bytes calldata bridgeSpecificParams) external payable whenNotPaused nonReentrant {
        (address oftTokenAddress, uint32 lzEid, uint256 amount, address dstVaultAddress, address refundAddress) =
            abi.decode(bridgeSpecificParams, (address, uint32, uint256, address, address));
        _executeBridging(oftTokenAddress, lzEid, amount, dstVaultAddress, refundAddress);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function initiateCrossChainAccounting(
        address[] memory vaults,
        uint32[] memory eids,
        bytes calldata _extraOptions,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt) {
        if (!IVaultsFactory(vaultsFactory).isFactoryVault(msg.sender)) {
            revert UnauthorizedVault();
        }
        bytes memory cmd = _getCmd(vaults, eids);

        receipt = _lzSend(
            READ_CHANNEL,
            cmd,
            combineOptions(READ_CHANNEL, READ_TYPE, _extraOptions),
            MessagingFee(msg.value, 0),
            payable(_initiator)
        );

        _guidToCallInfo[receipt.guid] = CallInfo({vault: msg.sender, initiator: _initiator});
    }

    /// @notice Reduces multiple mapped responses to a single sum value.
    /// @param _responses Array of encoded totalAssetsUsd responses from each chain and success flag.
    /// @return Encoded sum of all responses and success flag.
    function lzReduce(bytes calldata, bytes[] calldata _responses) external pure returns (bytes memory) {
        if (_responses.length == 0) revert NoResponses();
        uint256 sum;
        bool readSuccess = true;
        for (uint256 i = 0; i < _responses.length;) {
            (uint256 assets, bool success) = abi.decode(_responses[i], (uint256, bool));
            if (!success) readSuccess = false;
            sum += assets;

            unchecked {
                ++i;
            }
        }
        return abi.encode(sum, readSuccess);
    }

    /**
     * @inheritdoc IBridgeAdapter
     */
    function rescueToken(address token, address payable to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Batch set trust status for multiple OFT tokens
     * @param ofts Array of OFT token addresses
     * @param trusted Array of trust statuses (must match ofts length)
     * @dev Protected against reentrancy attacks during batch operations
     */
    function setTrustedOFTs(address[] calldata ofts, bool[] calldata trusted) external onlyOwner nonReentrant {
        if (ofts.length != trusted.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < ofts.length;) {
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

    function _getCmd(address[] memory vaults, uint32[] memory eids) internal view returns (bytes memory cmd) {
        // 1. Define WHAT function to call on the target contract
        //    Using the interface selector ensures type safety and correctness
        //    You can replace this with any public/external function or state variable
        bytes memory callData = abi.encodeWithSelector(IVaultFacet.totalAssetsUsd.selector);
        EVMCallRequestV1[] memory readRequests = new EVMCallRequestV1[](vaults.length);

        // 2. Build the read request specifying WHERE and HOW to fetch the data
        for (uint256 i = 0; i < vaults.length;) {
            readRequests[i] = EVMCallRequestV1({
                appRequestLabel: uint16(i + 1), // Label for tracking this specific request
                targetEid: eids[i], // WHICH chain to read from
                isBlockNum: false, // Use timestamp (not block number)
                blockNumOrTimestamp: uint64(block.timestamp), // WHEN to read the state (current time)
                confirmations: 15, // HOW many confirmations to wait for
                to: vaults[i], // WHERE - the contract address to call
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
        Origin calldata, /*_origin*/
        bytes32 _guid,
        bytes calldata _message,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override {
        (uint256 sum, bool readSuccess) = abi.decode(_message, (uint256, bool));

        CallInfo memory info = _guidToCallInfo[_guid];
        if (info.vault == address(0)) revert InvalidVault();

        IBridgeFacet(info.vault).updateAccountingInfoForRequest(_guid, sum, readSuccess);
        if (info.initiator == vaultsFactory.vaultComposer(info.vault)) {
            _callbackToComposer(info.initiator, _guid, readSuccess);
        }

        delete _guidToCallInfo[_guid];
    }

    function _callbackToComposer(address composer, bytes32 guid, bool readSuccess) internal {
        if (!readSuccess) {
            ILzComposer(composer).refundDeposit(guid);
        } else {
            ILzComposer(composer).completeDeposit(guid);
        }
    }

    /// @dev Gas-optimized consolidated validation logic
    function _validateBridgeParams(address oftToken, uint32 layerZeroEid, uint256 amount) internal view {
        // Single comprehensive check for basic parameters
        if (amount == 0 || oftToken == address(0) || layerZeroEid == 0) {
            revert InvalidBridgeParams();
        }

        // EID pause validation
        if (eidPaused[layerZeroEid]) revert ChainPaused();

        // Code existence check (separate for gas optimization)
        if (oftToken.code.length == 0) {
            revert InvalidOFTToken();
        }
    }

    /// @dev Internal bridge logic
    function _executeBridging(
        address oftTokenAddress,
        uint32 lzEid,
        uint256 amount,
        address dstVaultAddress,
        address refundAddress
    ) internal {
        // Validate caller is authorized vault (calculate initiatorIsHub internally)
        if (!vaultsFactory.isFactoryVault(msg.sender)) revert UnauthorizedVault();

        // Validate OFT token is trusted
        if (!_trustedOFTs[oftTokenAddress]) revert UntrustedOFT();

        if (!IConfigurationFacet(msg.sender).isHub()) {
            (uint32 hubEid, address hubVault) = vaultsFactory.spokeToHub(vaultsFactory.localEid(), msg.sender);
            if (lzEid != hubEid || dstVaultAddress != hubVault) {
                revert InvalidReceiver(lzEid, dstVaultAddress);
            }
        } else {
            // O(1) membership check via factory
            if (!vaultsFactory.isSpokeOfHub(vaultsFactory.localEid(), msg.sender, lzEid, dstVaultAddress)) {
                revert InvalidReceiver(lzEid, dstVaultAddress);
            }
        }

        if (refundAddress == address(0)) {
            revert ZeroAddress();
        }
        _validateBridgeParams(oftTokenAddress, lzEid, amount);

        address underlyingToken = IOFT(oftTokenAddress).token();
        if (underlyingToken == oftTokenAddress) {
            IERC20(oftTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            // OFT-Proxy: transfer underlying tokens to the adapter
            IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 actualFee = _executeOFTSend(oftTokenAddress, lzEid, amount, dstVaultAddress, refundAddress);

        emit BridgeExecuted(msg.sender, dstVaultAddress, oftTokenAddress, amount, actualFee, lzEid, refundAddress);
    }

    /// @dev Internal quote logic
    function _quoteFee(address oftTokenAddress, uint32 lzEid, uint256 amount, address dstVaultAddress)
        internal
        view
        returns (uint256 nativeFee)
    {
        _validateBridgeParams(oftTokenAddress, lzEid, amount);

        IOFT oft = IOFT(oftTokenAddress);

        uint256 minAmountOut = (amount * (10000 - slippageBps)) / 10000;

        SendParam memory sendParam = SendParam({
            dstEid: lzEid,
            to: bytes32(uint256(uint160(dstVaultAddress))),
            amountLD: amount,
            minAmountLD: minAmountOut,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(gasLimit), 0),
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
        address recipient,
        address refundAddress
    ) internal returns (uint256 actualFee) {
        IOFT oft = IOFT(oftToken);

        uint256 minAmountOut = (amount * (10000 - slippageBps)) / 10000;

        SendParam memory sendParam = SendParam({
            dstEid: layerZeroEid,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: amount,
            minAmountLD: minAmountOut,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(gasLimit), 0),
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        if (msg.value < fee.nativeFee) revert NotEnoughFee();

        address underlyingToken = IOFT(oftToken).token();
        if (underlyingToken != oftToken) {
            IERC20(underlyingToken).forceApprove(oftToken, amount);
        } else {
            IERC20(oftToken).forceApprove(oftToken, amount);
        }
        oft.send{value: fee.nativeFee}(sendParam, fee, refundAddress);

        if (msg.value > fee.nativeFee) {
            uint256 refund = msg.value - fee.nativeFee;
            (bool success,) = payable(refundAddress).call{value: refund}("");
            if (!success) revert NativeTransferFailed();
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
            for (uint256 i = 0; i < _trustedOFTsList.length;) {
                if (_trustedOFTsList[i] == oft) {
                    _trustedOFTsList[i] = _trustedOFTsList[_trustedOFTsList.length - 1];
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
