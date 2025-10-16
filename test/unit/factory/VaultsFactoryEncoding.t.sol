// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultsFactoryHarness} from "../../mocks/VaultsFactoryHarness.sol";

contract VaultsFactoryEncodingTest is Test {
    VaultsFactoryHarness public harness;
    address public mockEndpoint = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        harness = new VaultsFactoryHarness(mockEndpoint);
    }

    /// @notice Test that encode and decode are inverses (round-trip test)
    function test_encodeDecode_roundTrip() public {
        uint32 expectedEid = 12345;
        address expectedVault = address(0x1234567890123456789012345678901234567890);

        // Encode
        bytes32 encoded = harness.exposed_encodeSpokeKey(expectedEid, expectedVault);

        // Decode
        (uint32 actualEid, address actualVault) = harness.exposed_decodeSpokeKey(encoded);

        // Assert
        assertEq(actualEid, expectedEid, "EID should match");
        assertEq(actualVault, expectedVault, "Vault address should match");
    }

    /// @notice Test decoding with address(0)
    function test_decodeSpokeKey_withZeroAddress() public {
        uint32 expectedEid = 99999;
        address expectedVault = address(0);

        bytes32 encoded = harness.exposed_encodeSpokeKey(expectedEid, expectedVault);
        (uint32 actualEid, address actualVault) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(actualEid, expectedEid, "EID should match");
        assertEq(actualVault, expectedVault, "Vault address should be zero");
    }

    /// @notice Test decoding with maximum uint32 EID
    function test_decodeSpokeKey_withMaxEid() public {
        uint32 expectedEid = type(uint32).max;
        address expectedVault = address(0xabCDEF1234567890ABcDEF1234567890aBCDeF12);

        bytes32 encoded = harness.exposed_encodeSpokeKey(expectedEid, expectedVault);
        (uint32 actualEid, address actualVault) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(actualEid, expectedEid, "Max EID should match");
        assertEq(actualVault, expectedVault, "Vault address should match");
    }

    /// @notice Test decoding with EID = 0
    function test_decodeSpokeKey_withZeroEid() public {
        uint32 expectedEid = 0;
        address expectedVault = address(0x9999999999999999999999999999999999999999);

        bytes32 encoded = harness.exposed_encodeSpokeKey(expectedEid, expectedVault);
        (uint32 actualEid, address actualVault) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(actualEid, expectedEid, "EID should be zero");
        assertEq(actualVault, expectedVault, "Vault address should match");
    }

    /// @notice Test decoding extracts correct vault address from lower 160 bits
    function test_decodeSpokeKey_extractsVaultCorrectly() public {
        address expectedVault = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        uint32 eid = 1;

        bytes32 encoded = harness.exposed_encodeSpokeKey(eid, expectedVault);
        (, address actualVault) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(actualVault, expectedVault, "Should extract max address correctly");
    }

    /// @notice Test decoding extracts correct EID from upper bits
    function test_decodeSpokeKey_extractsEidCorrectly() public {
        uint32 expectedEid = 54321;
        address vault = address(0x1111111111111111111111111111111111111111);

        bytes32 encoded = harness.exposed_encodeSpokeKey(expectedEid, vault);
        (uint32 actualEid,) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(actualEid, expectedEid, "Should extract EID correctly");
    }

    /// @notice Fuzz test: verify encode/decode round-trip with random inputs
    function testFuzz_encodeDecode_roundTrip(uint32 eid, address vault) public {
        bytes32 encoded = harness.exposed_encodeSpokeKey(eid, vault);
        (uint32 decodedEid, address decodedVault) = harness.exposed_decodeSpokeKey(encoded);

        assertEq(decodedEid, eid, "Fuzz: EID should match");
        assertEq(decodedVault, vault, "Fuzz: Vault address should match");
    }

    /// @notice Test that different inputs produce different encoded values
    function test_encodeSpokeKey_differentInputs_produceDifferentOutputs() public {
        bytes32 encoded1 = harness.exposed_encodeSpokeKey(1, address(0x1111111111111111111111111111111111111111));
        bytes32 encoded2 = harness.exposed_encodeSpokeKey(2, address(0x1111111111111111111111111111111111111111));
        bytes32 encoded3 = harness.exposed_encodeSpokeKey(1, address(0x2222222222222222222222222222222222222222));

        assertTrue(encoded1 != encoded2, "Different EIDs should produce different encodings");
        assertTrue(encoded1 != encoded3, "Different vaults should produce different encodings");
        assertTrue(encoded2 != encoded3, "Different combinations should produce different encodings");
    }
}
