// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";

contract MockVaultForBootstrap {
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

contract MockEndpointForBootstrap {
    uint256 public quoteFee = 0.01 ether;
    uint32 public lastDstEid;
    bytes32 public lastReceiver;
    bytes public lastMessage;
    bytes public lastOptions;
    address public lastRefundAddress;
    address public delegate;

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
        lastDstEid = _params.dstEid;
        lastReceiver = _params.receiver;
        lastMessage = _params.message;
        lastOptions = _params.options;
        lastRefundAddress = _refundAddress;
        return MessagingReceipt({
            guid: bytes32(uint256(1)),
            nonce: 1,
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }

    function setNativeQuoteFee(uint256 _fee) external {
        quoteFee = _fee;
    }
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

contract VaultsFactoryHubSendBootstrapTest is Test {
    VaultsFactoryHarness public factory;
    MockEndpointForBootstrap public endpoint;
    MockVaultForBootstrap public hubVault;
    MockVaultForBootstrap public spokeVault;

    address public admin = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    address public owner = address(0x1111111111111111111111111111111111111111);
    address public notOwner = address(0x2222222222222222222222222222222222222222);

    uint32 public constant LOCAL_EID = 1;
    uint32 public constant DST_EID = 2;
    uint32 public constant SPOKE_EID = 3;

    uint8 public constant MSG_TYPE_BOOTSTRAP = 3;

    bytes32 public dstPeer = bytes32(uint256(uint160(address(0x3333333333333333333333333333333333333333))));
    bytes public options = hex"0003010011010000000000000000000000000000ea60";

    event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);

    function setUp() public {
        endpoint = new MockEndpointForBootstrap();
        factory = new VaultsFactoryHarness(address(endpoint));

        // Initialize factory
        vm.prank(admin);
        factory.initialize(
            admin,
            address(0x5555555555555555555555555555555555555555), // registry
            address(0x6666666666666666666666666666666666666666), // diamondCutFacet
            address(0x7777777777777777777777777777777777777777), // accessControlFacet
            address(0x8888888888888888888888888888888888888888), // wrappedNative
            LOCAL_EID,
            1 days, // maxFinalizationTime
            address(0x9999999999999999999999999999999999999999), // lzAdapter
            address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB), // composerImplementation
            address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC) // oftAdapterFactory
        );

        // Create hub vault owned by owner
        hubVault = new MockVaultForBootstrap(owner, true);

        // Create spoke vault
        spokeVault = new MockVaultForBootstrap(owner, false);

        // Register hub vault as factory vault
        factory.setFactoryVault(address(hubVault), true);

        // Set peer for destination (as admin since setPeer is onlyOwner)
        vm.prank(admin);
        factory.setPeer(DST_EID, dstPeer);
    }

    function test_hubSendBootstrap_Success() public {
        vm.deal(owner, 1 ether);

        vm.prank(owner);
        factory.hubSendBootstrap{value: 0.01 ether}(DST_EID, address(hubVault), options);

        // Verify the message was sent to endpoint
        assertEq(endpoint.lastDstEid(), DST_EID);
        assertEq(endpoint.lastReceiver(), dstPeer);
        assertEq(endpoint.lastRefundAddress(), owner);
    }

    function test_hubSendBootstrap_RevertIfNotFactoryVault() public {
        address notAVault = address(0x4444444444444444444444444444444444444444);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NotAVault(address)", notAVault));
        factory.hubSendBootstrap{value: 0.01 ether}(DST_EID, notAVault, options);
    }

    function test_hubSendBootstrap_RevertIfNotOwner() public {
        vm.deal(notOwner, 1 ether);
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAnOwnerOfVault(address)", notOwner));
        factory.hubSendBootstrap{value: 0.01 ether}(DST_EID, address(hubVault), options);
    }

    function test_hubSendBootstrap_RevertIfNotHub() public {
        MockVaultForBootstrap spokeVaultNotHub = new MockVaultForBootstrap(owner, false);
        factory.setFactoryVault(address(spokeVaultNotHub), true);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("HubCannotInitiateLink()"));
        factory.hubSendBootstrap{value: 0.01 ether}(DST_EID, address(spokeVaultNotHub), options);
    }

    function test_hubSendBootstrap_RevertIfInvalidFee() public {
        vm.deal(owner, 1 ether);

        vm.prank(owner);
        vm.expectRevert("LZ: invalid fee");
        factory.hubSendBootstrap{value: 0.005 ether}(DST_EID, address(hubVault), options);
    }

    function test_hubSendBootstrap_WithEmptySpokes() public {
        // Create new hub with no spokes
        MockVaultForBootstrap newHub = new MockVaultForBootstrap(owner, true);
        factory.setFactoryVault(address(newHub), true);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubSendBootstrap{value: 0.01 ether}(DST_EID, address(newHub), options);

        // Should succeed with empty spokes array
        assertEq(endpoint.lastRefundAddress(), owner);
    }

    function test_hubSendBootstrap_WithDifferentFee() public {
        endpoint.setNativeQuoteFee(0.05 ether);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory.hubSendBootstrap{value: 0.05 ether}(DST_EID, address(hubVault), options);

        assertEq(endpoint.lastRefundAddress(), owner);
    }
}
