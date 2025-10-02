// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";

contract MockVaultFacet {
    address public assetToken;
    bool public isHubFlag = true;
    uint32 public localEid;
    address public adapter;
    uint256 public lastAccountingFeeQuote;

    mapping(bytes32 => bool) public finalized;
    mapping(bytes32 => uint256) public accountingSum;
    mapping(address => bool) public depositableAsset;

    // additional testing state
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public maxDepositLimit = type(uint256).max;
    mapping(bytes32 => uint256) public finalizeSharesByGuid;
    bytes32 public lastGuid;
    bool public revertOnInit;

    constructor(address _asset, uint32 _eid) {
        assetToken = _asset;
        localEid = _eid;
    }

    // IERC4626 minimal subset used by tests
    function asset() external view returns (address) {
        return assetToken;
    }

    function maxDeposit(address) external view returns (uint256) {
        return maxDepositLimit;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address) external pure returns (uint256) {
        return assets;
    }

    function deposit(address[] calldata, uint256[] calldata, address) external pure returns (uint256) {
        return 1;
    }

    // IConfigurationFacet subset used by composer
    function isHub() external view returns (bool) {
        return isHubFlag;
    }

    function setIsHub(bool v) external {
        isHubFlag = v;
    }

    function isAssetDepositable(address token) external view returns (bool) {
        return depositableAsset[token];
    }

    function setDepositable(address token, bool v) external {
        depositableAsset[token] = v;
    }

    function setMaxDeposit(uint256 v) external {
        maxDepositLimit = v;
    }

    // IBridgeFacet
    function quoteAccountingFee(bytes calldata) external view returns (uint256) {
        return lastAccountingFeeQuote;
    }

    function setAccountingFee(uint256 v) external {
        lastAccountingFeeQuote = v;
    }

    function initVaultActionRequest(MoreVaultsLib.ActionType, bytes calldata, bytes calldata)
        external
        payable
        returns (bytes32 guid)
    {
        if (revertOnInit) revert("init-revert");
        guid = bytes32(uint256(0x1));
        lastGuid = guid;
    }

    function updateAccountingInfoForRequest(bytes32 guid, uint256 sum, bool) external {
        accountingSum[guid] = sum;
    }

    function finalizeRequest(bytes32 guid) external payable returns (bytes memory result) {
        finalized[guid] = true;
        result = abi.encode(finalizeSharesByGuid[guid]);
    }

    function setFinalizeShares(bytes32 guid, uint256 shares) external {
        finalizeSharesByGuid[guid] = shares;
    }

    function setRevertOnInit(bool v) external {
        revertOnInit = v;
    }

    function getLastGuid() external view returns (bytes32) {
        return lastGuid;
    }

    // ERC20-like minimal stubs for share token behavior
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, /*to*/ uint256 /*amount*/ ) external pure returns (bool) {
        return true;
    }

    // Unused stubs pruned
}
