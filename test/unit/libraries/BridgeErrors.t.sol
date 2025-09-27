// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BridgeErrors} from "../../../src/libraries/BridgeErrors.sol";

// Simple contract to test BridgeErrors library usage and patterns we implemented
contract TestBridgeErrorsUsage {
    mapping(address => bool) public trustedOFTs;
    mapping(uint16 => uint32) public chainIdToEid;
    mapping(uint256 => bool) public chainPaused;

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setTrustedOFT(address oft, bool trusted) external onlyOwner {
        if (oft == address(0)) revert BridgeErrors.ZeroAddress();
        trustedOFTs[oft] = trusted;
    }

    function setChainIdToEid(uint16 chainId, uint32 eid) external onlyOwner {
        chainIdToEid[chainId] = eid;
    }

    function pauseChain(uint256 chainId) external onlyOwner {
        chainPaused[chainId] = true;
    }

    function setTrustedOFTsBatch(
        address[] calldata ofts,
        bool[] calldata trusted
    ) external onlyOwner {
        if (ofts.length != trusted.length) revert BridgeErrors.ArrayLengthMismatch();

        for (uint256 i = 0; i < ofts.length; i++) {
            if (ofts[i] == address(0)) revert BridgeErrors.ZeroAddress();
            trustedOFTs[ofts[i]] = trusted[i];
        }
    }

    // Gas-optimized validation function like we implemented in LzAdapter
    function validateBridgeParams(
        uint256 destChainId,
        address oftToken,
        uint32 layerZeroEid,
        uint256 amount
    ) external view {
        // Single comprehensive check for basic parameters (gas optimized)
        if (amount == 0 ||
            destChainId == 0 ||
            oftToken == address(0) ||
            layerZeroEid == 0) {
            revert BridgeErrors.InvalidBridgeParams();
        }

        // Chain status validation (EID-only approach)
        uint32 configuredEid = chainIdToEid[uint16(destChainId)];
        if (configuredEid == 0) {
            revert BridgeErrors.UnsupportedChain(uint16(destChainId));
        }
        if (chainPaused[destChainId]) {
            revert BridgeErrors.ChainPaused();
        }

        // OFT validation
        if (!trustedOFTs[oftToken]) {
            revert BridgeErrors.UntrustedOFT();
        }

        // Code existence check
        if (oftToken.code.length == 0) {
            revert BridgeErrors.InvalidOFTToken();
        }
    }

    function simulateFailures() external pure {
        // Test various error conditions
        revert BridgeErrors.BridgeFailed();
    }
}

