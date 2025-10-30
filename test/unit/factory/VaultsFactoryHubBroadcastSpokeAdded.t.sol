// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";

contract MockVaultForBroadcast {
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
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

contract MockEndpointForBroadcast {
    uint256 public quoteFee = 0.01 ether;
    address public delegate;

    struct SendCall {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        address refundAddress;
        uint256 value;
    }

    SendCall[] public sendCalls;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        sendCalls.push(
            SendCall({
                dstEid: _params.dstEid,
                receiver: _params.receiver,
                message: _params.message,
                refundAddress: _refundAddress,
                value: msg.value
            })
        );
        return MessagingReceipt({
            guid: bytes32(sendCalls.length),
            nonce: uint64(sendCalls.length),
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    function setNativeQuoteFee(uint256 _fee) external {
        quoteFee = _fee;
    }

    function getSendCallsCount() external view returns (uint256) {
        return sendCalls.length;
    }

    function getSendCall(uint256 index) external view returns (SendCall memory) {
        return sendCalls[index];
    }
}

contract VaultsFactoryHubBroadcastSpokeAddedTest is Test {
    VaultsFactoryHarness public factory;
    MockEndpointForBroadcast public endpoint;
    MockVaultForBroadcast public hubVault;

    address public admin = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    address public owner = address(0x1111111111111111111111111111111111111111);
    address public notOwner = address(0x2222222222222222222222222222222222222222);

    uint32 public constant LOCAL_EID = 1;
    uint32 public constant DST_EID_1 = 2;
    uint32 public constant DST_EID_2 = 3;
    uint32 public constant NEW_SPOKE_EID = 4;

    address public constant NEW_SPOKE_VAULT = address(0x4444444444444444444444444444444444444444);

    bytes32 public peer1 = bytes32(uint256(uint160(address(0x5555555555555555555555555555555555555555))));
    bytes32 public peer2 = bytes32(uint256(uint160(address(0x6666666666666666666666666666666666666666))));

    bytes public options = hex"0003010011010000000000000000000000000000ea60";

    function setUp() public {
        endpoint = new MockEndpointForBroadcast();
        factory = new VaultsFactoryHarness(address(endpoint));

        // Initialize factory
        vm.prank(admin);
        factory.initialize(
            admin,
            address(0x7777777777777777777777777777777777777777), // registry
            address(0x8888888888888888888888888888888888888888), // diamondCutFacet
            address(0x9999999999999999999999999999999999999999), // accessControlFacet
            address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa), // wrappedNative
            LOCAL_EID,
            1 days, // maxFinalizationTime
            address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB), // lzAdapter
            address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC), // composerImplementation
            address(0xdD2FD4581271e230360230F9337D5c0430Bf44C0) // oftAdapterFactory
        );

        // Create hub vault owned by owner
        hubVault = new MockVaultForBroadcast(owner, true);

        // Register hub vault as factory vault
        factory.setFactoryVault(address(hubVault), true);

        // Set peers for destinations
        vm.startPrank(admin);
        factory.setPeer(DST_EID_1, peer1);
        factory.setPeer(DST_EID_2, peer2);
        vm.stopPrank();
    }

    function test_hubBroadcastSpokeAdded_SingleDestination() public {
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = DST_EID_1;

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubBroadcastSpokeAdded{value: 0.01 ether}(
            address(hubVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );

        // Verify one message was sent
        assertEq(endpoint.getSendCallsCount(), 1);

        MockEndpointForBroadcast.SendCall memory call = endpoint.getSendCall(0);
        assertEq(call.dstEid, DST_EID_1);
        assertEq(call.receiver, peer1);
        assertEq(call.refundAddress, owner);
    }

    function test_hubBroadcastSpokeAdded_MultipleDestinations() public {
        uint32[] memory dstEids = new uint32[](2);
        dstEids[0] = DST_EID_1;
        dstEids[1] = DST_EID_2;

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubBroadcastSpokeAdded{value: 0.02 ether}(
            address(hubVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );

        // Verify two messages were sent
        assertEq(endpoint.getSendCallsCount(), 2);

        MockEndpointForBroadcast.SendCall memory call1 = endpoint.getSendCall(0);
        assertEq(call1.dstEid, DST_EID_1);
        assertEq(call1.receiver, peer1);

        MockEndpointForBroadcast.SendCall memory call2 = endpoint.getSendCall(1);
        assertEq(call2.dstEid, DST_EID_2);
        assertEq(call2.receiver, peer2);
    }

    function test_hubBroadcastSpokeAdded_EmptyDestinations() public {
        uint32[] memory dstEids = new uint32[](0);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubBroadcastSpokeAdded{value: 0 ether}(
            address(hubVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );

        // Verify no messages were sent
        assertEq(endpoint.getSendCallsCount(), 0);
    }

    function test_hubBroadcastSpokeAdded_RevertIfNotFactoryVault() public {
        address notAVault = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = DST_EID_1;

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NotAVault(address)", notAVault));
        factory.hubBroadcastSpokeAdded{value: 0.01 ether}(notAVault, NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options);
    }

    function test_hubBroadcastSpokeAdded_RevertIfNotOwner() public {
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = DST_EID_1;

        vm.deal(notOwner, 1 ether);
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAnOwnerOfVault(address)", notOwner));
        factory.hubBroadcastSpokeAdded{value: 0.01 ether}(
            address(hubVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );
    }

    function test_hubBroadcastSpokeAdded_RevertIfNotHub() public {
        MockVaultForBroadcast spokeVault = new MockVaultForBroadcast(owner, false);
        factory.setFactoryVault(address(spokeVault), true);

        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = DST_EID_1;

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("OnlyHub()"));
        factory.hubBroadcastSpokeAdded{value: 0.01 ether}(
            address(spokeVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );
    }

    function test_hubBroadcastSpokeAdded_LastIterationFlushesRemaining() public {
        uint32[] memory dstEids = new uint32[](2);
        dstEids[0] = DST_EID_1;
        dstEids[1] = DST_EID_2;

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubBroadcastSpokeAdded{value: 0.03 ether}(
            address(hubVault), NEW_SPOKE_EID, NEW_SPOKE_VAULT, dstEids, options
        );

        // Verify the last call receives the remaining budget
        MockEndpointForBroadcast.SendCall memory lastCall = endpoint.getSendCall(1);
        // The last iteration should flush remaining budget (0.03 - 0.01 = 0.02)
        assertGt(lastCall.value, endpoint.quoteFee());
    }
}
