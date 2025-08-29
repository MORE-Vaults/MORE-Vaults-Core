// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/******************************************************************************\
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import {MoreVaultsLib} from "./libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "./libraries/AccessControlLib.sol";
import {IDiamondCut} from "./interfaces/facets/IDiamondCut.sol";
import {IAccessControlFacet} from "./interfaces/facets/IAccessControlFacet.sol";

contract MoreVaultsDiamond {
    error NativeTokenNotAvailable();
    error FunctionDoesNotExist();

    constructor(
        address _diamondCutFacet,
        address _accessControlFacet,
        address _registry,
        address _wrappedNative,
        IDiamondCut.FacetCut[] memory _cuts,
        bytes memory accessControlFacetInitData
    ) payable {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        bytes4[] memory functionSelectorsDc = new bytes4[](1);
        functionSelectorsDc[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsDc,
            initData: ""
        });

        bytes4[] memory functionSelectorsAc = new bytes4[](1);
        functionSelectorsAc[0] = IAccessControlFacet
            .setMoreVaultsRegistry
            .selector;
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: _accessControlFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsAc,
            initData: accessControlFacetInitData
        });
        AccessControlLib.setMoreVaultsRegistry(_registry);

        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.wrappedNative = _wrappedNative;
        ds.factory = msg.sender;

        MoreVaultsLib.diamondCut(cut);
        if (_cuts.length > 0) {
            MoreVaultsLib.diamondCut(_cuts);
        }
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        MoreVaultsLib.MoreVaultsStorage storage ds;
        bytes32 position = MoreVaultsLib.MORE_VAULTS_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) {
            revert FunctionDoesNotExist();
        }
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        if (!ds.isAssetAvailable[ds.wrappedNative]) {
            revert NativeTokenNotAvailable();
        }
    }
}
