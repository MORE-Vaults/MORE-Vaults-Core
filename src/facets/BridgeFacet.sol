// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {ICrossChainAccounting} from "../interfaces/ICrossChainAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IBridgeFacet} from "../interfaces/facets/IBridgeFacet.sol";

contract BridgeFacet is
    PausableUpgradeable,
    BaseFacetInitializer,
    IBridgeFacet
{
    using Math for uint256;

    error CrossChainRequestWasntFulfilled(uint64);
    error InvalidActionType();
    error OnlyCrossChainAccountingManager();
    error SyncActionsDisabledInCrossChainVaults();
    error RequestWasntFulfilled();
    error FinalizationCallFailed();
    error OracleWasntSetForSpoke(IVaultsFactory.VaultInfo);
    error NoOracleForSpoke(uint16);
    error AlreadySet();
    error AccountingViaOracles();

    event OracleCrossChainAccountingUpdated(bool indexed isTrue);

    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.BridgeFacet");
    }

    function facetName() external pure returns (string memory) {
        return "BridgeFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(
        bytes calldata data
    ) external initializerFacet initializer {
        // ds.supportedInterfaces[type(IBridgeFacet).interfaceId] = true; // IBridgeFacet interface
    }

    function accountingBridgeFacet()
        public
        view
        returns (uint256 sum, bool isPositive)
    {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        IVaultsFactory.VaultInfo[] memory spokeInfos = IVaultsFactory(
            ds.factory
        ).hubToSpokes(uint16(block.chainid), address(this));
        for (uint256 i = 0; i < spokeInfos.length; ) {
            IMoreVaultsRegistry registry = IMoreVaultsRegistry(
                AccessControlLib.vaultRegistry()
            );
            IOracleRegistry oracle = registry.oracle();
            sum += oracle.getSpokeValue(address(this), spokeInfos[i].chainId);
            unchecked {
                ++i;
            }
        }
        return (sum, true);
    }

    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        // ds.supportedInterfaces[type(IBridgeFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds,
            bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()"))),
            isReplacing
        );
    }

    function setOraclesCrossChainAccounting(bool isTrue) external {
        AccessControlLib.validateOwner(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        IVaultsFactory.VaultInfo[] memory spokeInfos = IVaultsFactory(
            ds.factory
        ).hubToSpokes(uint16(block.chainid), address(this));

        bool currentValue = ds.oraclesCrossChainAccounting;
        if (isTrue == currentValue) {
            revert AlreadySet();
        }
        if (isTrue && !currentValue) {
            for (uint256 i = 0; i < spokeInfos.length; ) {
                IMoreVaultsRegistry registry = IMoreVaultsRegistry(
                    AccessControlLib.vaultRegistry()
                );
                IOracleRegistry oracle = registry.oracle();

                if (
                    address(
                        oracle
                            .getSpokeOracleInfo(
                                address(this),
                                spokeInfos[i].chainId
                            )
                            .aggregator
                    ) == address(0)
                ) {
                    revert NoOracleForSpoke(spokeInfos[i].chainId);
                }
                unchecked {
                    ++i;
                }
            }
        }
        if (isTrue) {
            bytes32 facetSelector = bytes4(
                keccak256(abi.encodePacked("accountingBridgeFacet()"))
            );
            ds.facetsForAccounting.push(facetSelector);
        } else {
            MoreVaultsLib.removeFromFacetsForAccounting(
                ds,
                bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()"))),
                false
            );
        }
        ds.oraclesCrossChainAccounting = isTrue;

        emit OracleCrossChainAccountingUpdated(isTrue);
    }

    function initVaultActionRequest(
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        bytes calldata extraOptions
    ) external payable whenNotPaused returns (uint64 nonce) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        IVaultsFactory.VaultInfo[] memory spokesInfo = IVaultsFactory(
            ds.factory
        ).hubToSpokes(uint16(block.chainid), address(this));
        if (spokesInfo.length != 0) {
            if (ds.oraclesCrossChainAccounting) {
                revert AccountingViaOracles();
            }
            nonce = _createCrossChainRequest(
                ds,
                spokesInfo,
                actionType,
                actionCallData,
                extraOptions
            );
        }
    }

    function _createCrossChainRequest(
        MoreVaultsLib.MoreVaultsStorage storage ds,
        IVaultsFactory.VaultInfo[] memory spokesInfo,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        bytes calldata extraOptions
    ) internal returns (uint64 nonce) {
        nonce = ICrossChainAccounting(ds.crossChainAccountingManager)
        .initiateCrossChainAccounting{value: msg.value}(
            spokesInfo,
            extraOptions,
            msg.sender
        ).nonce;

        MoreVaultsLib._beforeAccounting(ds.beforeAccountingFacets);
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = MoreVaultsLib
            .CrossChainRequestInfo({
                initiator: msg.sender,
                actionType: actionType,
                actionCallData: actionCallData,
                fulfilled: false,
                totalAssets: IVaultFacet(address(this)).totalAssets()
            });
        ds.nonceToCrossChainRequestInfo[nonce] = requestInfo;
    }

    function updateAccountingInfoForRequest(
        uint64 nonce,
        uint256 sumOfSpokesUsdValue
    ) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (msg.sender != ds.crossChainAccountingManager)
            revert OnlyCrossChainAccountingManager();
        ds.nonceToCrossChainRequestInfo[nonce].totalAssets += MoreVaultsLib
            .convertUsdToUnderlying(sumOfSpokesUsdValue, Math.Rounding.Floor);
        ds.nonceToCrossChainRequestInfo[nonce].fulfilled = true;
    }

    function finalizeRequest(uint64 nonce) external payable {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.nonceToCrossChainRequestInfo[nonce].fulfilled) {
            revert RequestWasntFulfilled();
        }
        ds.finalizationNonce = nonce;

        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = ds
            .nonceToCrossChainRequestInfo[nonce];

        bool success;
        if (requestInfo.actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets, address receiver) = abi.decode(
                requestInfo.actionCallData,
                (uint256, address)
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    bytes4(keccak256("deposit(uint256,address)")),
                    assets,
                    receiver
                )
            );

            // TODO: think about this in terms native depostis, most likely they don't work since You need OFT to bridge assets and OFT will be for wrapped native, not native itself
            // } else if (
            //     requestInfo.actionType ==
            //     MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT
            // ) {
            //     (
            //         address[] memory tokens,
            //         uint256[] memory assets,
            //         address receiver,
            //         uint256 value
            //     ) = abi.decode(
            //             requestInfo.actionCallData,
            //             (address[], uint256[], address, uint256)
            //         );
            //     (success, ) = address(this).call{value: value}(
            //         abi.encodeWithSelector(
            //             bytes4(keccak256("deposit(address[],uint256[],address)")),
            //             tokens,
            //             assets,
            //             receiver
            //         )
            //     );
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MINT) {
            (uint256 shares, address receiver) = abi.decode(
                requestInfo.actionCallData,
                (uint256, address)
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(IERC4626.mint.selector, shares, receiver)
            );
        } else if (
            requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW
        ) {
            (uint256 assets, address receiver, address owner) = abi.decode(
                requestInfo.actionCallData,
                (uint256, address, address)
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    IERC4626.withdraw.selector,
                    assets,
                    receiver,
                    owner
                )
            );
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, address receiver, address owner) = abi.decode(
                requestInfo.actionCallData,
                (uint256, address, address)
            );
            (success, ) = address(this).call(
                abi.encodeWithSelector(
                    IERC4626.redeem.selector,
                    shares,
                    receiver,
                    owner
                )
            );
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.SET_FEE) {
            uint96 fee = abi.decode(requestInfo.actionCallData, (uint96));
            (success, ) = address(this).call(
                abi.encodeWithSelector(bytes4(keccak256("setFee(uint96)")), fee)
            );
        }
        if (!success) revert FinalizationCallFailed();

        ds.finalizationNonce = type(uint64).max;
    }

    function getRequestInfo(
        uint64 nonce
    ) external view returns (MoreVaultsLib.CrossChainRequestInfo memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return ds.nonceToCrossChainRequestInfo[nonce];
    }
}
