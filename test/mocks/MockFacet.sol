// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseFacetInitializer} from "../../src/facets/BaseFacetInitializer.sol";
import {IGenericMoreVaultFacetInitializable} from "../../src/interfaces/facets/IGenericMoreVaultFacetInitializable.sol";

contract MockFacet is
    BaseFacetInitializer,
    IGenericMoreVaultFacetInitializable
{
    // function to exclude from coverage
    function test_skip() external {}

    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.MockFacet");
    }

    function facetName() external pure returns (string memory) {
        return "MockFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata) external initializerFacet {}

    function onFacetRemoval(address, bool) external {}

    function mockFunciton1() external pure returns (bool) {
        return true;
    }

    function mockFunciton2() external pure returns (bool) {
        return true;
    }
}
