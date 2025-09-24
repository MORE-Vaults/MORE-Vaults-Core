// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {OAppRead} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppRead.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {AddressCast} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/AddressCast.sol";
import {ReadCodecV1, EVMCallRequestV1, EVMCallComputeV1} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/ReadCodecV1.sol";
import {MessagingFee, MessagingReceipt, ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {ICrossChainAccounting} from "../interfaces/ICrossChainAccounting.sol";
import {IBridgeFacet} from "../interfaces/facets/IBridgeFacet.sol";
import {ILzComposer} from "../interfaces/ILzComposer.sol";
import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";

contract CrossChainAccounting is
    OAppRead,
    OAppOptionsType3,
    ICrossChainAccounting
{
    error NoResponses();
    error UnsupportedChain(uint16);

    using Math for uint256;

    struct CallInfo {
        address vault;
        address initiator;
    }

    /// @notice Emitted when the data is received.
    /// @param data The value of the public state variable.
    event DataReceived(uint256 data);

    event ComposerUpdated(address indexed composer);

    event ChainIdToEidUpdated(uint16 indexed chainId, uint32 indexed eid);

    /// @notice LayerZero read channel ID.
    uint32 public READ_CHANNEL;

    /// @notice Message type for the read operation.
    uint16 public constant READ_TYPE = 1;

    mapping(uint16 => uint32) private _chainIdToEid;
    mapping(uint64 => CallInfo) private _nonceToCallInfo;

    address public composer;

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
        address _composer
    ) OAppRead(_endpoint, _delegate) Ownable(_delegate) {
        READ_CHANNEL = _readChannel;
        _setPeer(_readChannel, AddressCast.toBytes32(address(this)));
        composer = _composer;
    }

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

    function initiateCrossChainAccounting(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt) {
        // 1. Build the read command for the target contract and function
        bytes memory cmd = _getCmd(vaultInfos);

        // 2. Send the read request via LayerZero
        //    - READ_CHANNEL: Special channel ID for read operations
        //    - cmd: Encoded read command with target details
        //    - combineOptions: Merge enforced options with caller-provided options
        //    - MessagingFee(msg.value, 0): Pay all fees in native gas; no ZRO
        //    - payable(msg.sender): Refund excess gas to caller
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

    // ──────────────────────────────────────────────────────────────────────────────
    // 3. Receive Business Logic
    // ──────────────────────────────────────────────────────────────────────────────

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

    function setReadChannel(
        uint32 _channelId,
        bool _active
    ) public override onlyOwner {
        _setPeer(
            _channelId,
            _active ? AddressCast.toBytes32(address(this)) : bytes32(0)
        );
        READ_CHANNEL = _channelId;
    }

    function setChainIdToEid(uint16 chainId, uint32 eid) external onlyOwner {
        _chainIdToEid[chainId] = eid;
        emit ChainIdToEidUpdated(chainId, eid);
    }

    function setComposer(address _composer) external onlyOwner {
        composer = _composer;

        emit ComposerUpdated(composer);
    }

    function chainIdToEid(uint16 chainId) external view returns (uint32) {
        return _chainIdToEid[chainId];
    }

    function _callbackToComposer(uint64 nonce) internal {
        ILzComposer(composer).completeDeposit(nonce); // calling finalizeRequest in composer, TODO:may be we should do request creation through composer
        // and finalizeRequest automatically after receiving data from all spoke vaults. But in this case assets could be stucked on composer if accounting failed.
    }
}
