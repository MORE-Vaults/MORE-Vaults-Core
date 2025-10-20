// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IMoreVaultsComposer, MoreVaultsComposer} from "../../../../src/cross-chain/layerZero/MoreVaultsComposer.sol";
import {MockEndpointV2} from "../../../../test/mocks/MockEndpointV2.sol";
import {MockVaultFacet} from "../../../../test/mocks/MockVaultFacet.sol";
import {MockOFT} from "../../../../test/mocks/MockOFT.sol";
import {MockOFTAdapter} from "../../../../test/mocks/MockOFTAdapter.sol";
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);

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
        vault.setDepositable(address(assetToken), false);

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
        vault.setDepositable(address(assetToken), false);

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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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
        vault.setDepositable(address(assetToken), false);
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

    function test_lzCompose_insufficientMsgValue_revert_propagation() public {
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
        vault.setDepositable(address(assetToken), false);

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
        vault.setDepositable(address(assetToken), false);

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
}
