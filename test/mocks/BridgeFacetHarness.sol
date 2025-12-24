// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";

contract BridgeFacetHarness is BridgeFacet {
    uint256 private _totalAssets;
    mapping(bytes32 => uint256) public depositResult;
    mapping(bytes32 => uint256) public mintResult;
    mapping(bytes32 => uint256) public withdrawResult;
    mapping(bytes32 => uint256) public redeemResult;

    // Expose internal calls for testing where needed
    function h_setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    function h_setDepositResult(bytes32 guid, uint256 result) external {
        depositResult[guid] = result;
    }

    function h_setMintResult(bytes32 guid, uint256 result) external {
        mintResult[guid] = result;
    }

    function h_setWithdrawResult(bytes32 guid, uint256 result) external {
        withdrawResult[guid] = result;
    }

    function h_setRedeemResult(bytes32 guid, uint256 result) external {
        redeemResult[guid] = result;
    }

    // Override IERC4626 methods that BridgeFacet.executeRequest calls via address(this)
    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function totalAssetsUsd() external returns (uint256, bool) {
        return (_totalAssets, true);
    }

    // Stubs to satisfy interface linkage in tests; return configured results for slippage testing
    function deposit(uint256, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return depositResult[guid];
    }

    function deposit(address[] calldata, uint256[] calldata, address) external payable returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return depositResult[guid];
    }

    function mint(uint256, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return mintResult[guid];
    }

    function withdraw(uint256, address, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return withdrawResult[guid];
    }

    function redeem(uint256, address, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return redeemResult[guid];
    }

    function setFee(uint96) external {}
}
