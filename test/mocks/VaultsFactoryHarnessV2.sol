// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {VaultsFactoryHarness} from "./VaultsFactoryHarness.sol";

/// @notice Extended harness that exposes _updateConnections for integration tests.
/// Bypasses the hubVault == spokeVault check (which only holds in multi-chain production
/// where both factories share the same address via deterministic deployment).
contract VaultsFactoryHarnessV2 is VaultsFactoryHarness {
    constructor(address _endpoint) VaultsFactoryHarness(_endpoint) {}

    /// @notice Directly register a spoke for a hub vault without LZ message.
    /// @dev Calls the internal _updateConnections, skipping the VaultsNotInSameMesh check.
    function exposed_addSpoke(
        uint32 hubEid,
        address hubVault,
        uint32 spokeEid,
        address spokeVault
    ) external {
        _updateConnections(hubEid, hubVault, spokeEid, spokeVault);
    }
}
