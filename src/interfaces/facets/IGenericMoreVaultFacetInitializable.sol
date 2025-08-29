// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacet} from "./IGenericMoreVaultFacet.sol";

interface IGenericMoreVaultFacetInitializable is IGenericMoreVaultFacet {
    function initialize(bytes calldata data) external;

    function onFacetRemoval(address facetAddress, bool isReplacing) external;
}
