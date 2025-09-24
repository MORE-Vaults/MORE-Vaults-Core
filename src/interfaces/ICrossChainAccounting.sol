// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IVaultsFactory} from "../interfaces/IVaultsFactory.sol";

interface ICrossChainAccounting {
    function initiateCrossChainAccounting(
        IVaultsFactory.VaultInfo[] memory vaultInfos,
        bytes calldata _extraOptions,
        address _initiator
    ) external payable returns (MessagingReceipt memory receipt);
}
