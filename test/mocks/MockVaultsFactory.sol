// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";

contract MockVaultsFactory {
    mapping(uint32 => mapping(address => bool)) public isCrossChainVault;
    uint32 private _localEid;
    mapping(address => bool) private _vaults;
    address public lzAdapter;
    mapping(address => address) public vaultComposer;

    struct HubToSpokes {
        uint32[] eids;
        address[] vaults;
    }

    mapping(bytes32 => HubToSpokes) private _hubToSpokes;

    function setLocalEid(uint32 eid) external {
        _localEid = eid;
    }

    function setHubToSpokes(uint32 chainId, address hubVault, uint32[] calldata eids, address[] calldata vaults)
        external
    {
        bytes32 key = keccak256(abi.encode(chainId, hubVault));
        _hubToSpokes[key] = HubToSpokes({eids: eids, vaults: vaults});
    }

    function localEid() external view returns (uint32) {
        return _localEid;
    }

    function hubToSpokes(uint32 _chainId, address _hubVault)
        external
        view
        returns (uint32[] memory eids, address[] memory vaults)
    {
        HubToSpokes storage h = _hubToSpokes[keccak256(abi.encode(_chainId, _hubVault))];
        return (h.eids, h.vaults);
    }

    function setIsCrossChainVault(uint32 chainId, address vault, bool value) external {
        isCrossChainVault[chainId][vault] = value;
    }

    function setLzAdapter(address _lzAdapter) external {
        lzAdapter = _lzAdapter;
    }

    function setVaultComposer(address vault, address composer) external {
        vaultComposer[vault] = composer;
    }
}
