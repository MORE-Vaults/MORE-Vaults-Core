// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {StakingFacetStorage} from "../libraries/StakingFacetStorage.sol";
import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IStakingFacet} from "../interfaces/facets/IStakingFacet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakingFacet is BaseFacetInitializer, IStakingFacet, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        sfs.depegThresholdBps = 200;
        sfs.circuitBreakerThresholdBps = 300;
        sfs.circuitBreakerTimeWindow = 1 hours;

        if (data.length > 0) {
            bytes32 accountingSelector = abi.decode(data, (bytes32));
            ds.facetsForAccounting.push(accountingSelector);
        }
    }

    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IStakingFacet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(
            ds, bytes4(keccak256(abi.encodePacked("accountingStakingFacet()"))), isReplacing
        );

        MoreVaultsLib.removeFromBeforeAccounting(ds, address(this), isReplacing);
    }

    function stake(address protocol, address token, uint256 amount, bytes calldata params)
        external
        nonReentrant
        returns (uint256 receipts)
    {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocol];

        if (!config.isActive) {
            revert StakingFacetStorage.ProtocolNotActive(protocol);
        }

        if (token != config.depositToken) {
            revert StakingFacetStorage.InvalidProtocolConfig();
        }

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        bytes32 facetId = keccak256("StakingFacet");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeIncreaseAllowance(config.adapter, amount);

        receipts = IProtocolAdapter(config.adapter).stake(amount, params);

        ds.stakingAddresses[facetId].add(protocol);
        ds.tokensHeld[facetId].add(config.receiptToken);
        ds.lockedTokens[config.receiptToken] += receipts;
        config.stakedBalance += receipts;

        emit Staked(protocol, token, amount, receipts);
    }

    function requestUnstake(address protocol, uint256 receipts, bytes calldata params)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocol];

        if (!config.isActive) {
            revert StakingFacetStorage.ProtocolNotActive(protocol);
        }

        if (config.stakedBalance < receipts) {
            revert StakingFacetStorage.InsufficientStakedBalance(receipts, config.stakedBalance);
        }

        IERC20(config.receiptToken).safeIncreaseAllowance(config.adapter, receipts);

        bytes32 protocolRequestId = IProtocolAdapter(config.adapter).requestUnstake(receipts, params);

        requestId = keccak256(abi.encodePacked(protocol, protocolRequestId, block.timestamp));

        sfs.withdrawalRequests[requestId] = StakingFacetStorage.WithdrawalRequest({
            protocol: protocol,
            user: msg.sender,
            amount: receipts,
            timestamp: block.timestamp,
            timelockEnd: block.timestamp + 7 days,
            protocolRequestId: protocolRequestId,
            finalized: false
        });

        emit UnstakeRequested(protocol, receipts, requestId);
    }

    function finalizeUnstake(bytes32 requestId) external nonReentrant returns (uint256 amount) {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.WithdrawalRequest storage request = sfs.withdrawalRequests[requestId];

        if (request.finalized) {
            revert StakingFacetStorage.WithdrawalAlreadyFinalized(requestId);
        }

        if (block.timestamp < request.timelockEnd) {
            revert StakingFacetStorage.WithdrawalNotReady(requestId, request.timelockEnd);
        }

        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[request.protocol];

        amount = IProtocolAdapter(config.adapter).finalizeUnstake(request.protocolRequestId);

        config.stakedBalance -= request.amount;

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.lockedTokens[config.receiptToken] -= request.amount;

        request.finalized = true;

        emit UnstakeFinalized(requestId, amount);
    }

    function curatorInstantUnstake(address protocol, uint256 receipts, bytes calldata swapParams)
        external
        nonReentrant
        returns (uint256 amount)
    {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocol];

        if (!config.isActive) {
            revert StakingFacetStorage.ProtocolNotActive(protocol);
        }

        if (config.stakedBalance < receipts) {
            revert StakingFacetStorage.InsufficientStakedBalance(receipts, config.stakedBalance);
        }

        _checkDepeg(config.receiptToken, sfs.depegThresholdBps);

        (address dexAggregator, bytes memory swapCalldata) = abi.decode(swapParams, (address, bytes));

        MoreVaultsLib.validateAddressWhitelisted(dexAggregator);

        IERC20(config.receiptToken).safeIncreaseAllowance(dexAggregator, receipts);

        (bool success, bytes memory result) = dexAggregator.call(swapCalldata);
        if (!success) {
            assembly {
                let returndata_size := mload(result)
                revert(add(32, result), returndata_size)
            }
        }

        amount = abi.decode(result, (uint256));

        config.stakedBalance -= receipts;

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.lockedTokens[config.receiptToken] -= receipts;

        bytes32 facetId = keccak256("StakingFacet");
        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[facetId], config.receiptToken);

        emit InstantUnstakeExecuted(protocol, receipts, amount);
    }

    function harvest(address protocol) external returns (address[] memory tokens, uint256[] memory amounts) {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocol];

        if (!config.isActive) {
            revert StakingFacetStorage.ProtocolNotActive(protocol);
        }

        (tokens, amounts) = IProtocolAdapter(config.adapter).harvest();
    }

    function harvestAll() external returns (uint256 totalValue) {
        AccessControlLib.validateCurator(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        address[] memory protocols = sfs.activeProtocols.values();

        for (uint256 i; i < protocols.length;) {
            StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocols[i]];

            try IProtocolAdapter(config.adapter).harvest() returns (address[] memory, uint256[] memory amounts) {
                for (uint256 j; j < amounts.length;) {
                    totalValue += amounts[j];
                    unchecked {
                        ++j;
                    }
                }
            } catch {}

            unchecked {
                ++i;
            }
        }
    }

    function addProtocol(address protocol, StakingFacetStorage.ProtocolConfig calldata config) external {
        AccessControlLib.validateOwner(msg.sender);

        if (protocol == address(0) || config.adapter == address(0)) {
            revert StakingFacetStorage.InvalidProtocolConfig();
        }

        MoreVaultsLib.validateAddressWhitelisted(protocol);
        MoreVaultsLib.validateAddressWhitelisted(config.adapter);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();

        if (sfs.protocols[protocol].adapter != address(0)) {
            revert StakingFacetStorage.ProtocolAlreadyExists(protocol);
        }

        sfs.protocols[protocol] = config;
        sfs.activeProtocols.add(protocol);

        emit ProtocolAdded(protocol, config.adapter);
    }

    function removeProtocol(address protocol) external {
        AccessControlLib.validateOwner(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocol];

        if (config.stakedBalance > 0) {
            revert StakingFacetStorage.ProtocolHasBalance(protocol, config.stakedBalance);
        }

        sfs.activeProtocols.remove(protocol);
        delete sfs.protocols[protocol];

        emit ProtocolRemoved(protocol);
    }

    function updateProtocol(address protocol, StakingFacetStorage.ProtocolConfig calldata newConfig) external {
        AccessControlLib.validateOwner(msg.sender);

        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();

        if (sfs.protocols[protocol].adapter == address(0)) {
            revert StakingFacetStorage.ProtocolNotActive(protocol);
        }

        MoreVaultsLib.validateAddressWhitelisted(newConfig.adapter);

        sfs.protocols[protocol] = newConfig;

        emit ProtocolUpdated(protocol);
    }

    function accountingStakingFacet() external returns (uint256 sum, bool isPositive) {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();

        if (sfs.circuitBreakerTriggered) {
            revert StakingFacetStorage.CircuitBreakerActive();
        }

        address[] memory protocols = sfs.activeProtocols.values();

        for (uint256 i; i < protocols.length;) {
            StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocols[i]];

            try IProtocolAdapter(config.adapter).getDepositTokenForReceipts(config.stakedBalance) returns (
                uint256 depositTokenAmount
            ) {
                sum += MoreVaultsLib.convertToUnderlying(config.depositToken, depositTokenAmount, Math.Rounding.Floor);
            } catch {
                sum += MoreVaultsLib.convertToUnderlying(config.receiptToken, config.stakedBalance, Math.Rounding.Floor);
            }

            unchecked {
                ++i;
            }
        }

        _checkCircuitBreaker(sum, sfs);

        return (sum, true);
    }

    function beforeAccounting() external {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        address[] memory protocols = sfs.activeProtocols.values();

        for (uint256 i; i < protocols.length;) {
            StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocols[i]];

            try IProtocolAdapter(config.adapter).harvest() returns (address[] memory, uint256[] memory) {} catch {}

            unchecked {
                ++i;
            }
        }
    }

    function getStakedBalance(address protocol) external view returns (uint256) {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        return sfs.protocols[protocol].stakedBalance;
    }

    function getActiveProtocols() external view returns (address[] memory) {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        return sfs.activeProtocols.values();
    }

    function getTotalStakedValue() external view returns (uint256 totalValue) {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        address[] memory protocols = sfs.activeProtocols.values();

        for (uint256 i; i < protocols.length;) {
            StakingFacetStorage.ProtocolConfig storage config = sfs.protocols[protocols[i]];

            try IProtocolAdapter(config.adapter).getDepositTokenForReceipts(config.stakedBalance) returns (
                uint256 depositTokenAmount
            ) {
                totalValue += MoreVaultsLib.convertToUnderlying(config.depositToken, depositTokenAmount, Math.Rounding.Floor);
            } catch {
                totalValue += MoreVaultsLib.convertToUnderlying(config.receiptToken, config.stakedBalance, Math.Rounding.Floor);
            }

            unchecked {
                ++i;
            }
        }
    }

    function getProtocolConfig(address protocol)
        external
        view
        returns (StakingFacetStorage.ProtocolConfig memory)
    {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        return sfs.protocols[protocol];
    }

    function getWithdrawalRequest(bytes32 requestId)
        external
        view
        returns (StakingFacetStorage.WithdrawalRequest memory)
    {
        StakingFacetStorage.Layout storage sfs = StakingFacetStorage.layout();
        return sfs.withdrawalRequests[requestId];
    }

    function _checkDepeg(address token, uint256 thresholdBps) private {
        uint256 tokenValue = MoreVaultsLib.convertToUnderlying(token, 1e18, Math.Rounding.Floor);
        uint256 expectedValue = 1e18;

        if (tokenValue < expectedValue) {
            uint256 depegBps = ((expectedValue - tokenValue) * 10000) / expectedValue;

            if (depegBps > thresholdBps) {
                emit DepegDetected(token, expectedValue, tokenValue, depegBps);
                revert StakingFacetStorage.DepegThresholdExceeded(depegBps, thresholdBps);
            }
        }
    }

    function _checkCircuitBreaker(uint256 currentValue, StakingFacetStorage.Layout storage sfs) private {
        uint256 lastValue = sfs.lastTotalStakedValue;
        uint256 lastTimestamp = sfs.lastAccountingTimestamp;

        if (lastValue > 0 && currentValue < lastValue) {
            uint256 timeElapsed = block.timestamp - lastTimestamp;
            uint256 dropBps = ((lastValue - currentValue) * 10000) / lastValue;

            if (dropBps > sfs.circuitBreakerThresholdBps && timeElapsed < sfs.circuitBreakerTimeWindow) {
                sfs.circuitBreakerTriggered = true;
                emit CircuitBreakerTriggered(lastValue, currentValue, dropBps);
            }
        }

        sfs.lastTotalStakedValue = currentValue;
        sfs.lastAccountingTimestamp = block.timestamp;
    }
}
