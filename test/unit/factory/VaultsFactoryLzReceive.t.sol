// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultsFactory} from "../../../src/factory/VaultsFactory.sol";
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @notice Mock endpoint for lzReceive tests
contract MockEndpointForReceive {
    uint32 private _eid;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }

    function setDelegate(address) external {}
}

/// @notice Mock vault with owner and hub configuration
contract MockHubVault {
    address private _owner;
    bool private _isHub;

    constructor(address owner_, bool isHub_) {
        _owner = owner_;
        _isHub = isHub_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function isHub() external view returns (bool) {
        return _isHub;
    }

    function setOwner(address newOwner) external {
        _owner = newOwner;
    }
}

contract VaultsFactoryLzReceiveTest is Test {
    VaultsFactoryHarness public factory;
    MockEndpointForReceive public endpoint;
    MockHubVault public hubVault;
    MockHubVault public spokeVault;

    address public admin = address(0x1111);
    address public vaultOwner = address(0x2222);

    uint32 public constant LOCAL_EID = 101; // Hub chain
    uint32 public constant SPOKE_EID = 102; // Spoke chain
    uint96 public constant MAX_FINALIZATION_TIME = 1 days;

    // Message types from VaultsFactory
    uint16 public constant MSG_TYPE_REGISTER_SPOKE = 1;
    uint16 public constant MSG_TYPE_SPOKE_ADDED = 2;
    uint16 public constant MSG_TYPE_BOOTSTRAP = 3;

    event CrossChainLinked(uint32 indexed srcEid, address indexed spokeVault, address indexed hubVault);

    function setUp() public {
        // Deploy mock endpoint
        endpoint = new MockEndpointForReceive(LOCAL_EID);

        // Deploy factory
        factory = new VaultsFactoryHarness(address(endpoint));

        // Initialize factory
        vm.prank(admin);
        factory.initialize(
            admin,
            address(0x5555), // registry
            address(0x6666), // diamondCutFacet
            address(0x7777), // accessControlFacet
            address(0x8888), // wrappedNative
            LOCAL_EID,
            MAX_FINALIZATION_TIME,
            address(0x9999), // lzAdapter
            address(0xAAAA), // composerImplementation
            address(0xBBBB) // oftAdapterFactory
        );

        // Deploy mock vaults
        hubVault = new MockHubVault(vaultOwner, true); // isHub = true
        spokeVault = new MockHubVault(vaultOwner, false); // isHub = false

        // Register hub vault as factory vault
        factory.setFactoryVault(address(hubVault), true);

        // Configure LayerZero peer for SPOKE_EID
        bytes32 spokePeer = bytes32(uint256(uint160(address(factory))));
        vm.prank(admin);
        factory.setPeer(SPOKE_EID, spokePeer);
    }

    function test_lzReceive_MSG_TYPE_REGISTER_SPOKE_Success() public {
        bytes memory rest = abi.encode(address(spokeVault), address(hubVault), vaultOwner);
        bytes memory message = abi.encode(MSG_TYPE_REGISTER_SPOKE, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        vm.expectEmit(true, true, true, true);
        emit CrossChainLinked(SPOKE_EID, address(spokeVault), address(hubVault));

        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");

        (uint32 registeredHubEid, address registeredHubVault) = factory.spokeToHub(SPOKE_EID, address(spokeVault));
        assertEq(registeredHubEid, LOCAL_EID);
        assertEq(registeredHubVault, address(hubVault));
    }

    function test_lzReceive_MSG_TYPE_REGISTER_SPOKE_RevertIfNotFactoryVault() public {
        address fakeHubVault = address(0xDEAD);
        bytes memory rest = abi.encode(address(spokeVault), fakeHubVault, vaultOwner);
        bytes memory message = abi.encode(MSG_TYPE_REGISTER_SPOKE, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAVault.selector, fakeHubVault));
        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");
    }

    function test_lzReceive_MSG_TYPE_REGISTER_SPOKE_RevertIfNotHub() public {
        MockHubVault nonHubVault = new MockHubVault(vaultOwner, false);
        factory.setFactoryVault(address(nonHubVault), true);

        bytes memory rest = abi.encode(address(spokeVault), address(nonHubVault), vaultOwner);
        bytes memory message = abi.encode(MSG_TYPE_REGISTER_SPOKE, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.HubCannotInitiateLink.selector));
        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");
    }

    function test_lzReceive_MSG_TYPE_REGISTER_SPOKE_RevertIfOwnersMismatch() public {
        address differentOwner = address(0x9999);
        hubVault.setOwner(differentOwner);

        bytes memory rest = abi.encode(address(spokeVault), address(hubVault), vaultOwner);
        bytes memory message = abi.encode(MSG_TYPE_REGISTER_SPOKE, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.OwnersMismatch.selector, differentOwner, vaultOwner));
        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");
    }

    function test_lzReceive_MSG_TYPE_REGISTER_SPOKE_Idempotent() public {
        bytes memory rest = abi.encode(address(spokeVault), address(hubVault), vaultOwner);
        bytes memory message = abi.encode(MSG_TYPE_REGISTER_SPOKE, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        factory.exposed_lzReceive(origin, keccak256("guid1"), message, address(endpoint), "");
        factory.exposed_lzReceive(origin, keccak256("guid2"), message, address(endpoint), "");

        (uint32 registeredHubEid, address registeredHubVault) = factory.spokeToHub(SPOKE_EID, address(spokeVault));
        assertEq(registeredHubEid, LOCAL_EID);
        assertEq(registeredHubVault, address(hubVault));
    }

    function test_lzReceive_MSG_TYPE_SPOKE_ADDED_Success() public {
        address newSpokeVault = address(0xABCD);
        uint32 newSpokeEid = 103;

        bytes memory rest = abi.encode(LOCAL_EID, address(hubVault), newSpokeEid, newSpokeVault);
        bytes memory message = abi.encode(MSG_TYPE_SPOKE_ADDED, rest);

        Origin memory origin =
            Origin({srcEid: LOCAL_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");

        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(LOCAL_EID, address(hubVault));
        assertEq(eids.length, 1);
        assertEq(vaults.length, 1);
    }

    function test_lzReceive_MSG_TYPE_BOOTSTRAP_Success() public {
        bytes32[] memory spokes = new bytes32[](3);
        spokes[0] = bytes32(uint256(uint160(address(0x1111))) | (uint256(101) << 160));
        spokes[1] = bytes32(uint256(uint160(address(0x2222))) | (uint256(102) << 160));
        spokes[2] = bytes32(uint256(uint160(address(0x3333))) | (uint256(103) << 160));

        bytes memory rest = abi.encode(LOCAL_EID, address(hubVault), spokes);
        bytes memory message = abi.encode(MSG_TYPE_BOOTSTRAP, rest);

        Origin memory origin =
            Origin({srcEid: LOCAL_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");

        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(LOCAL_EID, address(hubVault));
        assertEq(eids.length, 3);
        assertEq(vaults.length, 3);
    }

    function test_lzReceive_MSG_TYPE_BOOTSTRAP_MergesWithExisting() public {
        bytes32[] memory initialSpokes = new bytes32[](1);
        initialSpokes[0] = bytes32(uint256(uint160(address(0x1111))) | (uint256(101) << 160));

        bytes memory rest1 = abi.encode(LOCAL_EID, address(hubVault), initialSpokes);
        bytes memory message1 = abi.encode(MSG_TYPE_BOOTSTRAP, rest1);

        Origin memory origin =
            Origin({srcEid: LOCAL_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        factory.exposed_lzReceive(origin, keccak256("guid1"), message1, address(endpoint), "");

        bytes32[] memory newSpokes = new bytes32[](2);
        newSpokes[0] = bytes32(uint256(uint160(address(0x2222))) | (uint256(102) << 160));
        newSpokes[1] = bytes32(uint256(uint160(address(0x3333))) | (uint256(103) << 160));

        bytes memory rest2 = abi.encode(LOCAL_EID, address(hubVault), newSpokes);
        bytes memory message2 = abi.encode(MSG_TYPE_BOOTSTRAP, rest2);

        factory.exposed_lzReceive(origin, keccak256("guid2"), message2, address(endpoint), "");

        (uint32[] memory eids, address[] memory vaults) = factory.hubToSpokes(LOCAL_EID, address(hubVault));
        assertEq(eids.length, 3);
        assertEq(vaults.length, 3);
    }

    function test_lzReceive_UnknownMsgType_Reverts() public {
        uint16 unknownMsgType = 999;
        bytes memory rest = abi.encode(address(0x1234));
        bytes memory message = abi.encode(unknownMsgType, rest);

        Origin memory origin =
            Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(address(factory)))), nonce: 1});

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.UnknownMsgType.selector));
        factory.exposed_lzReceive(origin, keccak256("guid"), message, address(endpoint), "");
    }
}
