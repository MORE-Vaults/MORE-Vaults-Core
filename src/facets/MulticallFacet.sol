// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib, TOTAL_ASSETS_SELECTOR, TOTAL_ASSETS_RUN_FAILED} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IMulticallFacet} from "../interfaces/facets/IMulticallFacet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

contract MulticallFacet is
    BaseFacetInitializer,
    IMulticallFacet,
    ContextUpgradeable,
    ReentrancyGuard
{
    error SlippageExceeded(uint256 slippagePercent, uint256 maxSlippagePercent);

    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.MulticallFacet");
    }

    function facetName() external pure returns (string memory) {
        return "MulticallFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata data) external initializerFacet {
        uint256 timeLockPeriod = abi.decode(data, (uint256));

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IMulticallFacet).interfaceId] = true;

        MoreVaultsLib._setTimeLockPeriod(timeLockPeriod);
    }

    function onFacetRemoval(address, bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IMulticallFacet).interfaceId] = false;
    }

    /**
     * @inheritdoc IMulticallFacet
     */
    function submitActions(
        bytes[] calldata actionsData
    ) external override returns (uint256 nonce) {
        AccessControlLib.validateCurator(msg.sender);
        if (actionsData.length == 0) revert EmptyActions();

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        nonce = ds.actionNonce;
        uint256 pendingUntil = block.timestamp + ds.timeLockPeriod;

        ds.pendingActions[nonce] = MoreVaultsLib.PendingActions({
            actionsData: actionsData,
            pendingUntil: pendingUntil
        });
        ds.actionNonce++;

        emit ActionsSubmitted(msg.sender, nonce, pendingUntil, actionsData);

        if (ds.timeLockPeriod == 0) {
            executeActions(nonce);
        }
    }

    /**
     * @inheritdoc IMulticallFacet
     */
    function executeActions(uint256 actionsNonce) public override nonReentrant {
        AccessControlLib.validateCurator(msg.sender);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        MoreVaultsLib.PendingActions storage actions = ds.pendingActions[
            actionsNonce
        ];

        if (actions.pendingUntil == 0) {
            revert NoSuchActions(actionsNonce);
        }

        if (block.timestamp < actions.pendingUntil) {
            revert ActionsStillPending(actionsNonce);
        }

        uint256 freePtr;
        uint256 totalBefore;
        uint256 totalAfter;
        assembly {
            freePtr := mload(0x40)
            mstore(freePtr, TOTAL_ASSETS_SELECTOR)
            let retOffset := add(freePtr, 4)
            let res := staticcall(gas(), address(), freePtr, 4, retOffset, 0x20)

            if iszero(res) {
                mstore(freePtr, TOTAL_ASSETS_RUN_FAILED)
                revert(freePtr, 4)
            }
            totalBefore := mload(retOffset)
            mstore(0x40, add(freePtr, 4)) // leave the function signature for 2nd call
        }

        ds.isMulticall = true;
        _multicall(actions.actionsData);
        ds.isMulticall = false;

        delete ds.pendingActions[actionsNonce];
        assembly {
            mstore(freePtr, TOTAL_ASSETS_SELECTOR)
            let retOffset := add(freePtr, 4)
            let res := staticcall(gas(), address(), freePtr, 4, retOffset, 0x20)

            if iszero(res) {
                mstore(freePtr, TOTAL_ASSETS_RUN_FAILED)
                revert(freePtr, 4)
            }
            totalAfter := mload(retOffset)
        }

        if (totalBefore > totalAfter) {
            uint256 slippagePercent = ((totalBefore - totalAfter) * 10_000) /
                totalBefore;

            if (slippagePercent > ds.maxSlippagePercent) {
                revert SlippageExceeded(slippagePercent, ds.maxSlippagePercent);
            }
        }

        MoreVaultsLib.checkGasLimitOverflow();

        emit ActionsExecuted(msg.sender, actionsNonce);
    }

    /**
     * @inheritdoc IMulticallFacet
     */
    function vetoActions(uint256[] calldata actionsNonces) external {
        AccessControlLib.validateGuardian(msg.sender);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();

        for (uint256 i = 0; i < actionsNonces.length; ) {
            if (ds.pendingActions[actionsNonces[i]].pendingUntil == 0) {
                revert NoSuchActions(actionsNonces[i]);
            }

            delete ds.pendingActions[actionsNonces[i]];
            emit ActionsVetoed(msg.sender, actionsNonces[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IMulticallFacet
     */
    function getPendingActions(
        uint256 actionsNonce
    )
        external
        view
        override
        returns (bytes[] memory actionsData, uint256 pendingUntil)
    {
        MoreVaultsLib.PendingActions storage actions = MoreVaultsLib
            .moreVaultsStorage()
            .pendingActions[actionsNonce];
        return (actions.actionsData, actions.pendingUntil);
    }

    /**
     * @inheritdoc IMulticallFacet
     */
    function getCurrentNonce() external view override returns (uint256) {
        return MoreVaultsLib.moreVaultsStorage().actionNonce;
    }

    function _multicall(
        bytes[] storage data
    ) internal virtual returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ) {
            (bool success, bytes memory result) = address(this).call(data[i]);
            if (!success) {
                revert MulticallFailed(i, result);
            }
            results[i] = result;
            unchecked {
                ++i;
            }
        }
    }
}
