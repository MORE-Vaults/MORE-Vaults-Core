// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IVaultComposerAsync, VaultComposerAsync} from "../../../../src/cross-chain/layerZero/VaultComposerAsync.sol";
import {MockEndpointV2} from "../../../../test/mocks/MockEndpointV2.sol";
import {MockVaultFacet} from "../../../../test/mocks/MockVaultFacet.sol";
import {MockOFT} from "../../../../test/mocks/MockOFT.sol";
import {MockOFTAdapter} from "../../../../test/mocks/MockOFTAdapter.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {MockLzAdapterView} from "../../../../test/mocks/MockLzAdapterView.sol";

contract TestableComposer is VaultComposerAsync {
    constructor(address v, address s, address lz) VaultComposerAsync(v, s, lz) {}

    function callSendLocalExpectingRevert() external payable {
        SendParam memory sp;
        sp.dstEid = VAULT_EID;
        sp.to = bytes32(uint256(uint160(address(this))));
        sp.amountLD = 1;
        _send(SHARE_OFT, sp, msg.sender, msg.value);
    }
}

contract VaultComposerAsyncTest is Test {
    using OFTComposeMsgCodec for bytes;

    MockEndpointV2 endpoint;
    MockVaultFacet vault;
    MockOFTAdapter shareOFT;
    MockOFTAdapter assetOFT;
    MockOFT assetToken; // underlying asset for non-primary asset path

    VaultComposerAsync composer;

    MockLzAdapterView lzAdapter;
    address user = address(0xBEEF);
    TestableComposer testComposer;

    function setUp() public {
        endpoint = new MockEndpointV2(101);
        vm.deal(address(endpoint), 100 ether);

        // Set up tokens
        shareOFT = new MockOFTAdapter();
        assetOFT = new MockOFTAdapter();
        assetToken = new MockOFT("Asset", "ASST");

        // Primary vault underlying asset = assetToken, share token must be vault itself
        vault = new MockVaultFacet(address(assetToken), 101);
        shareOFT.setUnderlyingToken(address(vault));
        shareOFT.setEndpoint(address(endpoint));
        assetOFT.setUnderlyingToken(address(assetToken));
        assetOFT.setEndpoint(address(endpoint));

        lzAdapter = new MockLzAdapterView();
        lzAdapter.setTrusted(address(assetOFT), true);

        composer = new VaultComposerAsync(address(vault), address(shareOFT), address(lzAdapter));
        testComposer = new TestableComposer(address(vault), address(shareOFT), address(lzAdapter));
    }

    // ============ Constructor checks ============
    function test_constructor_reverts_whenShareTokenNotVault() public {
        MockOFTAdapter wrongShareOFT = new MockOFTAdapter();
        wrongShareOFT.setUnderlyingToken(address(0xdead));
        wrongShareOFT.setEndpoint(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(IVaultComposerAsync.ShareTokenNotVault.selector, wrongShareOFT.token(), address(vault)));
        new VaultComposerAsync(address(vault), address(wrongShareOFT), address(lzAdapter));
    }

    function test_constructor_reverts_whenShareOFTNotAdapter() public {
        MockOFTAdapter wrongShareOFT = new MockOFTAdapter();
        wrongShareOFT.setUnderlyingToken(address(vault));
        wrongShareOFT.setEndpoint(address(endpoint));
        wrongShareOFT.setApprovalRequired(false);
        vm.expectRevert();
        new VaultComposerAsync(address(vault), address(wrongShareOFT), address(lzAdapter));
    }

    function test_constructor_sets_allowance_for_shareOFT() public {
        uint256 allowance = vault.allowance(address(composer), address(shareOFT));
        assertEq(allowance, type(uint256).max, "share allowance not set");
    }

    // ============ quoteSend ============
    function test_quoteSend_success() public view {
        SendParam memory sp;
        sp.dstEid = 102;
        sp.to = bytes32(uint256(uint160(user)));
        uint256 vaultInAmount = 100e18;
        composer.quoteSend(user, address(shareOFT), vaultInAmount, sp);
    }

    function test_quoteSend_revert_wrongTargetOFT() public {
        SendParam memory sp;
        vm.expectRevert();
        composer.quoteSend(user, address(assetOFT), 1, sp);
    }

    function test_quoteSend_revert_exceedsMaxDeposit() public {
        SendParam memory sp;
        sp.dstEid = 102;
        sp.to = bytes32(uint256(uint160(user)));
        vault.setMaxDeposit(1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, user, 2, 1));
        composer.quoteSend(user, address(shareOFT), 2, sp);
    }

    // ============ lzCompose and handleCompose ============
    function _buildComposeMsg(SendParam memory hop, uint256 minMsgValue, uint32 srcEid, uint256 amountLD)
        internal
        view
        returns (bytes memory)
    {
        bytes memory composePayload = abi.encode(hop, minMsgValue);
        bytes memory header = abi.encodePacked(bytes8(uint64(1)), bytes4(srcEid), bytes32(amountLD));
        // composeFrom = user
        bytes memory full = bytes.concat(header, bytes32(uint256(uint160(user))), composePayload);
        return full;
    }

    function test_lzCompose_revert_onlyEndpoint() public {
        SendParam memory sendParam;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1);
        vm.expectRevert();
        composer.lzCompose(address(assetOFT), bytes32(uint256(1)), msgBytes, address(0), "");
    }

    function test_lzCompose_revert_onlyValidComposeCaller() public {
        vault.setDepositable(address(assetToken), true);
        SendParam memory sendParam;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1);
        vm.prank(address(endpoint));
        vm.expectRevert();
        composer.lzCompose(address(assetOFT), bytes32(uint256(1)), msgBytes, address(0), "");
    }

    function test_lzCompose_success_depositFlow() public {
        // Configure vault fees and depositable
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), false);

        // Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 100e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOFT), bytes32(uint256(1)), msgBytes, address(0), "");
    }

    function test_lzCompose_untrustedOFT_succeeds() public {
        // When OFT is not trusted by adapter, compose skips depositable check branch
        vault.setAccountingFee(0);
        // mark trusted false
        lzAdapter.setTrusted(address(assetOFT), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1e18);
        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOFT), bytes32(uint256(0xabc)), msgBytes, address(0), "");
    }

    function test_handleCompose_revert_insufficientMsgValue() public {
        SendParam memory sendParam;
        bytes memory composeMsg = abi.encode(sendParam, 1 ether);

        vm.expectRevert();
        // self-call restriction path via lzCompose try/catch
        bytes memory header = abi.encodePacked(bytes8(uint64(1)), bytes4(uint32(201)), bytes32(uint256(1)));
        bytes memory full = bytes.concat(header, bytes32(uint256(uint160(user))), composeMsg);
        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOFT), bytes32(uint256(2)), full, address(0), "");
    }

    function test_handleCompose_onlySelf_guard() public {
        vm.expectRevert();
        composer.handleCompose(address(assetOFT), bytes32(uint256(1)), new bytes(0), 0, 0);
    }

    // ============ pending/init/complete/refund paths ============
    function test_initDeposit_revert_on_insufficient_readFee() public {
        // require readFee > msg.value inside _initDeposit
        vault.setAccountingFee(1 ether);
        vault.setDepositable(address(assetToken), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        bytes memory full = _buildComposeMsg(sendParam, 0, 201, 1e18);
        vm.prank(address(endpoint));
        vm.expectRevert();
        composer.lzCompose{value: 0.5 ether}(address(assetOFT), bytes32(uint256(42)), full, address(0), "");
    }

    function test_pendingDeposit_init_and_complete_local_send() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), false);

        SendParam memory sendParam;
        sendParam.dstEid = 101; // local path
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOFT), bytes32(uint256(1001)), full, address(0), "");

        bytes32 guid = vault.getLastGuid();
        vault.setFinalizeShares(guid, amountLD);
        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_completeDeposit_crosschain_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202; // cross chain
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.5 ether}(address(assetOFT), bytes32(uint256(2000)), full, address(0), "");
        bytes32 guid = vault.getLastGuid();
        vault.setFinalizeShares(guid, amountLD);

        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_completeDeposit_reverts_onlyVault_and_missing() public {
        vm.expectRevert();
        composer.completeDeposit(bytes32(uint256(1)));

        vm.expectRevert();
        vm.prank(address(vault));
        composer.completeDeposit(bytes32(uint256(1)));
    }

    function test_completeDeposit_reverts_on_slippage() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202; // cross chain
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 2e18; // require more shares than minted

        uint256 amountLD = 1e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.5 ether}(address(assetOFT), bytes32(uint256(2001)), full, address(0), "");
        bytes32 guid = vault.getLastGuid();
        vault.setFinalizeShares(guid, 1e18);

        vm.expectRevert();
        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_refundDeposit_success() public {
        vault.setAccountingFee(0.2 ether);
        vault.setDepositable(address(assetToken), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 5e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOFT), bytes32(uint256(3001)), full, address(0), "");
        bytes32 guid = vault.getLastGuid();

        vm.prank(address(vault));
        composer.refundDeposit{value: 0}(guid);

        // second refund should revert due to missing deposit
        vm.expectRevert();
        vm.prank(address(vault));
        composer.refundDeposit{value: 0}(guid);
    }

    function test_refundDeposit_reverts_when_notVault_or_missing() public {
        vm.expectRevert();
        composer.refundDeposit(bytes32(uint256(999)));

        vm.expectRevert();
        vm.prank(address(vault));
        composer.refundDeposit(bytes32(uint256(999)));
    }

    function test_lzCompose_refund_path_on_other_revert() public {
        vault.setDepositable(address(assetToken), false);
        vault.setAccountingFee(0);
        vault.setRevertOnInit(true);

        SendParam memory sp;
        sp.dstEid = 202;
        sp.to = bytes32(uint256(uint160(user)));
        bytes memory msgBytes = _buildComposeMsg(sp, 0, 201, 1e18);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.3 ether}(address(assetOFT), bytes32(uint256(777)), msgBytes, address(0), "");
    }

    function test_multiAssetsDeposit_flow_crosschain() public {
        // Create another asset and OFT so token != vault.asset to hit MULTI_ASSETS_DEPOSIT branch
        MockOFTAdapter otherOFT = new MockOFTAdapter();
        MockOFT otherToken = new MockOFT("Other", "OTH");
        otherOFT.setUnderlyingToken(address(otherToken));
        otherOFT.setEndpoint(address(endpoint));
        lzAdapter.setTrusted(address(otherOFT), true);

        vault.setAccountingFee(0);
        // must set depositable false due to current adapter check logic
        vault.setDepositable(address(otherToken), false);

        SendParam memory sp;
        sp.dstEid = 202;
        sp.to = bytes32(uint256(uint160(user)));
        sp.minAmountLD = 0;

        bytes memory msgBytes = _buildComposeMsg(sp, 0, 201, 2e18);
        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.25 ether}(address(otherOFT), bytes32(uint256(0xdead)), msgBytes, address(0), "");

        bytes32 guid = vault.getLastGuid();
        vault.setFinalizeShares(guid, 2e18);
        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_receive_accepts_eth() public {
        (bool ok,) = address(composer).call{value: 1 wei}("");
        assertTrue(ok, "receive failed");
    }

    function test__send_local_revert_on_msg_value() public {
        // Local path must revert if msg.value > 0
        vm.expectRevert(IVaultComposerAsync.NoMsgValueExpected.selector);
        testComposer.callSendLocalExpectingRevert{value: 1 wei}();
    }
}
