// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMoreVaultsComposer} from "../../src/interfaces/LayerZero/IMoreVaultsComposer.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

contract MockMoreVaultsComposer is IMoreVaultsComposer {
    address public vault;
    address public registry;
    address public lzAdapter;
    address public factory;

    bool public shouldRevert = false;
    string public revertMessage = "";

    function initialize(address _vault, address _registry, address _factory) external {
        if (shouldRevert) {
            if (bytes(revertMessage).length > 0) {
                revert(revertMessage);
            } else {
                revert("MockMoreVaultsComposer: initialization failed");
            }
        }

        vault = _vault;
        registry = _registry;
        factory = _factory;
    }

    function setShouldRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }

    // Required view functions
    function VAULT() external view returns (IVaultFacet) {
        return IVaultFacet(vault);
    }

    function SHARE_OFT() external view returns (address) {
        return registry;
    }

    function SHARE_ERC20() external view returns (address) {
        return registry;
    }

    function ENDPOINT() external view returns (address) {
        return lzAdapter;
    }

    function VAULT_EID() external view returns (uint32) {
        return 1;
    }

    // Required functions from IOAppComposer
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable {
        // Mock implementation
    }

    // Required functions from IMoreVaultsComposer
    function quoteSend(address from, address targetOft, uint256 vaultInAmount, SendParam memory sendParam)
        external
        view
        returns (MessagingFee memory msgFee)
    {
        // Mock implementation
        return MessagingFee(0, 0);
    }

    function depositAndSend(
        address tokenAddress,
        uint256 assetAmount,
        SendParam memory sendParam,
        address refundAddress
    ) external payable {
        // Mock implementation
    }

    function initDeposit(
        bytes32 depositor,
        address tokenAddress,
        uint256 assetAmount,
        SendParam memory sendParam,
        address refundAddress,
        uint32 srcEid
    ) external payable {
        // Mock implementation
    }

    function completeDeposit(bytes32 guid) external {
        // Mock implementation
    }

    function refundDeposit(bytes32 guid) external payable {
        // Mock implementation
    }

    receive() external payable {
        // Mock implementation
    }
}
