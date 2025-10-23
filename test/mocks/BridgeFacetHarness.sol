// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";

contract BridgeFacetHarness is BridgeFacet {
    uint256 private _totalAssets;

    // Expose internal calls for testing where needed
    function h_setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    // Override IERC4626 methods that BridgeFacet.finalizeRequest calls via address(this)
    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function totalAssetsUsd() external returns (uint256, bool) {
        return (_totalAssets, true);
    }

    // Minimal stubs to satisfy interface linkage in tests; logic not needed here
    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function deposit(address[] calldata, uint256[] calldata, address) external payable returns (uint256) {
        return 0;
    }

    function mint(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function setFee(uint96) external {}
}
