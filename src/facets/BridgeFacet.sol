// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IBridgeFacet} from "../interfaces/facets/IBridgeFacet.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract BridgeFacet is PausableUpgradeable, BaseFacetInitializer, IBridgeFacet, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    event AccountingInfoUpdated(bytes32 indexed guid, uint256 sumOfSpokesUsdValue, bool readSuccess);
    event OracleCrossChainAccountingUpdated(bool indexed isTrue);

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.BridgeFacet");
    }

    function facetName() external pure returns (string memory) {
        return "BridgeFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata) external initializerFacet initializer {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IBridgeFacet).interfaceId] = true; // IBridgeFacet interface
    }

    function accountingBridgeFacet() public view returns (uint256 sum, bool isPositive) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        uint32 localEid = factory.localEid();
        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(localEid, address(this));
        for (uint256 i = 0; i < vaults.length;) {
            IMoreVaultsRegistry registry = IMoreVaultsRegistry(AccessControlLib.vaultRegistry());
            IOracleRegistry oracle = registry.oracle();
            sum += oracle.getSpokeValue(address(this), eids[i]);
            unchecked {
                ++i;
            }
        }
        return (sum, true);
    }

    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IBridgeFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds, bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()"))), isReplacing
        );
    }

    function setOraclesCrossChainAccounting(bool isTrue) external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(factory.localEid(), address(this));

        bool currentValue = ds.oraclesCrossChainAccounting;
        if (isTrue == currentValue) {
            revert AlreadySet();
        }
        if (isTrue && !currentValue) {
            for (uint256 i = 0; i < vaults.length;) {
                IMoreVaultsRegistry registry = IMoreVaultsRegistry(AccessControlLib.vaultRegistry());
                IOracleRegistry oracle = registry.oracle();

                if (address(oracle.getSpokeOracleInfo(address(this), eids[i]).aggregator) == address(0)) {
                    revert NoOracleForSpoke(eids[i]);
                }
                unchecked {
                    ++i;
                }
            }
        }
        if (isTrue) {
            bytes32 facetSelector = bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()")));
            ds.facetsForAccounting.push(facetSelector);
        } else {
            MoreVaultsLib.removeFromFacetsForAccounting(
                ds, bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()"))), false
            );
        }
        ds.oraclesCrossChainAccounting = isTrue;

        emit OracleCrossChainAccountingUpdated(isTrue);
    }

    function executeBridging(address adapter, address token, uint256 amount, bytes calldata bridgeSpecificParams)
        external
        payable
        whenNotPaused
    {
        AccessControlLib.validateCurator(msg.sender);
        _pause();
        AccessControlLib.AccessControlStorage storage acs = AccessControlLib.accessControlStorage();
        if (!IMoreVaultsRegistry(acs.moreVaultsRegistry).isBridgeAllowed(adapter)) {
            revert AdapterNotAllowed(adapter);
        }
        IERC20(token).forceApprove(adapter, amount);
        IBridgeAdapter(adapter).executeBridging{value: msg.value}(bridgeSpecificParams);
    }

    function quoteAccountingFee(bytes calldata extraOptions) external view returns (uint256 nativeFee) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(factory.localEid(), address(this));
        IBridgeAdapter adapter = IBridgeAdapter(MoreVaultsLib._getCrossChainAccountingManager());
        MessagingFee memory fee = adapter.quoteReadFee(vaults, eids, extraOptions);
        return fee.nativeFee;
    }

    function initVaultActionRequest(
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        bytes calldata extraOptions
    ) external payable whenNotPaused nonReentrant returns (bytes32 guid) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(factory.localEid(), address(this));
        if (vaults.length != 0) {
            if (ds.oraclesCrossChainAccounting) {
                revert AccountingViaOracles();
            }
            guid = _createCrossChainRequest(ds, vaults, eids, actionType, actionCallData, extraOptions);
        }
    }

    function _createCrossChainRequest(
        MoreVaultsLib.MoreVaultsStorage storage ds,
        address[] memory vaults,
        uint32[] memory eids,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        bytes calldata extraOptions
    ) internal returns (bytes32 guid) {
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = MoreVaultsLib.CrossChainRequestInfo({
            initiator: msg.sender,
            timestamp: uint64(block.timestamp),
            actionType: actionType,
            actionCallData: actionCallData,
            fulfilled: false,
            finalized: false,
            totalAssets: IVaultFacet(address(this)).totalAssets()
        });
        MessagingFee memory fee =
            IBridgeAdapter(MoreVaultsLib._getCrossChainAccountingManager()).quoteReadFee(vaults, eids, extraOptions);
        if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (,,, uint256 value) = abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256));
            if (value + fee.nativeFee > msg.value) revert NotEnoughMsgValueProvided();
        }

        guid = IBridgeAdapter(MoreVaultsLib._getCrossChainAccountingManager()).initiateCrossChainAccounting{value: msg.value}(
            vaults, eids, extraOptions, msg.sender
        ).guid;
        ds.guidToCrossChainRequestInfo[guid] = requestInfo;
    }

    function updateAccountingInfoForRequest(bytes32 guid, uint256 sumOfSpokesUsdValue, bool readSuccess) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (msg.sender != MoreVaultsLib._getCrossChainAccountingManager()) {
            revert OnlyCrossChainAccountingManager();
        }
        if (readSuccess) {
            ds.guidToCrossChainRequestInfo[guid].totalAssets +=
                MoreVaultsLib.convertUsdToUnderlying(sumOfSpokesUsdValue, Math.Rounding.Floor);
        }
        ds.guidToCrossChainRequestInfo[guid].fulfilled = readSuccess;

        emit AccountingInfoUpdated(guid, sumOfSpokesUsdValue, readSuccess);
    }

    function finalizeRequest(bytes32 guid) external payable nonReentrant returns (bytes memory result) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = ds.guidToCrossChainRequestInfo[guid];
        if (!ds.guidToCrossChainRequestInfo[guid].fulfilled) {
            revert RequestWasntFulfilled();
        }
        if (requestInfo.timestamp + 1 hours < block.timestamp) {
            revert RequestTimedOut();
        }
        if (requestInfo.finalized) {
            revert RequestAlreadyFinalized();
        }
        ds.finalizationGuid = guid;

        bool success;
        if (requestInfo.actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets, address receiver) = abi.decode(requestInfo.actionCallData, (uint256, address));
            (success, result) = address(this).call(abi.encodeWithSelector(IERC4626.deposit.selector, assets, receiver));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory assets, address receiver, uint256 value) =
                abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256));
            (success, result) = address(this).call{value: value}(
                abi.encodeWithSelector(
                    bytes4(keccak256("deposit(address[],uint256[],address)")), tokens, assets, receiver
                )
            );
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MINT) {
            (uint256 shares, address receiver) = abi.decode(requestInfo.actionCallData, (uint256, address));
            (success, result) = address(this).call(abi.encodeWithSelector(IERC4626.mint.selector, shares, receiver));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (uint256 assets, address receiver, address owner) =
                abi.decode(requestInfo.actionCallData, (uint256, address, address));
            (success, result) =
                address(this).call(abi.encodeWithSelector(IERC4626.withdraw.selector, assets, receiver, owner));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, address receiver, address owner) =
                abi.decode(requestInfo.actionCallData, (uint256, address, address));
            (success, result) =
                address(this).call(abi.encodeWithSelector(IERC4626.redeem.selector, shares, receiver, owner));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.SET_FEE) {
            uint96 fee = abi.decode(requestInfo.actionCallData, (uint96));
            (success,) = address(this).call(abi.encodeWithSelector(IVaultFacet.setFee.selector, fee));
        }
        if (!success) revert FinalizationCallFailed();

        ds.guidToCrossChainRequestInfo[guid].finalized = true;
        ds.finalizationGuid = 0;
    }

    function getRequestInfo(bytes32 guid) external view returns (MoreVaultsLib.CrossChainRequestInfo memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.guidToCrossChainRequestInfo[guid];
    }
}
