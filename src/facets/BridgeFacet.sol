// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";
import {VaultFacet} from "./VaultFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IMoreVaultsRegistry} from "../interfaces/IMoreVaultsRegistry.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IMoreVaultsComposer} from "../interfaces/LayerZero/IMoreVaultsComposer.sol";
import {IOracleRegistry} from "../interfaces/IOracleRegistry.sol";
import {IBridgeFacet} from "../interfaces/facets/IBridgeFacet.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract BridgeFacet is PausableUpgradeable, BaseFacetInitializer, IBridgeFacet, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error TransferSharesFailed();

    event AccountingInfoUpdated(bytes32 indexed guid, uint256 sumOfSpokesUsdValue, bool readSuccess);
    event OracleCrossChainAccountingUpdated(bool indexed isTrue);

    uint256 public constant MAX_DELAY = 1 hours;

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.BridgeFacetV1.0.1");
    }

    function facetName() external pure returns (string memory) {
        return "BridgeFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.1";
    }

    function initialize(bytes calldata) external initializerFacet {
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
        sum = MoreVaultsLib.convertUsdToUnderlying(sum, Math.Rounding.Floor);
        return (sum, true);
    }

    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IBridgeFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds, bytes4(keccak256(abi.encodePacked("accountingBridgeFacet()"))), isReplacing
        );
    }

    function oraclesCrossChainAccounting() external view returns (bool) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.oraclesCrossChainAccounting;
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
        uint256 amountLimit,
        bytes calldata extraOptions
    ) external payable whenNotPaused nonReentrant returns (bytes32 guid) {
        MoreVaultsLib.validateNotMulticall();
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        IVaultsFactory factory = IVaultsFactory(ds.factory);
        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(factory.localEid(), address(this));
        if (vaults.length != 0) {
            if (ds.oraclesCrossChainAccounting) {
                revert AccountingViaOracles();
            }
            guid = _createCrossChainRequest(ds, vaults, eids, actionType, actionCallData, amountLimit, extraOptions);
        }
    }

    function _createCrossChainRequest(
        MoreVaultsLib.MoreVaultsStorage storage ds,
        address[] memory vaults,
        uint32[] memory eids,
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData,
        uint256 amountLimit,
        bytes calldata extraOptions
    ) internal returns (bytes32 guid) {
        MessagingFee memory fee = IBridgeAdapter(MoreVaultsLib._getCrossChainAccountingManager())
            .quoteReadFee(vaults, eids, extraOptions);
        uint256 value;
        if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (,,,, value) = abi.decode(actionCallData, (address[], uint256[], address, uint256, uint256));
            ds.pendingNative += value;
            if (value + fee.nativeFee > msg.value) {
                revert NotEnoughMsgValueProvided();
            }
        }

        guid =
        IBridgeAdapter(MoreVaultsLib._getCrossChainAccountingManager())
        .initiateCrossChainAccounting{value: msg.value - value}(
            vaults, eids, extraOptions, msg.sender
        )
        .guid;

        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = MoreVaultsLib.CrossChainRequestInfo({
            initiator: msg.sender,
            timestamp: uint64(block.timestamp),
            actionType: actionType,
            actionCallData: actionCallData,
            fulfilled: false,
            finalized: false,
            refunded: false,
            totalAssets: IVaultFacet(address(this)).totalAssets(),
            finalizationResult: 0,
            amountLimit: amountLimit
        });

        ds.guidToCrossChainRequestInfo[guid] = requestInfo;

        // Lock funds for the request
        _lockFundsForRequest(actionType, actionCallData);
    }

    /**
     * @dev Locks funds for a cross-chain request
     * @param actionType Type of action (DEPOSIT, WITHDRAW, REDEEM, etc.)
     * @param actionCallData Encoded action data
     */
    function _lockFundsForRequest(
        MoreVaultsLib.ActionType actionType,
        bytes calldata actionCallData
    ) internal {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        address initiator = msg.sender;

        if (actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets, address receiver) = abi.decode(actionCallData, (uint256, address));
            address assetToken = MoreVaultsLib.getUnderlyingTokenAddress();

            // Always transfer tokens from initiator to vault
            // Cannot use tokens already in vault - they belong to other users
            IERC20(assetToken).safeTransferFrom(initiator, address(this), assets);

            // Lock tokens
            ds.crossChainLockedTokens[assetToken] += assets;

        } else if (actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory assets,,,) =
                abi.decode(actionCallData, (address[], uint256[], address, uint256, uint256));

            // Always transfer tokens from initiator for each token
            for (uint256 i = 0; i < tokens.length; i++) {
                IERC20(tokens[i]).safeTransferFrom(initiator, address(this), assets[i]);
                ds.crossChainLockedTokens[tokens[i]] += assets[i];
            }

        } else if (actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (uint256 assets, address receiver, address owner) =
                abi.decode(actionCallData, (uint256, address, address));

            // Convert assets to shares
            uint256 shares = IVaultFacet(address(this)).previewWithdraw(assets);

            // Transfer shares from owner to vault using initiator's allowance from owner
            // Call public function VaultFacet via address(this).call() (both facets in same diamond contract)
            // Uses internal ERC20 functions for transfer within a single call
            (bool success, bytes memory returnData) = address(this).call(
                abi.encodeWithSelector(
                    VaultFacet.transferSharesFromOwner.selector,
                    owner,
                    shares,
                    initiator
                )
            );
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                revert TransferSharesFailed();
            }

            // Lock shares
            ds.crossChainLockedTokens[address(this)] += shares;

        } else if (actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, address receiver, address owner) =
                abi.decode(actionCallData, (uint256, address, address));

            // Transfer shares from owner to vault using initiator's allowance from owner
            (bool success, bytes memory returnData) = address(this).call(
                abi.encodeWithSelector(
                    VaultFacet.transferSharesFromOwner.selector,
                    owner,
                    shares,
                    initiator
                )
            );
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        revert(add(returnData, 0x20), mload(returnData))
                    }
                }
                revert TransferSharesFailed();
            }

            // Lock shares
            ds.crossChainLockedTokens[address(this)] += shares;
        }
        // For MINT and ACCRUE_FEES locking is not required
    }

    function updateAccountingInfoForRequest(bytes32 guid, uint256 sumOfSpokesUsdValue, bool readSuccess) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        if (msg.sender != MoreVaultsLib._getCrossChainAccountingManager()) {
            revert OnlyCrossChainAccountingManager();
        }
        if (readSuccess) {
            ds.guidToCrossChainRequestInfo[guid].totalAssets += MoreVaultsLib.convertUsdToUnderlying(
                sumOfSpokesUsdValue, Math.Rounding.Floor
            );
        }
        ds.guidToCrossChainRequestInfo[guid].fulfilled = readSuccess;

        emit AccountingInfoUpdated(guid, sumOfSpokesUsdValue, readSuccess);
    }

    /**
     * @dev Executes a cross-chain request action (deposit, mint, withdraw, etc.)
     * @param guid Request number to execute
     * @notice Can only be called by the cross-chain accounting manager
     * @notice Requires the request to be fulfilled
     * @notice Executes the action and performs slippage check
     */
    function executeRequest(bytes32 guid) external {
        if (msg.sender != MoreVaultsLib._getCrossChainAccountingManager()) {
            revert OnlyCrossChainAccountingManager();
        }
        _executeRequest(guid);
    }

    /**
     * @inheritdoc IBridgeFacet
     */
    function sendNativeTokenBackToInitiator(bytes32 guid) external {
        address crossChainAccountingManager = MoreVaultsLib._getCrossChainAccountingManager();
        if (msg.sender != crossChainAccountingManager) {
            revert OnlyCrossChainAccountingManager();
        }
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        MoreVaultsLib.CrossChainRequestInfo storage requestInfo = ds.guidToCrossChainRequestInfo[guid];
        if (requestInfo.actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (, , , , uint256 value) =
                abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256, uint256));
            if (value == 0) {
                return;
            }
            ds.pendingNative -= value;
            (bool success, ) = requestInfo.initiator.call{value: value}("");
            if (!success) {
                crossChainAccountingManager.call{value: value}("");
            } 
        }
    }

    /**
     * @dev Refunds the request if necessary
     * @param guid Request number to refund
     * @notice Can only be called by the cross-chain accounting manager
     * @notice Refunds the request if necessary
     */
    function refundStuckDepositInComposer(bytes32 guid) external payable {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        MoreVaultsLib.CrossChainRequestInfo storage requestInfo = ds.guidToCrossChainRequestInfo[guid];

        address vaultComposer = IVaultsFactory(ds.factory).vaultComposer(address(this));
        if (requestInfo.initiator != vaultComposer) {
            revert InitiatorIsNotVaultComposer();
        }
        if (requestInfo.timestamp + MAX_DELAY > block.timestamp || requestInfo.finalized || requestInfo.refunded) {
            revert RequestNotStuck();
        }

        // Unlock funds before refund
        _unlockRequestFunds(requestInfo);
        
        // Transfer tokens back to composer for refund
        _transferTokensBackToComposer(requestInfo, vaultComposer);
        
        IMoreVaultsComposer(vaultComposer).refundDeposit{value: msg.value}(guid);
        requestInfo.refunded = true;
    }

    /**
     * @dev Transfers tokens back to composer for refund
     * @param requestInfo Request info containing action type and call data
     * @param composer Composer address to transfer tokens to
     */
    function _transferTokensBackToComposer(
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo,
        address composer
    ) internal {
        if (requestInfo.actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets,) = abi.decode(requestInfo.actionCallData, (uint256, address));
            address assetToken = MoreVaultsLib.getUnderlyingTokenAddress();
            IERC20(assetToken).safeTransfer(composer, assets);
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory assets,,,) =
                abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256, uint256));
            for (uint256 i = 0; i < tokens.length; i++) {
                IERC20(tokens[i]).safeTransfer(composer, assets[i]);
            }
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (uint256 assets,,) = abi.decode(requestInfo.actionCallData, (uint256, address, address));
            uint256 shares = IVaultFacet(address(this)).previewWithdraw(assets);
            IERC20(address(this)).safeTransfer(composer, shares);
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares,,) = abi.decode(requestInfo.actionCallData, (uint256, address, address));
            IERC20(address(this)).safeTransfer(composer, shares);
        }
        // For MINT and ACCRUE_FEES no transfer needed
    }

    function _executeRequest(bytes32 guid) internal returns (bytes memory result) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        MoreVaultsLib.CrossChainRequestInfo memory requestInfo = ds.guidToCrossChainRequestInfo[guid];
        if (!ds.guidToCrossChainRequestInfo[guid].fulfilled) {
            revert RequestWasntFulfilled();
        }
        if (requestInfo.timestamp + MAX_DELAY < block.timestamp) {
            // Unlock funds before revert on timeout
            _unlockRequestFunds(requestInfo);
            revert RequestTimedOut();
        }
        if (requestInfo.finalized) {
            revert RequestAlreadyFinalized();
        }
        ds.finalizationGuid = guid;

        bool success;
        uint256 amountIn = 0;
        if (requestInfo.actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets, address receiver) = abi.decode(requestInfo.actionCallData, (uint256, address));
            (success, result) = address(this).call(abi.encodeWithSelector(IERC4626.deposit.selector, assets, receiver));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory assets, address receiver, uint256 minAmountOut, uint256 value) =
                abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256, uint256));
            (success, result) = address(this).call{value: value}(
                abi.encodeWithSelector(
                    bytes4(keccak256("deposit(address[],uint256[],address,uint256)")), tokens, assets, receiver, minAmountOut
                )
            );
            ds.pendingNative -= value;
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MINT) {
            (uint256 shares, address receiver) = abi.decode(requestInfo.actionCallData, (uint256, address));
            uint256 balanceBefore = IERC20(MoreVaultsLib.getUnderlyingTokenAddress()).balanceOf(requestInfo.initiator);
            (success, result) = address(this).call(abi.encodeWithSelector(IERC4626.mint.selector, shares, receiver));
            uint256 balanceAfter = IERC20(MoreVaultsLib.getUnderlyingTokenAddress()).balanceOf(requestInfo.initiator);
            amountIn = balanceBefore - balanceAfter;
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (uint256 assets, address receiver, address owner) =
                abi.decode(requestInfo.actionCallData, (uint256, address, address));
            uint256 balanceBefore = IERC20(address(this)).balanceOf(owner);
            (success, result) =
                address(this).call(abi.encodeWithSelector(IERC4626.withdraw.selector, assets, receiver, owner));
            uint256 balanceAfter = IERC20(address(this)).balanceOf(owner);
            amountIn = balanceBefore - balanceAfter;
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares, address receiver, address owner) =
                abi.decode(requestInfo.actionCallData, (uint256, address, address));
            (success, result) =
                address(this).call(abi.encodeWithSelector(IERC4626.redeem.selector, shares, receiver, owner));
        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.ACCRUE_FEES) {
            (address user) = abi.decode(requestInfo.actionCallData, (address));
            (success, result) =
                address(this).call(abi.encodeWithSelector(IVaultFacet.accrueFees.selector, user));
        }
        if (!success) revert FinalizationCallFailed();

        uint256 resultValue = abi.decode(result, (uint256));
        if (requestInfo.amountLimit != 0 && requestInfo.actionType != MoreVaultsLib.ActionType.ACCRUE_FEES && requestInfo.actionType != MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            if (requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW || requestInfo.actionType == MoreVaultsLib.ActionType.MINT) {
                if (amountIn > requestInfo.amountLimit) {
                    revert SlippageExceeded(amountIn, requestInfo.amountLimit);
                }
            } else {
                if (resultValue < requestInfo.amountLimit) {
                    revert SlippageExceeded(resultValue, requestInfo.amountLimit);
                }
            }
        }

        ds.guidToCrossChainRequestInfo[guid].finalized = true;
        ds.guidToCrossChainRequestInfo[guid].finalizationResult = resultValue;
        ds.finalizationGuid = 0;

        // Unlock funds after successful execution
        _unlockRequestFunds(requestInfo);
    }

    /**
     * @dev Unlocks funds for a cross-chain request
     * @param requestInfo Request info containing action type and call data
     */
    function _unlockRequestFunds(MoreVaultsLib.CrossChainRequestInfo memory requestInfo) internal {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        if (requestInfo.actionType == MoreVaultsLib.ActionType.DEPOSIT) {
            (uint256 assets,) = abi.decode(requestInfo.actionCallData, (uint256, address));
            address assetToken = MoreVaultsLib.getUnderlyingTokenAddress();
            ds.crossChainLockedTokens[assetToken] -= assets;

        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.MULTI_ASSETS_DEPOSIT) {
            (address[] memory tokens, uint256[] memory assets,,,) =
                abi.decode(requestInfo.actionCallData, (address[], uint256[], address, uint256, uint256));
            for (uint256 i = 0; i < tokens.length; i++) {
                ds.crossChainLockedTokens[tokens[i]] -= assets[i];
            }

        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.WITHDRAW) {
            (uint256 assets,,) = abi.decode(requestInfo.actionCallData, (uint256, address, address));
            uint256 shares = IVaultFacet(address(this)).previewWithdraw(assets);
            ds.crossChainLockedTokens[address(this)] -= shares;

        } else if (requestInfo.actionType == MoreVaultsLib.ActionType.REDEEM) {
            (uint256 shares,,) = abi.decode(requestInfo.actionCallData, (uint256, address, address));
            ds.crossChainLockedTokens[address(this)] -= shares;
        }
        // For MINT and ACCRUE_FEES unlocking is not required
    }

    function getRequestInfo(bytes32 guid) external view returns (MoreVaultsLib.CrossChainRequestInfo memory) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.guidToCrossChainRequestInfo[guid];
    }

    function getFinalizationResult(bytes32 guid) external view returns (uint256 result) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        return ds.guidToCrossChainRequestInfo[guid].finalizationResult;
    }
}
