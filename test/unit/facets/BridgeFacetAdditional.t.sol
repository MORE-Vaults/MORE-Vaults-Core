// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {BridgeFacet} from "../../../src/facets/BridgeFacet.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";

contract BridgeFacetAdditionalTest is Test {
    BridgeFacet public bridgeFacet;

    function setUp() public {
        bridgeFacet = new BridgeFacet();
    }

    function test_facetName_shouldReturnCorrectName() public view {
        string memory name = bridgeFacet.facetName();
        assertEq(name, "BridgeFacet");
    }

    function test_facetVersion_shouldReturnCorrectVersion() public view {
        string memory version = bridgeFacet.facetVersion();
        assertEq(version, "1.0.1");
    }
}
