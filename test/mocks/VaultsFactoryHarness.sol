// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {VaultsFactory, Origin} from "../../src/factory/VaultsFactory.sol";

/// @notice Harness contract to expose internal functions for testing
contract VaultsFactoryHarness is VaultsFactory {
    constructor(address _endpoint) VaultsFactory(_endpoint) {}

    function exposed_decodeSpokeKey(bytes32 key) external pure returns (uint32 eid, address vault) {
        return _decodeSpokeKey(key);
    }

    function exposed_encodeSpokeKey(uint32 eid, address vault) external pure returns (bytes32) {
        return _encodeSpokeKey(eid, vault);
    }

    // Helper functions for testing requestRegisterSpoke
    function setFactoryVault(address vault, bool isFactory) external {
        isFactoryVault[vault] = isFactory;
    }

    function setDeployedAt(address vault, uint96 timestamp) external {
        deployedAt[vault] = timestamp;
    }

    // Expose _lzReceive for testing
    function exposed_lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external {
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }
}