contract BridgeErrorsTest is Test {
    TestBridgeErrorsUsage public testContract;

    address public owner = address(0x1);
    address public user = address(0x2);
    address public mockToken = address(0x1000); // Use a higher address to avoid precompiles

    uint16 public constant CHAIN_ID = 137; // Polygon
    uint32 public constant EID = 30109; // Polygon EID
    uint256 public constant AMOUNT = 1000e18;

    function setUp() public {
        vm.prank(owner);
        testContract = new TestBridgeErrorsUsage();

        // Deploy some bytecode to mockToken so it has code.length > 0
        vm.etch(mockToken, hex"600160005260206000f3");
    }

    function test_skip() external {
        // Function to exclude from coverage
    }

    // ============ BridgeErrors Library Functionality Tests ============

    function test_BridgeErrors_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BridgeErrors.ZeroAddress.selector);
        testContract.setTrustedOFT(address(0), true);
    }

    function test_BridgeErrors_ArrayLengthMismatch() public {
        address[] memory ofts = new address[](2);
        bool[] memory trusted = new bool[](1); // Mismatched length

        ofts[0] = mockToken;
        ofts[1] = address(0x2000);
        trusted[0] = true;

        vm.prank(owner);
        vm.expectRevert(BridgeErrors.ArrayLengthMismatch.selector);
        testContract.setTrustedOFTsBatch(ofts, trusted);
    }

    function test_BridgeErrors_InvalidBridgeParams_ZeroAmount() public {
        // Set up valid chain and OFT
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.setTrustedOFT(mockToken, true);
        vm.stopPrank();

        vm.expectRevert(BridgeErrors.InvalidBridgeParams.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            0 // Zero amount should trigger consolidated error
        );
    }

    function test_BridgeErrors_InvalidBridgeParams_ZeroDestChain() public {
        vm.expectRevert(BridgeErrors.InvalidBridgeParams.selector);
        testContract.validateBridgeParams(
            0, // Zero chain ID
            mockToken,
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_InvalidBridgeParams_ZeroOFTToken() public {
        vm.expectRevert(BridgeErrors.InvalidBridgeParams.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            address(0), // Zero OFT address
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_InvalidBridgeParams_ZeroLayerZeroEid() public {
        vm.expectRevert(BridgeErrors.InvalidBridgeParams.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            0, // Zero EID
            AMOUNT
        );
    }

    function test_BridgeErrors_UnsupportedChain() public {
        // Don't set EID for chain - this tests the EID-only approach
        vm.prank(owner);
        testContract.setTrustedOFT(mockToken, true);

        vm.expectRevert(abi.encodeWithSelector(BridgeErrors.UnsupportedChain.selector, CHAIN_ID));
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_ChainPaused() public {
        // Set up chain and pause it
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.setTrustedOFT(mockToken, true);
        testContract.pauseChain(CHAIN_ID);
        vm.stopPrank();

        vm.expectRevert(BridgeErrors.ChainPaused.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_UntrustedOFT() public {
        // Set up chain but don't trust OFT - tests OFT management moved to adapter
        vm.prank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);

        vm.expectRevert(BridgeErrors.UntrustedOFT.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_InvalidOFTToken_NoCode() public {
        address emptyContract = address(0x999); // No code deployed

        // Set up chain and trust the empty contract
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.setTrustedOFT(emptyContract, true);
        vm.stopPrank();

        vm.expectRevert(BridgeErrors.InvalidOFTToken.selector);
        testContract.validateBridgeParams(
            CHAIN_ID,
            emptyContract,
            EID,
            AMOUNT
        );
    }

    function test_BridgeErrors_BridgeFailed() public {
        vm.expectRevert(BridgeErrors.BridgeFailed.selector);
        testContract.simulateFailures();
    }

    // ============ Positive Test Cases ============

    function test_validateBridgeParams_ShouldPassWithValidParams() public {
        // Set up all valid conditions
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.setTrustedOFT(mockToken, true);
        vm.stopPrank();

        // Should not revert with valid parameters
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            AMOUNT
        );
    }

    function test_setTrustedOFTsBatch_ShouldWorkCorrectly() public {
        address[] memory ofts = new address[](2);
        bool[] memory trusted = new bool[](2);

        ofts[0] = mockToken;
        ofts[1] = address(0x2000);
        trusted[0] = true;
        trusted[1] = false;

        // Deploy code to second address
        vm.etch(ofts[1], hex"600160005260206000f3");

        vm.prank(owner);
        testContract.setTrustedOFTsBatch(ofts, trusted);

        assertTrue(testContract.trustedOFTs(mockToken));
        assertFalse(testContract.trustedOFTs(address(0x2000)));
    }

    // ============ Gas Optimization Tests ============

    function test_validateBridgeParams_GasOptimized() public {
        // Set up valid conditions
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.setTrustedOFT(mockToken, true);
        vm.stopPrank();

        // Measure gas for our optimized validation
        uint256 gasBefore = gasleft();
        testContract.validateBridgeParams(
            CHAIN_ID,
            mockToken,
            EID,
            AMOUNT
        );
        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable for the consolidated validation approach
        assertLt(gasUsed, 15000);
    }

    function test_consolidatedErrorCheck_MultipleInvalidParams() public {
        // Test that multiple invalid params trigger the same consolidated error
        // This validates our gas optimization approach
        vm.expectRevert(BridgeErrors.InvalidBridgeParams.selector);
        testContract.validateBridgeParams(
            0, // Invalid chain
            address(0), // Invalid OFT
            0, // Invalid EID
            0 // Invalid amount
        );
    }

    // ============ EID-Only Chain Management Tests ============

    function test_chainSupport_EIDOnlyApproach() public {
        // Test that chain support is determined solely by EID mapping (our architectural change)
        assertEq(testContract.chainIdToEid(CHAIN_ID), 0); // Initially unsupported

        vm.prank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);

        assertEq(testContract.chainIdToEid(CHAIN_ID), EID); // Now supported
    }

    function test_chainPause_IndependentFromEIDMapping() public {
        // Test that chain pause works independently (our simplified approach)
        vm.startPrank(owner);
        testContract.setChainIdToEid(CHAIN_ID, EID);
        testContract.pauseChain(CHAIN_ID);
        vm.stopPrank();

        assertTrue(testContract.chainPaused(CHAIN_ID));
        assertEq(testContract.chainIdToEid(CHAIN_ID), EID); // EID still there
    }

    // ============ Access Control Tests ============

    function test_onlyOwner_ShouldRevertWhenNotOwner() public {
        vm.startPrank(user);

        vm.expectRevert("Not owner");
        testContract.setChainIdToEid(CHAIN_ID, EID);

        vm.expectRevert("Not owner");
        testContract.setTrustedOFT(mockToken, true);

        vm.expectRevert("Not owner");
        testContract.pauseChain(CHAIN_ID);

        address[] memory ofts = new address[](1);
        bool[] memory trusted = new bool[](1);
        vm.expectRevert("Not owner");
        testContract.setTrustedOFTsBatch(ofts, trusted);

        vm.stopPrank();
    }

    function test_onlyOwner_ShouldPassWhenOwner() public {
        vm.prank(owner);
        testContract.setTrustedOFT(mockToken, true);
        assertTrue(testContract.trustedOFTs(mockToken));
    }

    function test_setTrustedOFTsBatch_NoZeroAddress() public {
        address[] memory ofts = new address[](1);
        bool[] memory trusted = new bool[](1);
        ofts[0] = mockToken; // Non-zero address
        trusted[0] = true;

        vm.prank(owner);
        testContract.setTrustedOFTsBatch(ofts, trusted);
        assertTrue(testContract.trustedOFTs(mockToken));
    }
}