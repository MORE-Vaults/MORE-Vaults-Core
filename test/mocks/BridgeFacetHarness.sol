// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract BridgeFacetHarness is BridgeFacet {
    using SafeERC20 for IERC20;

    uint256 private _totalAssets;
    mapping(bytes32 => uint256) public depositResult;
    mapping(bytes32 => uint256) public mintResult;
    mapping(bytes32 => uint256) public withdrawResult;
    mapping(bytes32 => uint256) public redeemResult;
    mapping(bytes32 => uint256) public accrueFeesResult;
    mapping(bytes32 => uint256) public amountOfTokenToSendIn;
    mapping(address => uint256) private _balances; // Mock balance tracking
    mapping(bytes32 => address) public initiatorByGuid;
    mapping(bytes32 => address) public ownerByGuid;
    
    // Expose internal calls for testing where needed
    function h_setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }
    
    function h_setBalance(address token, address account, uint256 balance) external {
        if (token == address(this)) {
            // For share token (vault itself)
            _balances[account] = balance;
        } else {
            // For underlying token, we'll use MockERC20's balance
            // This is handled by MockERC20 itself
        }
    }

    function h_setDepositResult(bytes32 guid, uint256 result) external {
        depositResult[guid] = result;
    }


    function h_setMintResult(bytes32 guid, uint256 result) external {
        mintResult[guid] = result;
    }

    function h_setInitiatorByGuid(bytes32 guid, address initiator) external {
        initiatorByGuid[guid] = initiator;
        // Also update the actual storage
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.guidToCrossChainRequestInfo[guid].initiator = initiator;
    }

    function h_setOwnerByGuid(bytes32 guid, address owner) external {
        ownerByGuid[guid] = owner;
    }

    function h_setWithdrawResult(bytes32 guid, uint256 result) external {
        withdrawResult[guid] = result;
    }

    function h_setRedeemResult(bytes32 guid, uint256 result) external {
        redeemResult[guid] = result;
    }

    function h_setAccrueFeesResult(bytes32 guid, uint256 result) external {
        accrueFeesResult[guid] = result;
    }
    
    function h_setAmountOfTokenToSendIn(bytes32 guid, uint256 amount) external {
        amountOfTokenToSendIn[guid] = amount;
    }

    function h_setFinalizedByGuid(bytes32 guid, bool finalized) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.guidToCrossChainRequestInfo[guid].finalized = finalized;
    }

    function h_setRefundedByGuid(bytes32 guid, bool refunded) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.guidToCrossChainRequestInfo[guid].refunded = refunded;
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
        address underlying = MoreVaultsLib.getUnderlyingTokenAddress();
        uint256 amount = amountOfTokenToSendIn[guid];
        // Simulate transfer: reduce balance of msg.sender (facet) and increase balance of address(this) (facet)
        // In real scenario, tokens are transferred from user to vault, but here msg.sender is facet itself
        // So we simulate by directly updating MockERC20 balances
        if (amount > 0) {
            // Use MockERC20's transfer function to simulate the transfer
            // This will update balances correctly for balanceOf checks
            MockERC20(underlying).transfer(initiatorByGuid[guid], address(this), amount);
        }
        return mintResult[guid];
    }

    function withdraw(uint256, address, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        uint256 amount = amountOfTokenToSendIn[guid];
        // Simulate transfer of share tokens (vault tokens)
        // In real scenario, share tokens are burned/transferred from user
        // Here we simulate by reducing balance of address(this) (facet) since withdraw is called via address(this).call
        // The balance check in BridgeFacet checks balanceOf(address(this)) before and after
        _balances[ownerByGuid[guid]] -= amount;
        return withdrawResult[guid];
    }
    
    // Mock ERC20 balanceOf for share token (vault itself)
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function redeem(uint256, address, address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return redeemResult[guid];
    }

    function accrueFees(address) external returns (uint256) {
        bytes32 guid = MoreVaultsLib.moreVaultsStorage().finalizationGuid;
        return accrueFeesResult[guid];
    }

    function setFee(uint96) external {}
}
