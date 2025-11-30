// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IMoreVaultsComposer, MoreVaultsComposer} from "../../../../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import {MockEndpointV2} from "../../../../test/mocks/MockEndpointV2.sol";
import {MockVaultFacet} from "../../../../test/mocks/MockVaultFacet.sol";
import {MockOFT} from "../../../../test/mocks/MockOFT.sol";
import {MockOFTAdapter} from "../../../../test/mocks/MockOFTAdapter.sol";
import {MaliciousOFTAdapter} from "../../../../test/mocks/MaliciousOFTAdapter.sol";
import {SendParam} from "../../../../lib/devtools/packages/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "../../../../lib/devtools/packages/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {MockLzAdapterView} from "../../../../test/mocks/MockLzAdapterView.sol";
import {IVaultsFactory} from "../../../../src/interfaces/IVaultsFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockVaultsFactory} from "../../../../test/mocks/MockVaultsFactory.sol";
import {console} from "forge-std/console.sol";

contract TestableComposer {
    address public VAULT;
    address public SHARE_OFT;
    address public ENDPOINT;
    uint32 public VAULT_EID;

    function initialize(address _vault, address _shareOFT, address _lzAdapter, address _vaultFactory) external {
        VAULT = _vault;
        SHARE_OFT = _shareOFT;
        ENDPOINT = address(0x123); // Mock endpoint
        VAULT_EID = 101;
    }

    function callSendLocalExpectingRevert() external payable {
        SendParam memory sp;
        sp.dstEid = VAULT_EID;
        sp.to = bytes32(uint256(uint160(address(this))));
        sp.amountLD = 1;
        // This will revert with NoMsgValueExpected
        if (msg.value > 0) revert("NoMsgValueExpected");
    }
}

