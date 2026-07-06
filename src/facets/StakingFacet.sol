// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {StakingFacetStorage} from "../libraries/StakingFacetStorage.sol";
import {IStakingFacet} from "../interfaces/facets/IStakingFacet.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StakingFacet
 * @notice Facet for staking vault assets into external LST protocols via whitelisted adapter modules
 * @dev Adapter execution functions are delegatecalled in the vault context and must be stateless.
 *      Position amounts are reported by adapter view functions via staticcall. The facet stores
 *      vault withdrawal request metadata only. Adapters are tracked in
 *      MoreVaultsLib.stakingAddresses[STAKING_FACET_ID]. Withdrawal readiness is enforced only
 *      through adapter.isWithdrawalClaimable. Receipt tokens may be listed in availableAssets;
 *      adapter accounting excludes wallet receipts in that case.
 */
contract StakingFacet is BaseFacetInitializer, IStakingFacet, ReentrancyGuard {
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 internal constant STAKING_FACET_ID = keccak256("StakingFacet");

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.StakingFacet");
    }

    function facetName() external pure returns (string memory) {
        return "StakingFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IStakingFacet).interfaceId] = true;

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        sfs.facetAddress = ds.selectorToFacetAndPosition[IStakingFacet.stake.selector].facetAddress;

        bytes32 facetSelector = abi.decode(data, (bytes32));
        ds.facetsForAccounting.push(facetSelector);
        ds.beforeAccountingFacets.push(sfs.facetAddress);
        ds.vaultExternalAssets[MoreVaultsLib.TokenType.StakingToken].add(STAKING_FACET_ID);
    }

    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IStakingFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds, IStakingFacet.accountingStakingFacet.selector, isReplacing
        );

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        MoreVaultsLib.removeFromBeforeAccounting(ds, sfs.facetAddress, isReplacing);

        if (!isReplacing) {
            ds.vaultExternalAssets[MoreVaultsLib.TokenType.StakingToken].remove(STAKING_FACET_ID);
        }
    }


    function accountingStakingFacet() public view returns (uint256 sum, bool isPositive) {
        return (_computeStakedValue(), true);
    }

    function beforeAccounting() external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        EnumerableSet.AddressSet storage adapters = ds.stakingAddresses[STAKING_FACET_ID];

        for (uint256 i; i < adapters.length();) {
            address adapter = adapters.at(i);
            (bool success,) = adapter.delegatecall(abi.encodeWithSelector(IProtocolAdapter.harvest.selector));
            emit RewardsHarvested(adapter, success);

            unchecked {
                ++i;
            }
        }
    }

    function stake(address adapter, uint256 amount, bytes calldata params)
        external
        nonReentrant
        returns (uint256 receipts)
    {
        if (amount == 0) revert StakingFacetStorage.ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);

        MoreVaultsLib.validateAddressWhitelisted(adapter);
        (address depositToken,) = _resolveAdapterTokens(adapter);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        bytes memory result = _delegatecallAdapter(
            adapter, abi.encodeWithSelector(IProtocolAdapter.stake.selector, amount, params)
        );
        receipts = abi.decode(result, (uint256));

        ds.stakingAddresses[STAKING_FACET_ID].add(adapter);

        emit Staked(adapter, depositToken, amount, receipts);
    }

    function requestUnstake(address adapter, uint256 receipts, bytes calldata params)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (receipts == 0) revert StakingFacetStorage.ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);

        MoreVaultsLib.validateAddressWhitelisted(adapter);

        if (IProtocolAdapter(adapter).isUnstakeBlocked(address(this))) {
            revert StakingFacetStorage.UnstakeBlocked(adapter);
        }

        uint256 available = IProtocolAdapter(adapter).getUnstakeableReceipts(address(this));
        // Adapter-specific: e.g. sFlow async stake leaves FLOW_RECEIPT until fulfillment, so unstake is
        // unavailable while wallet receipt balance is zero even though staking accounting is non-zero.
        if (available < receipts) {
            revert StakingFacetStorage.InsufficientStakedBalance(receipts, available);
        }

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        uint256 adapterRequestNonce = ++sfs.withdrawalRequestNonce[adapter];

        bytes memory result = _delegatecallAdapter(
            adapter,
            abi.encodeWithSelector(IProtocolAdapter.requestUnstake.selector, receipts, params)
        );
        (bytes32 protocolRequestId, uint256 actualReceipts) = abi.decode(result, (bytes32, uint256));

        if (actualReceipts == 0 || actualReceipts > receipts) {
            revert StakingFacetStorage.InvalidUnstakeReceipts(receipts, actualReceipts);
        }

        uint256 expectedClaimableAt =
            IProtocolAdapter(adapter).getWithdrawalClaimableAt(address(this), protocolRequestId);

        requestId = keccak256(abi.encode(adapter, adapterRequestNonce, protocolRequestId));

        sfs.withdrawalRequests[requestId] = StakingFacetStorage.WithdrawalRequest({
            adapter: adapter,
            amount: actualReceipts,
            timestamp: block.timestamp,
            // Informational snapshot from adapter at request time; not enforced on finalize
            expectedClaimableAt: expectedClaimableAt,
            protocolRequestId: protocolRequestId,
            finalized: false
        });

        emit UnstakeRequested(adapter, actualReceipts, requestId);
    }

    /// @notice Finalize a vault withdrawal request: claim from the protocol or close an already-settled request.
    /// @dev `nativeAmountReceived` in `UnstakeFinalized` is the native delta this tx; `requestedSharesAmount`
    ///      is the facet snapshot from unstake time (receipt shares). On shared protocol buckets the first
    ///      claim may emit `nativeAmountReceived` larger than this request's native deposit value — use
    ///      `requestedSharesAmount` for share attribution, not for summing native inflow.
    function finalizeUnstake(bytes32 requestId) external nonReentrant returns (uint256 amount) {
        AccessControlLib.validateDiamond(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.WithdrawalRequest storage request = sfs.withdrawalRequests[requestId];

        if (request.finalized) {
            revert StakingFacetStorage.WithdrawalAlreadyFinalized(requestId);
        }

        address adapter = request.adapter;
        if (adapter == address(0)) {
            revert StakingFacetStorage.WithdrawalRequestNotFound(requestId);
        }

        MoreVaultsLib.validateAddressWhitelisted(adapter);

        bytes32 protocolRequestId = request.protocolRequestId;
        bool completed = IProtocolAdapter(adapter).isWithdrawalCompleted(address(this), protocolRequestId);
        bool claimable = IProtocolAdapter(adapter).isWithdrawalClaimable(address(this), protocolRequestId);

        if (!completed && !claimable) {
            revert StakingFacetStorage.WithdrawalNotReady(
                requestId, IProtocolAdapter(adapter).getWithdrawalClaimableAt(address(this), protocolRequestId)
            );
        }

        bool alreadySettled = completed;

        bytes memory result = _delegatecallAdapter(
            adapter,
            abi.encodeWithSelector(IProtocolAdapter.finalizeUnstake.selector, protocolRequestId)
        );
        amount = abi.decode(result, (uint256));

        request.finalized = true;

        _removeAdapterIfEmpty(adapter);

        emit UnstakeFinalized(requestId, amount, alreadySettled, request.amount);
    }

    /// @notice Recover native deposit-token refunds stranded in the protocol without a facet withdrawal
    ///         request. Edge-case recovery only — e.g. async stake cancelled by the keeper with a refund
    ///         credited to a protocol-side bucket that has no matching `requestUnstake` / `finalizeUnstake`
    ///         flow. Normal withdrawals must use `finalizeUnstake`. If this drains a shared bucket that
    ///         covered open fulfilled requests, call `finalizeUnstake` on each — they sync with
    ///         `alreadySettled=true` and `nativeAmountReceived=0`.
    /// @param params Adapter-specific recovery options forwarded via delegatecall.
    function recoverStrandedWithdrawals(address adapter, bytes calldata params)
        external
        nonReentrant
        returns (uint256 amount)
    {
        AccessControlLib.validateDiamond(msg.sender);

        MoreVaultsLib.validateAddressWhitelisted(adapter);

        bytes memory result = _delegatecallAdapter(
            adapter,
            abi.encodeWithSelector(IProtocolAdapter.recoverStrandedWithdrawals.selector, params)
        );
        amount = abi.decode(result, (uint256));

        if (amount == 0) revert StakingFacetStorage.NoStrandedWithdrawals(adapter);

        _removeAdapterIfEmpty(adapter);

        emit StrandedWithdrawalsRecovered(adapter, amount);
    }

    function getStakedBalance(address adapter) external view returns (uint256) {
        return IProtocolAdapter(adapter).getStakedReceipts(address(this));
    }

    function getPendingUnstake(address adapter) external view returns (uint256) {
        return IProtocolAdapter(adapter).getPendingUnstake(address(this));
    }

    function getUnstakeableReceipts(address adapter) external view returns (uint256) {
        return IProtocolAdapter(adapter).getUnstakeableReceipts(address(this));
    }

    function getAccountingDepositValue(address adapter) external view returns (uint256) {
        return _getAccountingDepositValue(adapter);
    }

    function getActiveAdapters() external view returns (address[] memory) {
        return MoreVaultsLib.moreVaultsStorage().stakingAddresses[STAKING_FACET_ID].values();
    }

    function getWithdrawalRequest(bytes32 requestId)
        external
        view
        returns (StakingFacetStorage.WithdrawalRequest memory)
    {
        return StakingFacetStorage.layout().withdrawalRequests[requestId];
    }

    function _resolveAdapterTokens(address adapter)
        private
        view
        returns (address depositToken, address receiptToken)
    {
        if (adapter == address(0)) revert StakingFacetStorage.InvalidAdapter(adapter);

        depositToken = IProtocolAdapter(adapter).depositToken();
        receiptToken = IProtocolAdapter(adapter).receiptToken();

        if (depositToken == address(0) || receiptToken == address(0)) {
            revert StakingFacetStorage.InvalidAdapter(adapter);
        }

        MoreVaultsLib.validateAssetAvailable(depositToken);
    }

    function _getAccountingDepositValue(address adapter) private view returns (uint256 depositTokenAmount) {
        address receiptToken = IProtocolAdapter(adapter).receiptToken();
        bool receiptIsAvailableAsset = MoreVaultsLib.moreVaultsStorage().isAssetAvailable[receiptToken];
        return IProtocolAdapter(adapter).getAccountingDepositValue(address(this), receiptIsAvailableAsset);
    }

    function _delegatecallAdapter(address adapter, bytes memory data)
        private
        returns (bytes memory result)
    {
        (bool success, bytes memory ret) = adapter.delegatecall(data);
        if (!success) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            }
            revert StakingFacetStorage.AdapterExecutionFailed(adapter, ret);
        }
        return ret;
    }

    function _computeStakedValue() private view returns (uint256 sum) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        EnumerableSet.AddressSet storage adapters = ds.stakingAddresses[STAKING_FACET_ID];

        for (uint256 i; i < adapters.length();) {
            address adapter = adapters.at(i);
            uint256 depositTokenAmount = _getAccountingDepositValue(adapter);

            if (depositTokenAmount == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            address depositToken = IProtocolAdapter(adapter).depositToken();
            sum += MoreVaultsLib.convertToUnderlying(depositToken, depositTokenAmount, Math.Rounding.Floor);

            unchecked {
                ++i;
            }
        }
    }

    function _removeAdapterIfEmpty(address adapter) private {
        if (_getAccountingDepositValue(adapter) >= StakingFacetStorage.ADAPTER_DUST_THRESHOLD) {
            return;
        }
        MoreVaultsLib.moreVaultsStorage().stakingAddresses[STAKING_FACET_ID].remove(adapter);
    }
}
