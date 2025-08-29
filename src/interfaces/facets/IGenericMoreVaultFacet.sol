// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IGenericMoreVaultFacet {
    function facetName() external view returns (string memory);

    function facetVersion() external view returns (string memory);
}