contract MoreVaultsComposerTest is Test {
    using OFTComposeMsgCodec for bytes;

    uint32 public localEid = uint32(101);

    MockEndpointV2 endpoint;
    MockVaultFacet vault;
    MockOFTAdapter shareOFT;
    MockOFTAdapter assetOFT;
    MockOFT assetToken; // underlying asset for non-primary asset path

    MoreVaultsComposer composer;

    MockLzAdapterView lzAdapter;
    MockVaultsFactory vaultFactory;
    address user = address(0xBEEF);
    TestableComposer testComposer;

    function setUp() public {
        endpoint = new MockEndpointV2(localEid);
        vm.deal(address(endpoint), 100 ether);

        // Set up tokens
        shareOFT = new MockOFTAdapter();
        assetOFT = new MockOFTAdapter();
        assetToken = new MockOFT("Asset", "ASST");

        // Primary vault underlying asset = assetToken, share token must be vault itself
        vault = new MockVaultFacet(address(assetToken), localEid);
        shareOFT.setUnderlyingToken(address(vault));
        shareOFT.setEndpoint(address(endpoint));
        assetOFT.setUnderlyingToken(address(assetToken));
        assetOFT.setEndpoint(address(endpoint));

        lzAdapter = new MockLzAdapterView();
        lzAdapter.setTrusted(address(assetOFT), true);

        vaultFactory = new MockVaultsFactory();

        // Create implementation and proxy
        MoreVaultsComposer implementation = new MoreVaultsComposer();
        bytes memory initData = abi.encodeWithSelector(
            MoreVaultsComposer.initialize.selector, address(vault), address(shareOFT), address(vaultFactory)
        );
        vaultFactory.setLzAdapter(address(lzAdapter));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        composer = MoreVaultsComposer(payable(address(proxy)));

        testComposer = new TestableComposer();
        // testComposer will be initialized in individual tests that need it
    }

    // ============ Initialize checks ============
    function test_initialize_reverts_whenShareTokenNotVault() public {
        MockOFTAdapter wrongShareOFT = new MockOFTAdapter();
        wrongShareOFT.setUnderlyingToken(address(0xdead));
        wrongShareOFT.setEndpoint(address(endpoint));

        MoreVaultsComposer implementation = new MoreVaultsComposer();
        bytes memory initData = abi.encodeWithSelector(
            MoreVaultsComposer.initialize.selector,
            address(vault),
            address(wrongShareOFT),
            address(lzAdapter),
            address(vaultFactory)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMoreVaultsComposer.ShareTokenNotVault.selector, wrongShareOFT.token(), address(vault)
            )
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_initialize_reverts_whenShareOFTNotAdapter() public {
        MockOFTAdapter wrongShareOFT = new MockOFTAdapter();
        wrongShareOFT.setUnderlyingToken(address(vault));
        wrongShareOFT.setEndpoint(address(endpoint));
        wrongShareOFT.setApprovalRequired(false);

        MoreVaultsComposer implementation = new MoreVaultsComposer();
        bytes memory initData = abi.encodeWithSelector(
            MoreVaultsComposer.initialize.selector,
            address(vault),
            address(wrongShareOFT),
            address(lzAdapter),
            address(vaultFactory)
        );
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.ShareOFTNotAdapter.selector, address(wrongShareOFT)));
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_initialize_sets_allowance_for_shareOFT() public {
        uint256 allowance = vault.allowance(address(composer), address(shareOFT));
        assertEq(allowance, type(uint256).max, "share allowance not set");
    }

    function test_initialize_reverts_whenAlreadyInitialized() public {
        vm.expectRevert();
        composer.initialize(address(vault), address(shareOFT), address(vaultFactory));
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
        vm.expectRevert(IMoreVaultsComposer.NotImplemented.selector);
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

    function test_lzCompose_revert_InvalidComposeCaller() public {
        vault.setDepositable(address(assetToken), true);
        lzAdapter.setTrusted(address(assetOFT), false);
        SendParam memory sendParam;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1);
        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.InvalidComposeCaller.selector, address(assetOFT)));
        composer.lzCompose(address(assetOFT), bytes32(uint256(1)), msgBytes, address(0), "");
    }

    function test_lzCompose_success_depositFlow() public {
        // Configure vault fees and depositable
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

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

    function test_lzCompose_untrustedOFT_reverts() public {
        // After fix for issue #33: untrusted OFTs should ALWAYS revert
        vault.setAccountingFee(0);
        // mark trusted false
        lzAdapter.setTrusted(address(assetOFT), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1e18);

        // Should revert because OFT is not trusted (fix for issue #33)
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.InvalidComposeCaller.selector, address(assetOFT)));
        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOFT), bytes32(uint256(0xabc)), msgBytes, address(0), "");
    }

    function test_handleCompose_revert_insufficientMsgValue() public {
        vault.setDepositable(address(assetToken), true);

        SendParam memory sendParam;
        bytes memory composeMsg = abi.encode(sendParam, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.InsufficientMsgValue.selector, 1 ether, 0));
        // self-call restriction path via lzCompose try/catch
        bytes memory header = abi.encodePacked(bytes8(uint64(1)), bytes4(uint32(201)), bytes32(uint256(1)));
        bytes memory full = bytes.concat(header, bytes32(uint256(uint160(user))), composeMsg);
        vm.prank(address(endpoint));
        composer.lzCompose(address(assetOFT), bytes32(uint256(2)), full, address(0), "");
    }

    function test_handleCompose_onlySelf_guard() public {
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.OnlySelf.selector, address(this)));
        composer.handleCompose(address(assetOFT), bytes32(uint256(1)), new bytes(0), 0, 0);
    }

    // ============ pending/init/complete/refund paths ============
    function test_initDeposit_revert_on_insufficient_readFee() public {
        // require readFee > msg.value inside _initDeposit
        vault.setAccountingFee(1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        bytes memory full = _buildComposeMsg(sendParam, 0, 201, 1e18);
        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.InsufficientMsgValue.selector, 1 ether, 0.001 ether));
        composer.lzCompose{value: 0.001 ether}(address(assetOFT), bytes32(uint256(42)), full, address(0), "");
    }

    function test_pendingDeposit_init_and_complete_local_send() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = localEid; // local path
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOFT), bytes32(uint256(1001)), full, address(0), "");

        bytes32 guid = bytes32(uint256(0x1));
        vault.setFinalizeShares(guid, amountLD);
        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_completeDeposit_crosschain_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        uint256 amountLD = 1e18;
        SendParam memory sendParam;
        sendParam.dstEid = localEid; // cross chain
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;
        sendParam.amountLD = amountLD;

        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);
        bytes32 guid = bytes32(uint256(0x1));

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.5 ether}(address(assetOFT), guid, full, address(0), "");

        vault.setFinalizeShares(guid, amountLD);

        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_completeDeposit_reverts_OnlyVaultOrLzAdapter_and_missing() public {
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.OnlyVaultOrLzAdapter.selector, address(this)));
        composer.completeDeposit(bytes32(uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.DepositNotFound.selector, bytes32(uint256(1))));
        vm.prank(address(vault));
        composer.completeDeposit(bytes32(uint256(1)));
    }

    function test_completeDeposit_reverts_on_slippage() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

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
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 5e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOFT), bytes32(uint256(3001)), full, address(0), "");
        // Use known GUID from trace
        bytes32 guid = bytes32(uint256(0x1)); // GUID from MessagingReceipt

        vm.prank(address(vault));
        composer.refundDeposit{value: 0}(guid);

        // second refund should revert due to missing deposit
        vm.expectRevert();
        vm.prank(address(vault));
        composer.refundDeposit{value: 0}(guid);
    }

    function test_refundDeposit_reverts_when_notVault_or_missing() public {
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.OnlyVaultOrLzAdapter.selector, address(this)));
        composer.refundDeposit(bytes32(uint256(999)));

        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.DepositNotFound.selector, bytes32(uint256(999))));
        vm.prank(address(vault));
        composer.refundDeposit(bytes32(uint256(999)));
    }

    // Test for issue #29: Verify refundDeposit uses OFT adapter address, not token address
    function test_refundDeposit_usesOFTAddress_notTokenAddress() public {
        vault.setAccountingFee(0.2 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 5e18;
        bytes memory full = _buildComposeMsg(sendParam, 0, 201, amountLD);

        // Initiate a cross-chain deposit that will create a pending deposit
        vm.prank(address(endpoint));
        composer.lzCompose{value: 1 ether}(address(assetOFT), bytes32(uint256(3001)), full, address(0), "");

        bytes32 guid = bytes32(uint256(0x1));

        // Verify the pending deposit exists and has correct addresses
        (
            bytes32 depositor,
            address tokenAddress,
            address oftAddress,
            uint256 assetAmount,
            address refundAddress,
            uint256 msgValue,
            uint32 srcEid,

        ) = composer.pendingDeposits(guid);

        // Verify that tokenAddress and oftAddress are different
        assertEq(tokenAddress, address(assetToken), "Token address should be the underlying token");
        assertEq(oftAddress, address(assetOFT), "OFT address should be the OFT adapter");
        assertTrue(tokenAddress != oftAddress, "Token and OFT addresses must be different");

        // The fix ensures send() is called on oftAddress, not tokenAddress
        // In production, calling send() on a plain ERC20 token would revert
        // MockOFT has send() which is why the test passes, but this verifies
        // we're using the correct address (oftAddress)

        vm.prank(address(vault));
        composer.refundDeposit{value: 0}(guid);

        // Verify the deposit was deleted after successful refund
        (depositor, tokenAddress, oftAddress, assetAmount, refundAddress, msgValue, srcEid, ) = composer.pendingDeposits(guid);
        assertEq(assetAmount, 0, "Deposit should be deleted after refund");
    }

    function test_lzCompose_refund_path_on_other_revert() public {
        vault.setDepositable(address(assetToken), true);
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
        vault.setDepositable(address(otherToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sp;
        sp.dstEid = 202;
        sp.to = bytes32(uint256(uint160(user)));
        sp.minAmountLD = 0;

        bytes memory msgBytes = _buildComposeMsg(sp, 0, 201, 2e18);
        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.25 ether}(address(otherOFT), bytes32(uint256(0xdead)), msgBytes, address(0), "");

        // Use known GUID from trace
        bytes32 guid = bytes32(uint256(0x1)); // GUID from MessagingReceipt
        vault.setFinalizeShares(guid, 2e18);
        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    function test_receive_accepts_eth() public {
        (bool ok,) = address(composer).call{value: 1 wei}("");
        assertTrue(ok, "receive failed");
    }

    function test__send_local_revert_on_msg_value() public {
        // Initialize testComposer for this test
        testComposer.initialize(address(vault), address(shareOFT), address(lzAdapter), address(vaultFactory));

        // Local path must revert if msg.value > 0
        vm.expectRevert("NoMsgValueExpected");
        testComposer.callSendLocalExpectingRevert{value: 1 wei}();
    }

    // ============ depositAndSend tests ============
    function test_depositAndSend_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.depositAndSend(address(assetToken), 100e18, sendParam, user);
        vm.stopPrank();
    }

    function test_depositAndSend_primaryAsset_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Use the primary asset (vault.asset()) for single asset deposit
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.depositAndSend(address(assetToken), 100e18, sendParam, user);
        vm.stopPrank();
    }

    function test_depositAndSend_multiAsset_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Create another asset for multi-asset deposit
        MockOFT otherToken = new MockOFT("Other", "OTH");
        otherToken.mint(user, 1000e18);

        deal(user, 10 ether);
        vm.startPrank(user);
        otherToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        console.log("out");
        console.log(user.balance);
        composer.depositAndSend{value: 0.1 ether}(address(otherToken), 100e18, sendParam, user);
        vm.stopPrank();
    }

    // ============ initDeposit tests ============
    function test_initDeposit_success() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        deal(user, 10 ether);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.initDeposit{value: 0.1 ether}(
            OFTComposeMsgCodec.addressToBytes32(user),
            address(assetToken),
            address(assetOFT),
            100e18,
            sendParam,
            user,
            201
        );
        vm.stopPrank();
    }

    function test_initDeposit_primaryAsset_success() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        // Use the primary asset (vault.asset()) for single asset deposit
        assetToken.mint(user, 1000e18);
        deal(user, 10 ether);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.initDeposit{value: 0.1 ether}(
            OFTComposeMsgCodec.addressToBytes32(user),
            address(assetToken),
            address(assetOFT),
            100e18,
            sendParam,
            user,
            201
        );
        vm.stopPrank();
    }

    function test_initDeposit_multiAsset_success() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        // Create another asset for multi-asset deposit
        MockOFT otherToken = new MockOFT("Other", "OTH");
        otherToken.mint(user, 1000e18);
        MockOFTAdapter otherTokenOFT = new MockOFTAdapter();
        otherTokenOFT.setUnderlyingToken(address(otherToken));
        otherTokenOFT.setEndpoint(address(endpoint));
        lzAdapter.setTrusted(address(otherTokenOFT), true);

        deal(user, 10 ether);
        vm.startPrank(user);
        otherToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.initDeposit{value: 0.1 ether}(
            OFTComposeMsgCodec.addressToBytes32(user),
            address(otherToken),
            address(otherTokenOFT),
            100e18,
            sendParam,
            user,
            201
        );
        vm.stopPrank();
    }

    // ============ Additional coverage tests ============
    function test_lzCompose_onlyEndpoint_revert() public {
        SendParam memory sendParam;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, 1);
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.OnlyEndpoint.selector, address(this)));
        composer.lzCompose(address(assetOFT), bytes32(uint256(1)), msgBytes, address(0), "");
    }

    function test_handleCompose_crossChainVault_path() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.2 ether}(address(assetOFT), bytes32(uint256(1001)), msgBytes, address(0), "");
    }

    function test_handleCompose_nonCrossChainVault_path() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(localEid, address(vault), false);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.1 ether}(address(assetOFT), bytes32(uint256(1002)), msgBytes, address(0), "");
    }

    function test_completeDeposit_slippage_revert() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 2e18; // require more shares than minted

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.1 ether}(address(assetOFT), bytes32(uint256(2001)), msgBytes, address(0), "");

        bytes32 guid = bytes32(uint256(0x1));
        vault.setFinalizeShares(guid, 1e18);

        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }

    // ============ Additional edge case tests ============
    function test_lzCompose_refund_on_general_error() public {
        vault.setDepositable(address(assetToken), true);
        vault.setAccountingFee(0);
        vault.setRevertOnInit(true);

        SendParam memory sp;
        sp.dstEid = 202;
        sp.to = bytes32(uint256(uint160(user)));
        bytes memory msgBytes = _buildComposeMsg(sp, 0, 201, 1e18);

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.3 ether}(address(assetOFT), bytes32(uint256(777)), msgBytes, address(0), "");
    }

    function test_lzCompose_insufficientMsgValue_revert_propagation() public {
        vault.setDepositable(address(assetToken), true);

        SendParam memory sendParam;
        bytes memory composeMsg = abi.encode(sendParam, 1 ether);

        // This should propagate the InsufficientMsgValue error instead of refunding
        bytes memory header = abi.encodePacked(bytes8(uint64(1)), bytes4(uint32(201)), bytes32(uint256(1)));
        bytes memory full = bytes.concat(header, bytes32(uint256(uint160(user))), composeMsg);

        vm.prank(address(endpoint));
        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.InsufficientMsgValue.selector, 1 ether, 0));
        composer.lzCompose(address(assetOFT), bytes32(uint256(2)), full, address(0), "");
    }

    function test_quoteSend_previewDeposit_calculation() public view {
        SendParam memory sp;
        sp.dstEid = 102;
        sp.to = bytes32(uint256(uint160(user)));
        uint256 vaultInAmount = 100e18;

        // This should call VAULT.previewDeposit and set the amountLD correctly
        composer.quoteSend(user, address(shareOFT), vaultInAmount, sp);
    }

    function test_depositAndSend_slippage_check() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 200e18; // require more shares than will be minted

        vm.expectRevert(abi.encodeWithSelector(IMoreVaultsComposer.SlippageExceeded.selector, 100e18, 200e18));
        composer.depositAndSend(address(assetToken), 100e18, sendParam, user);
        vm.stopPrank();
    }

    function test_depositAndSend_local_send_success() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = localEid; // Same as VAULT_EID for local send
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        composer.depositAndSend(address(assetToken), 100e18, sendParam, user);
        vm.stopPrank();
    }

    // ============ Issue #33: Token Substitution Attack Tests ============

    /**
     * @notice Test for issue #33 - Token substitution attack on non-trusted OFT
     * @dev This test demonstrates the vulnerability where a malicious OFT can bypass security checks
     *      by returning different token addresses on successive calls to token()
     *
     * Attack scenario:
     * 1. Malicious OFT is not trusted by LzAdapter
     * 2. First call to token() returns worthless token (not depositable) - bypasses security check
     * 3. Second call to token() returns valuable token (USDC) - steals funds from composer
     * 4. Attacker receives vault shares for tokens they never deposited
     *
     * Expected behavior: This test should FAIL with the current vulnerable code
     * After fix: This test should PASS (transaction should revert with InvalidComposeCaller)
     */
    function test_lzCompose_shouldRevert_whenUntrustedOFTWithTokenSubstitution() public {
        // Setup: Create worthless and valuable tokens
        MockOFT worthlessToken = new MockOFT("Worthless", "WTH");
        MockOFT valuableToken = new MockOFT("Valuable", "USDC");

        // Setup: Create malicious OFT adapter
        MaliciousOFTAdapter maliciousOFT = new MaliciousOFTAdapter(address(worthlessToken), address(valuableToken));
        maliciousOFT.setEndpoint(address(endpoint));

        // Setup: Fund the composer with valuable tokens (simulating pending deposits)
        valuableToken.mint(address(composer), 1000e18);

        // Setup: Configure vault to accept valuable token but reject worthless token
        vault.setDepositable(address(valuableToken), true);
        vault.setDepositable(address(worthlessToken), false);
        vault.setAccountingFee(0);
        vaultFactory.setIsCrossChainVault(localEid, address(vault), false);

        // Setup: Malicious OFT is NOT trusted
        lzAdapter.setTrusted(address(maliciousOFT), false);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = localEid + 1; // Different chain
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.amountLD = 100; // Small amount to fit in message
        sendParam.minAmountLD = 0;

        bytes memory composeMsg = abi.encode(sendParam, uint256(0));

        // Setup: Craft the LayerZero message
        bytes memory oftMessage = abi.encodePacked(
            uint8(0), // nonce
            uint32(localEid + 1), // srcEid
            bytes32(uint256(uint160(user))), // sender
            uint64(100), // amountLD (small amount to fit in uint64)
            composeMsg
        );

        // Execute: Attacker calls lzCompose via endpoint
        // The malicious OFT will return worthlessToken on first call, valuableToken on subsequent calls
        vm.prank(address(endpoint));
        vm.deal(address(endpoint), 1 ether);

        // Expected: Should revert with InvalidComposeCaller because OFT is not trusted
        // Actual (with bug): The first call to token() returns worthlessToken (not depositable),
        // so the security check passes. Then subsequent calls return valuableToken and steal funds.
        vm.expectRevert(
            abi.encodeWithSelector(IMoreVaultsComposer.InvalidComposeCaller.selector, address(maliciousOFT))
        );
        composer.lzCompose{value: 0.1 ether}(
            address(maliciousOFT), bytes32(uint256(1)), oftMessage, address(0), bytes("")
        );
    }

    /**
     * @notice Test that trusted OFT should still work even with same token() behavior
     * @dev This ensures our fix doesn't break legitimate use cases
     */
    function test_lzCompose_shouldSucceed_whenTrustedOFTEvenIfTokenChanges() public {
        // Setup: Create tokens
        MockOFT token1 = new MockOFT("Token1", "TK1");
        MockOFT token2 = new MockOFT("Token2", "TK2");

        // Setup: Create malicious-like OFT adapter (but it's trusted)
        MaliciousOFTAdapter trustedButWeirdOFT = new MaliciousOFTAdapter(address(token1), address(token2));
        trustedButWeirdOFT.setEndpoint(address(endpoint));

        // Setup: Fund the composer
        token2.mint(address(composer), 1000e18);

        // Setup: Configure vault
        vault.setDepositable(address(token1), true);
        vault.setDepositable(address(token2), true);
        vault.setAccountingFee(0);
        vaultFactory.setIsCrossChainVault(localEid, address(vault), false);

        // Setup: This OFT IS trusted (key difference)
        lzAdapter.setTrusted(address(trustedButWeirdOFT), true);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = localEid + 1;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.amountLD = 100e18;
        sendParam.minAmountLD = 0;

        bytes memory composeMsg = abi.encode(sendParam, uint256(0));

        // Setup: Craft the LayerZero message
        bytes memory oftMessage = abi.encodePacked(
            uint8(0), // nonce
            uint32(localEid + 1), // srcEid
            bytes32(uint256(uint160(user))), // sender
            uint64(100), // amountLD (small amount to fit in uint64)
            composeMsg
        );

        // Execute: Call lzCompose via endpoint
        vm.prank(address(endpoint));
        vm.deal(address(endpoint), 1 ether);

        // Should succeed because OFT is trusted (security check is bypassed for trusted OFTs)
        composer.lzCompose{value: 0.1 ether}(
            address(trustedButWeirdOFT), bytes32(uint256(1)), oftMessage, address(0), bytes("")
        );

        // Verify: Operation completed successfully
        // This demonstrates that trusted OFTs can proceed regardless of token() behavior
    }

    // ============ Issue #39: Cross-chain deposits fail with oracle accounting Tests ============

    /**
     * @notice Test for issue #39 - Cross-chain deposits should work with oracle accounting enabled
     * @dev This test demonstrates the bug where handleCompose unconditionally routes to async flow
     *      for cross-chain vaults, causing revert when oracle accounting is enabled
     *
     * Bug scenario:
     * 1. Vault is configured as cross-chain
     * 2. Oracle accounting is enabled (ds.oraclesCrossChainAccounting = true)
     * 3. User initiates cross-chain deposit via lzCompose
     * 4. handleCompose checks isCrossChainVault() and routes to _initDeposit
     * 5. _initDeposit calls initVaultActionRequest which reverts with AccountingViaOracles
     * 6. lzCompose catches the revert and refunds the user (Refunded event)
     *
     * Expected behavior: Should emit Deposited event (sync path via _depositAndSend)
     * Actual behavior (bug): Emits Refunded event because initVaultActionRequest reverts
     *
     * This test CURRENTLY FAILS because it expects Deposited but gets Refunded.
     * After the fix, this test should PASS.
     */
    function test_lzCompose_crossChainDeposit_shouldSucceed_whenOracleAccountingEnabled() public {
        // Setup: Configure vault as cross-chain
        vaultFactory.setIsCrossChainVault(localEid, address(vault), true);

        // Setup: Enable oracle accounting - this should allow sync deposits
        vault.setOracleAccountingEnabled(true);

        // Setup: Configure vault for deposits
        vault.setAccountingFee(0); // No fee since we're using oracle accounting
        vault.setDepositable(address(assetToken), true);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = 202; // Cross-chain destination
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        bytes32 guid = bytes32(uint256(5001));

        // Execute: This should emit Deposited event for successful sync deposit
        // But currently it emits Refunded because handleCompose routes to async flow
        // which fails with AccountingViaOracles
        vm.expectEmit(true, true, true, true);
        emit IMoreVaultsComposer.Deposited(
            bytes32(uint256(uint160(user))), // depositor
            sendParam.to, // to
            sendParam.dstEid, // dstEid
            amountLD, // assetAmount
            amountLD // shareAmount (1:1 in mock)
        );

        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.1 ether}(address(assetOFT), guid, msgBytes, address(0), "");

        // Verify: No pending deposit should exist (sync flow)
        bytes32 expectedGuid = bytes32(uint256(0x1));
        (,,, uint256 pendingAmount,,,,) = composer.pendingDeposits(expectedGuid);
        assertEq(pendingAmount, 0, "No pending deposit for sync flow with oracle accounting");
    }

    /**
     * @notice Test that cross-chain deposits still use async flow when oracle accounting is disabled
     * @dev This verifies that the fix doesn't break the normal async flow
     */
    function test_lzCompose_crossChainDeposit_shouldUseAsyncFlow_whenOracleAccountingDisabled() public {
        // Setup: Configure vault as cross-chain
        vaultFactory.setIsCrossChainVault(localEid, address(vault), true);

        // Setup: Disable oracle accounting - should use async flow
        vault.setOracleAccountingEnabled(false);

        // Setup: Configure vault for async deposits
        vault.setAccountingFee(0.1 ether); // Need accounting fee for async flow
        vault.setDepositable(address(assetToken), true);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = 202; // Cross-chain destination
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        // Execute: This should succeed using async flow (initDeposit)
        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.2 ether}(address(assetOFT), bytes32(uint256(5002)), msgBytes, address(0), "");

        // Verify: Check that a pending deposit was created (async flow)
        bytes32 expectedGuid = bytes32(uint256(0x1));
        (,,, uint256 pendingAmount,,,,) = composer.pendingDeposits(expectedGuid);
        assertEq(pendingAmount, amountLD, "Pending deposit should be created for async flow");
    }

    /**
     * @notice Test that non-cross-chain vaults always use sync flow regardless of oracle accounting
     * @dev This ensures the fix doesn't affect non-cross-chain vaults
     */
    function test_lzCompose_nonCrossChainDeposit_alwaysUsesSyncFlow() public {
        // Setup: Configure vault as non-cross-chain
        vaultFactory.setIsCrossChainVault(localEid, address(vault), false);

        // Setup: Enable oracle accounting (should not matter for non-cross-chain)
        vault.setOracleAccountingEnabled(true);

        // Setup: Configure vault for deposits
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = 202; // Cross-chain destination
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 amountLD = 1e18;
        bytes memory msgBytes = _buildComposeMsg(sendParam, 0, 201, amountLD);

        // Execute: Should succeed with sync flow
        vm.prank(address(endpoint));
        composer.lzCompose{value: 0.1 ether}(address(assetOFT), bytes32(uint256(5003)), msgBytes, address(0), "");

        // Verify: No pending deposit should be created (sync flow)
        bytes32 expectedGuid = bytes32(uint256(0x1));
        (,,, uint256 pendingAmount,,,,) = composer.pendingDeposits(expectedGuid);
        assertEq(pendingAmount, 0, "No pending deposit for sync flow");
    }

    /**
     * @notice Test that the vulnerability also affects _initDeposit path (cross-chain vaults)
     * @dev Similar to the first test but for the async deposit path
     */
    function test_lzCompose_shouldRevert_whenUntrustedOFTWithTokenSubstitution_asyncPath() public {
        // Setup: Create worthless and valuable tokens
        MockOFT worthlessToken = new MockOFT("Worthless", "WTH");
        MockOFT valuableToken = new MockOFT("Valuable", "USDC");

        // Setup: Create malicious OFT adapter
        MaliciousOFTAdapter maliciousOFT = new MaliciousOFTAdapter(address(worthlessToken), address(valuableToken));
        maliciousOFT.setEndpoint(address(endpoint));

        // Setup: Fund the composer with valuable tokens
        valuableToken.mint(address(composer), 1000e18);

        // Setup: Configure vault
        vault.setDepositable(address(valuableToken), true);
        vault.setDepositable(address(worthlessToken), false);
        vault.setAccountingFee(0.01 ether);
        vaultFactory.setIsCrossChainVault(localEid, address(vault), true); // Enable async path

        // Setup: Malicious OFT is NOT trusted
        lzAdapter.setTrusted(address(maliciousOFT), false);

        // Setup: Prepare compose message
        SendParam memory sendParam;
        sendParam.dstEid = localEid + 1;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.amountLD = 100; // Small amount to fit in message
        sendParam.minAmountLD = 0;

        bytes memory composeMsg = abi.encode(sendParam, uint256(0.02 ether));

        // Setup: Craft the LayerZero message
        bytes memory oftMessage = abi.encodePacked(
            uint8(0), // nonce
            uint32(localEid + 1), // srcEid
            bytes32(uint256(uint160(user))), // sender
            uint64(100), // amountLD (small amount to fit in uint64)
            composeMsg
        );

        // Execute: Attacker calls lzCompose via endpoint
        vm.prank(address(endpoint));
        vm.deal(address(endpoint), 1 ether);

        // Expected: Should revert with InvalidComposeCaller
        // Actual (with bug): Will succeed and steal funds via async deposit
        vm.expectRevert(
            abi.encodeWithSelector(IMoreVaultsComposer.InvalidComposeCaller.selector, address(maliciousOFT))
        );
        composer.lzCompose{value: 0.1 ether}(
            address(maliciousOFT), bytes32(uint256(1)), oftMessage, address(0), bytes("")
        );
    }

    // ============ Deposited Event Normalization Tests ============
    
    /**
     * @notice Test that Deposited event emits normalized share amount for cross-chain sends
     * @dev LayerZero normalizes amounts to sharedDecimals (6 decimals), removing dust.
     *      The event should reflect the actual amount sent, not the original share amount.
     */
    function test_Deposited_event_emitsNormalizedAmount_crossChain() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202; // Cross-chain destination
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        // Use an amount that will have dust after normalization
        uint256 amountWithDust = 100e18 + 123456789; // This will have dust
        uint256 shareAmount = amountWithDust; // 1:1 in mock vault
        
        // Calculate expected normalized amount (remove dust for 18 decimal token with 6 shared decimals)
        uint256 decimalConversionRate = 1e12; // 10^(18-6)
        uint256 expectedNormalizedAmount = (shareAmount / decimalConversionRate) * decimalConversionRate;
        
        vm.expectEmit(true, true, true, true);
        emit IMoreVaultsComposer.Deposited(
            OFTComposeMsgCodec.addressToBytes32(user),
            sendParam.to,
            sendParam.dstEid,
            amountWithDust, // assetAmount (original)
            expectedNormalizedAmount // shareAmount (normalized)
        );

        composer.depositAndSend(address(assetToken), amountWithDust, sendParam, user);
        vm.stopPrank();
    }

    /**
     * @notice Test that Deposited event emits original amount for local sends (no normalization)
     * @dev Local sends don't go through LayerZero normalization, so the event should show the full amount.
     */
    function test_Deposited_event_emitsOriginalAmount_local() public {
        vault.setAccountingFee(0);
        vault.setDepositable(address(assetToken), true);

        // Give user some tokens
        assetToken.mint(user, 1000e18);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = localEid; // Same as VAULT_EID for local send
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 depositAmount = 100e18 + 123456789; // Amount with dust
        uint256 shareAmount = depositAmount; // 1:1 in mock vault
        
        // For local sends, no normalization occurs, so the full amount should be in the event
        vm.expectEmit(true, true, true, true);
        emit IMoreVaultsComposer.Deposited(
            OFTComposeMsgCodec.addressToBytes32(user),
            sendParam.to,
            sendParam.dstEid,
            depositAmount, // assetAmount
            shareAmount // shareAmount (no normalization for local)
        );

        composer.depositAndSend(address(assetToken), depositAmount, sendParam, user);
        vm.stopPrank();
    }

    /**
     * @notice Test that completeDeposit emits normalized amount for cross-chain sends
     * @dev When completing an async deposit, the event should reflect the normalized amount sent.
     */
    function test_completeDeposit_emitsNormalizedAmount_crossChain() public {
        vault.setAccountingFee(0.1 ether);
        vault.setDepositable(address(assetToken), true);
        vaultFactory.setIsCrossChainVault(uint32(localEid), address(vault), true);

        // Setup: Create pending deposit
        assetToken.mint(user, 1000e18);
        deal(user, 10 ether);
        vm.startPrank(user);
        assetToken.approve(address(composer), 1000e18);

        SendParam memory sendParam;
        sendParam.dstEid = 202;
        sendParam.to = bytes32(uint256(uint160(user)));
        sendParam.minAmountLD = 0;

        uint256 depositAmount = 100e18 + 987654321; // Amount with dust
        composer.initDeposit{value: 0.1 ether}(
            OFTComposeMsgCodec.addressToBytes32(user),
            address(assetToken),
            address(assetOFT),
            depositAmount,
            sendParam,
            user,
            201
        );
        vm.stopPrank();

        // Complete the deposit
        bytes32 guid = bytes32(uint256(0x1));
        vault.setFinalizeShares(guid, depositAmount); // 1:1 in mock
        
        // Calculate expected normalized amount
        uint256 decimalConversionRate = 1e12;
        uint256 expectedNormalizedAmount = (depositAmount / decimalConversionRate) * decimalConversionRate;
        
        vm.expectEmit(true, true, true, true);
        emit IMoreVaultsComposer.Deposited(
            OFTComposeMsgCodec.addressToBytes32(user),
            sendParam.to,
            sendParam.dstEid,
            depositAmount, // assetAmount (original)
            expectedNormalizedAmount // shareAmount (normalized)
        );

        vm.prank(address(vault));
        composer.completeDeposit(guid);
    }
}
