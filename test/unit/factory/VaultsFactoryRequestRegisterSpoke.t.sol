// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultsFactory, MessagingFee} from "../../../src/factory/VaultsFactory.sol";
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";
import {IAccessControlFacet} from "../../../src/interfaces/facets/IAccessControlFacet.sol";

/// @notice Mock endpoint that supports quote and send
contract MockLayerZeroEndpoint {
    uint32 private _eid;
    uint256 public quoteFee = 0.01 ether;
    address public delegate;

    event MessageSent(uint32 indexed dstEid, bytes payload, address refundAddress);

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view returns (uint32) {
        return _eid;
    }

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }

    function setQuoteFee(uint256 _fee) external {
        quoteFee = _fee;
    }

    // Support both quote signatures
    function quote(
        uint32,
        bytes calldata,
        bytes calldata,
        bool
    ) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    // MessagingParams struct for LayerZero v2
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory) {
        emit MessageSent(_params.dstEid, _params.message, _refundAddress);
        return MessagingReceipt({
            guid: keccak256(abi.encodePacked(_params.dstEid, _params.message)),
            nonce: 1,
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
    }
}

/// @notice Mock vault with access control
contract MockVaultWithOwner {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}

contract VaultsFactoryRequestRegisterSpokeTest is Test {
    VaultsFactoryHarness public factory;
    MockLayerZeroEndpoint public endpoint;
    MockVaultWithOwner public spokeVault;

    address public admin = address(0x1111);
    address public vaultOwner = address(0x2222);
    address public nonOwner = address(0x3333);
    address public hubVault = address(0x4444);

    uint32 public constant LOCAL_EID = 101;
    uint32 public constant HUB_EID = 102;
    uint96 public constant MAX_FINALIZATION_TIME = 1 days;

    uint256 public constant QUOTE_FEE = 0.01 ether;

    event CrossChainLinkRequested(
        uint32 indexed dstEid, address indexed sender, address indexed spokeVault, address hubVault
    );

    function setUp() public {
        // Deploy mock endpoint
        endpoint = new MockLayerZeroEndpoint(LOCAL_EID);
        endpoint.setQuoteFee(QUOTE_FEE);

        // Deploy factory using harness
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
            address(0xBBBB)  // oftAdapterFactory
        );

        // Deploy mock spoke vault
        spokeVault = new MockVaultWithOwner(vaultOwner);

        // Warp forward to have some time
        vm.warp(10 days);

        // Set vault as factory vault using harness
        factory.setFactoryVault(address(spokeVault), true);

        // Set deployedAt timestamp (current time - 2 days, so max finalization passed)
        factory.setDeployedAt(address(spokeVault), uint96(block.timestamp - 2 days));

        // Configure LayerZero peer for HUB_EID
        // The peer should be the factory address on the hub chain (encoded as bytes32)
        bytes32 hubPeer = bytes32(uint256(uint160(address(factory))));
        vm.prank(admin);
        factory.setPeer(HUB_EID, hubPeer);
    }

    function test_requestRegisterSpoke_ShouldRevertIfNotAVault() public {
        address fakeVault = address(0xDEAD);

        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAVault.selector, fakeVault));
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, fakeVault, "");
    }

    function test_requestRegisterSpoke_ShouldRevertIfNotOwner() public {
        vm.deal(nonOwner, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.NotAnOwnerOfVault.selector, nonOwner));
        vm.prank(nonOwner);
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, address(spokeVault), "");
    }

    function test_requestRegisterSpoke_ShouldRevertIfMaxFinalizationTimeNotExceeded() public {
        // Deploy new vault with recent deployment time
        MockVaultWithOwner recentVault = new MockVaultWithOwner(vaultOwner);

        // Set as factory vault using harness
        factory.setFactoryVault(address(recentVault), true);

        // Set deployedAt to current time (not enough time passed)
        factory.setDeployedAt(address(recentVault), uint96(block.timestamp));

        vm.deal(vaultOwner, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(VaultsFactory.MaxFinalizationTimeNotExceeded.selector));
        vm.prank(vaultOwner);
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, address(recentVault), "");
    }

    function test_requestRegisterSpoke_ShouldRevertIfInvalidFee() public {
        uint256 wrongFee = QUOTE_FEE - 1;

        vm.deal(vaultOwner, 1 ether);
        vm.expectRevert("LZ: invalid fee");
        vm.prank(vaultOwner);
        factory.requestRegisterSpoke{value: wrongFee}(HUB_EID, hubVault, address(spokeVault), "");
    }

    function test_requestRegisterSpoke_ShouldSucceedWithCorrectFee() public {
        vm.deal(vaultOwner, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit CrossChainLinkRequested(HUB_EID, vaultOwner, address(spokeVault), hubVault);

        vm.prank(vaultOwner);
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, address(spokeVault), "");
    }

    function test_requestRegisterSpoke_ShouldSucceedWithEmptyOptions() public {
        bytes memory emptyOptions = "";

        vm.deal(vaultOwner, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit CrossChainLinkRequested(HUB_EID, vaultOwner, address(spokeVault), hubVault);

        vm.prank(vaultOwner);
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, address(spokeVault), emptyOptions);
    }

    function test_requestRegisterSpoke_ShouldSucceedWithCustomOptions() public {
        bytes memory customOptions = hex"0001020304";

        vm.deal(vaultOwner, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit CrossChainLinkRequested(HUB_EID, vaultOwner, address(spokeVault), hubVault);

        vm.prank(vaultOwner);
        factory.requestRegisterSpoke{value: QUOTE_FEE}(HUB_EID, hubVault, address(spokeVault), customOptions);
    }
}
