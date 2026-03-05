// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

// Core contracts
import {VaultsFactory} from "../../src/factory/VaultsFactory.sol";
import {OFTAdapterFactory} from "../../src/factory/OFTAdapterFactory.sol";
import {MoreVaultsEscrow} from "../../src/cross-chain/MoreVaultsEscrow.sol";
import {MoreVaultsComposer} from "../../src/cross-chain/layerZero/MoreVaultsComposer.sol";

// Facets
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {BridgeFacet} from "../../src/facets/BridgeFacet.sol";
import {ConfigurationFacet} from "../../src/facets/ConfigurationFacet.sol";
import {AccessControlFacet} from "../../src/facets/AccessControlFacet.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";

// Interfaces
import {IDiamondCut} from "../../src/interfaces/facets/IDiamondCut.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";
import {IAccessControlFacet} from "../../src/interfaces/facets/IAccessControlFacet.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

// LayerZero
import {
    SendParam,
    MessagingFee,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

// Mocks
import {MockEndpointV2} from "../mocks/MockEndpointV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOFT} from "../mocks/MockOFT.sol";
import {MockOFTAdapter} from "../mocks/MockOFTAdapter.sol";
import {MockOracleRegistry} from "../mocks/MockOracleRegistry.sol";
import {MockMoreVaultsRegistry} from "../mocks/MockMoreVaultsRegistry.sol";
import {MockMoreVaultsEscrow} from "../mocks/MockMoreVaultsEscrow.sol";
import {VaultsFactoryHarness} from "../mocks/VaultsFactoryHarness.sol";

/// @title BaseE2ETest
/// @notice Shared base contract for all E2E test files. Deploys a complete Hub+Spoke
///         system using mocked LayerZero endpoints on a single Foundry chain.
contract BaseE2ETest is Test {
    // ── Chain simulation EIDs ─────────────────────────────────────────
    uint32 public constant HUB_EID = 30332; // Flow EVM
    uint32 public constant SPOKE_EID = 30110; // Arbitrum

    // ── Roles ─────────────────────────────────────────────────────────
    address public owner = address(0xA11CE);
    address public curator = address(0xC0FFEE);
    address public guardian = address(0xBEEF);
    address public feeRecipient = address(0xFEE);
    address public user1 = address(0x1001);
    address public user2 = address(0x1002);

    // ── Endpoints ─────────────────────────────────────────────────────
    MockEndpointV2 public hubEndpoint;
    MockEndpointV2 public spokeEndpoint;

    // ── Factories ─────────────────────────────────────────────────────
    VaultsFactoryHarness public hubFactory;
    VaultsFactoryHarness public spokeFactory;

    // ── Tokens ────────────────────────────────────────────────────────
    MockERC20 public underlying; // USDC-like (18 decimals in MockERC20)
    MockERC20 public weth; // WETH
    MockOFT public usdcOFT; // OFT for bridging USDC
    MockOFT public wethOFT; // OFT for WETH

    // ── Vaults ────────────────────────────────────────────────────────
    address public hubVault;
    address public spokeVault;

    // ── Share OFT (deployed by factory) ───────────────────────────────
    address public shareOFT;

    // ── Cross-chain infrastructure ────────────────────────────────────
    MockMoreVaultsEscrow public escrow;
    MockOracleRegistry public oracleRegistry;
    MockMoreVaultsRegistry public hubRegistry;
    MockMoreVaultsRegistry public spokeRegistry;

    // ── Facet instances (shared between hub and spoke deployments) ────
    DiamondCutFacet internal _diamondCutFacet;
    AccessControlFacet internal _accessControlFacet;
    VaultFacet internal _vaultFacet;
    BridgeFacet internal _bridgeFacet;
    ConfigurationFacet internal _configurationFacet;

    // ── Composer (deployed by factory alongside hub vault) ────────────
    address public hubComposer;

    // ── OFT Adapter Factory ──────────────────────────────────────────
    OFTAdapterFactory internal _hubOftAdapterFactory;
    OFTAdapterFactory internal _spokeOftAdapterFactory;

    // ── Vault identifier (same for hub + spoke to get same CREATE3 address)
    bytes32 internal _vaultIdentifier = keccak256("E2E_VAULT_V1");

    // ── Constants ─────────────────────────────────────────────────────
    uint96 internal constant MAX_FINALIZATION_TIME = 0; // no delay for tests
    uint96 internal constant VAULT_FEE = 0; // 0% fee for simplicity
    uint256 internal constant DEPOSIT_CAPACITY = type(uint256).max;
    uint256 internal constant MAX_SLIPPAGE_PERCENT = 500; // 5%

    // ════════════════════════════════════════════════════════════════════
    //  SETUP
    // ════════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        vm.warp(block.timestamp + 1 days); // advance past zero timestamp

        _deployEndpoints();
        _deployFacets();
        _deployTokens();
        _deployRegistries();
        _deployFactories();
        _deployVaults();
        _configureVaults();
    }

    // ── Step 1: Endpoints ─────────────────────────────────────────────
    function _deployEndpoints() internal {
        hubEndpoint = new MockEndpointV2(HUB_EID);
        spokeEndpoint = new MockEndpointV2(SPOKE_EID);
    }

    // ── Step 2: Facets (singleton instances, reused across vaults) ────
    function _deployFacets() internal {
        _diamondCutFacet = new DiamondCutFacet();
        _accessControlFacet = new AccessControlFacet();
        _vaultFacet = new VaultFacet();
        _bridgeFacet = new BridgeFacet();
        _configurationFacet = new ConfigurationFacet();
    }

    // ── Step 3: Tokens ────────────────────────────────────────────────
    function _deployTokens() internal {
        underlying = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
        usdcOFT = new MockOFT("USDC OFT", "oUSDC");
        usdcOFT.setUnderlyingToken(address(underlying));
        wethOFT = new MockOFT("WETH OFT", "oWETH");
        wethOFT.setUnderlyingToken(address(weth));
    }

    // ── Step 4: Registries ────────────────────────────────────────────
    function _deployRegistries() internal {
        oracleRegistry = new MockOracleRegistry();
        oracleRegistry.setAssetPrice(address(underlying), 1e8); // $1
        oracleRegistry.setAssetPrice(address(weth), 2000e8); // $2000

        hubRegistry = new MockMoreVaultsRegistry();
        hubRegistry.setOracle(address(oracleRegistry));

        spokeRegistry = new MockMoreVaultsRegistry();
        spokeRegistry.setOracle(address(oracleRegistry));
    }

    // ── Step 5: Factories ─────────────────────────────────────────────
    function _deployFactories() internal {
        // Deploy composer implementation (needed by factory)
        MoreVaultsComposer composerImpl = new MoreVaultsComposer();

        // Hub OFT adapter factory
        _hubOftAdapterFactory = new OFTAdapterFactory(address(hubEndpoint), owner);

        // Hub factory
        hubFactory = new VaultsFactoryHarness(address(hubEndpoint));
        hubFactory.initialize(
            owner,
            address(hubRegistry),
            address(_diamondCutFacet),
            address(_accessControlFacet),
            address(weth), // wrappedNative
            HUB_EID,
            MAX_FINALIZATION_TIME,
            address(0x1), // lzAdapter placeholder (set later)
            address(composerImpl),
            address(_hubOftAdapterFactory)
        );

        // Spoke OFT adapter factory
        _spokeOftAdapterFactory = new OFTAdapterFactory(address(spokeEndpoint), owner);

        // Spoke factory
        spokeFactory = new VaultsFactoryHarness(address(spokeEndpoint));
        spokeFactory.initialize(
            owner,
            address(spokeRegistry),
            address(_diamondCutFacet),
            address(_accessControlFacet),
            address(weth), // wrappedNative
            SPOKE_EID,
            MAX_FINALIZATION_TIME,
            address(0x1), // lzAdapter placeholder
            address(composerImpl),
            address(_spokeOftAdapterFactory)
        );
    }

    // ── Step 6: Vault deployment ──────────────────────────────────────
    function _deployVaults() internal {
        // Build facet cuts for VaultFacet + BridgeFacet + ConfigurationFacet
        IDiamondCut.FacetCut[] memory hubCuts = _buildFacetCuts();
        IDiamondCut.FacetCut[] memory spokeCuts = _buildFacetCuts();

        // AccessControlFacet init data: (owner, curator, guardian)
        bytes memory acInitData = abi.encode(owner, curator, guardian);

        // Deploy hub vault
        vm.prank(owner);
        hubVault = hubFactory.deployVault(hubCuts, acInitData, true, _vaultIdentifier);

        // Deploy spoke vault
        vm.prank(owner);
        spokeVault = spokeFactory.deployVault(spokeCuts, acInitData, false, _vaultIdentifier);

        // Note: In production the same factory address is on both chains (same CREATE3 deployer)
        // so addresses match. In this single-chain test they differ, which is fine.

        // Record share OFT (deployed by factory alongside vault)
        shareOFT = _hubOftAdapterFactory.getAdapter(hubVault);
        require(shareOFT != address(0), "Share OFT not deployed");

        // Record composer
        hubComposer = hubFactory.vaultComposer(hubVault);
        require(hubComposer != address(0), "Composer not deployed");

        // Deploy escrow using hub factory
        escrow = new MockMoreVaultsEscrow();
        escrow.setUnderlyingToken(hubVault, address(underlying));

        // Set escrow on registry
        hubRegistry.setEscrow(address(escrow));
        spokeRegistry.setEscrow(address(escrow));
    }

    // ── Step 7: Post-deploy configuration ─────────────────────────────
    function _configureVaults() internal {
        // Mock calls for the vault interactions that query the registry
        _setupRegistryMocks();
    }

    // ════════════════════════════════════════════════════════════════════
    //  SETUP MODES (call from individual tests)
    // ════════════════════════════════════════════════════════════════════

    /// @notice Register spoke vault on hub factory
    /// @dev Since hub and spoke factories have different addresses, CREATE3 produces
    ///      different vault addresses. The real lzReceive checks hubVault == spokeVault,
    ///      so we mock the factory responses instead.
    function _registerSpoke() internal {
        // Mock isCrossChainVault to return true
        vm.mockCall(
            address(hubFactory),
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, HUB_EID, hubVault),
            abi.encode(true)
        );

        // Mock hubToSpokes to return the spoke vault on SPOKE_EID
        uint32[] memory eids = new uint32[](1);
        eids[0] = SPOKE_EID;
        address[] memory vaults = new address[](1);
        vaults[0] = spokeVault;
        vm.mockCall(
            address(hubFactory),
            abi.encodeWithSelector(IVaultsFactory.hubToSpokes.selector, HUB_EID, hubVault),
            abi.encode(eids, vaults)
        );

        // Mock isSpokeOfHub
        vm.mockCall(
            address(hubFactory),
            abi.encodeWithSelector(IVaultsFactory.isSpokeOfHub.selector, HUB_EID, hubVault, SPOKE_EID, spokeVault),
            abi.encode(true)
        );
    }

    /// @notice Enable oracle-based cross-chain accounting
    function _enableOracleAccounting() internal {
        // Must register spoke first and set oracle info
        oracleRegistry.setSpokeValue(hubVault, SPOKE_EID, 500e8); // $500 in spoke

        // Set spoke oracle info so setOraclesCrossChainAccounting doesn't revert
        IOracleRegistry.OracleInfo memory info = IOracleRegistry.OracleInfo({
            aggregator: IAggregatorV2V3Interface(address(0x1111)),
            stalenessThreshold: uint96(1)
        });
        oracleRegistry.setSpokeOracleInfo(hubVault, SPOKE_EID, info);

        vm.prank(owner);
        IBridgeFacet(hubVault).setOraclesCrossChainAccounting(true);
    }

    /// @notice Enable withdrawal queue with optional timelock
    function _enableWithdrawalQueue(uint256 timelock) internal {
        vm.prank(hubVault);
        IConfigurationFacet(hubVault).updateWithdrawalQueueStatus(true);
        if (timelock > 0) {
            vm.prank(hubVault);
            IConfigurationFacet(hubVault).setWithdrawalTimelock(uint64(timelock));
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPER: Simulate LZ Read response arriving at hub
    // ════════════════════════════════════════════════════════════════════

    function _simulateLzReadResponse(bytes32 guid, uint256 spokeUsdValue, bool success) internal {
        // The LzAdapter._lzReceive decodes the result and calls
        // BridgeFacet.updateAccountingInfoForRequest + executeRequest
        // For e2e tests we directly call the BridgeFacet since we don't have a real LzAdapter
        address ccManager = IConfigurationFacet(hubVault).getCrossChainAccountingManager();
        vm.prank(ccManager);
        IBridgeFacet(hubVault).updateAccountingInfoForRequest(guid, spokeUsdValue, success);
        if (success) {
            vm.prank(ccManager);
            IBridgeFacet(hubVault).executeRequest(guid);
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPER: Simulate OFT compose arriving at hub composer
    // ════════════════════════════════════════════════════════════════════

    function _simulateOFTComposeAtHub(
        address oft,
        address composer,
        uint256 amount,
        address user,
        uint32 srcEid,
        SendParam memory hopSendParam,
        uint256 minMsgValue,
        uint256 msgValue
    ) internal returns (bytes32 guid) {
        guid = keccak256(abi.encode(oft, composer, amount, user, srcEid, block.timestamp));

        // 1. Mint underlying tokens to composer (simulating OFT delivery which credits underlying)
        address underlyingToken = MockOFT(oft).token();
        MockERC20(underlyingToken).mint(composer, amount);

        // 2. Build compose message using OFTComposeMsgCodec format
        bytes memory composePayload = abi.encode(hopSendParam, minMsgValue);
        bytes memory composeMsg = bytes.concat(
            bytes8(uint64(1)), // nonce
            bytes4(srcEid), // srcEid
            bytes32(amount), // amountLD
            bytes32(uint256(uint160(user))), // composeFrom (original sender)
            composePayload
        );

        // 3. Call lzCompose via endpoint prank
        vm.prank(address(hubEndpoint));
        (bool success,) = composer.call{value: msgValue}(
            abi.encodeWithSignature(
                "lzCompose(address,bytes32,bytes,address,bytes)",
                oft,
                guid,
                composeMsg,
                address(0), // executor
                "" // extraData
            )
        );
        require(success, "lzCompose call failed");
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPER: Give user tokens and approve vault/escrow
    // ════════════════════════════════════════════════════════════════════

    function _giveTokensAndApprove(address user, uint256 amount) internal {
        underlying.mint(user, amount);
        vm.prank(user);
        underlying.approve(hubVault, amount);
        vm.prank(user);
        underlying.approve(address(escrow), amount);
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPER: Give user shares (deposit into hub vault)
    // ════════════════════════════════════════════════════════════════════

    function _giveShares(address user, uint256 assets) internal returns (uint256 shares) {
        _giveTokensAndApprove(user, assets);
        vm.prank(user);
        shares = IVaultFacet(hubVault).deposit(assets, user);
    }

    // ════════════════════════════════════════════════════════════════════
    //  INTERNAL: Build facet cuts for vault deployment
    // ════════════════════════════════════════════════════════════════════

    function _buildFacetCuts() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);

        // ── VaultFacet ──
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(_vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _getVaultFacetSelectors(),
            initData: abi.encode(
                "E2E Vault", // name
                "E2EV", // symbol
                address(underlying), // asset
                feeRecipient, // feeRecipient
                VAULT_FEE, // fee
                DEPOSIT_CAPACITY // depositCapacity
            )
        });

        // ── BridgeFacet ──
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(_bridgeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _getBridgeFacetSelectors(),
            initData: "" // BridgeFacet.initialize takes no data
        });

        // ── ConfigurationFacet ──
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(_configurationFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _getConfigurationFacetSelectors(),
            initData: abi.encode(MAX_SLIPPAGE_PERCENT) // maxSlippagePercent
        });
    }

    // ── VaultFacet selectors ──────────────────────────────────────────
    function _getVaultFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](31);
        s[0] = IVaultFacet.pause.selector;
        s[1] = IVaultFacet.unpause.selector;
        s[2] = IVaultFacet.paused.selector;
        s[3] = IVaultFacet.totalAssets.selector;
        s[4] = IVaultFacet.totalAssetsUsd.selector;
        s[5] = IVaultFacet.getWithdrawalRequest.selector;
        s[6] = bytes4(keccak256("deposit(address[],uint256[],address,uint256)")); // multi-asset deposit
        s[7] = IERC4626.deposit.selector; // deposit(uint256,address)
        s[8] = IERC4626.mint.selector;
        s[9] = IERC4626.withdraw.selector;
        s[10] = IERC4626.redeem.selector;
        s[11] = IVaultFacet.setFee.selector;
        s[12] = IVaultFacet.requestRedeem.selector;
        s[13] = IVaultFacet.requestWithdraw.selector;
        s[14] = IVaultFacet.clearRequest.selector;
        s[15] = IVaultFacet.accrueFees.selector;
        // ERC4626 view functions
        s[16] = IERC4626.asset.selector;
        s[17] = IERC20.totalSupply.selector;
        s[18] = IERC20.balanceOf.selector;
        s[19] = IERC4626.convertToShares.selector;
        s[20] = IERC4626.convertToAssets.selector;
        s[21] = IERC4626.maxDeposit.selector;
        s[22] = IERC4626.previewDeposit.selector;
        s[23] = IERC4626.maxRedeem.selector;
        // ERC20 functions needed by OFTAdapter and token transfers
        s[24] = IERC20Metadata.decimals.selector;
        s[25] = IERC20Metadata.name.selector;
        s[26] = IERC20Metadata.symbol.selector;
        s[27] = IERC20.approve.selector;
        s[28] = IERC20.transfer.selector;
        s[29] = IERC20.transferFrom.selector;
        s[30] = IERC20.allowance.selector;
    }

    // ── BridgeFacet selectors ─────────────────────────────────────────
    function _getBridgeFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = IBridgeFacet.accountingBridgeFacet.selector;
        s[1] = IBridgeFacet.setOraclesCrossChainAccounting.selector;
        s[2] = IBridgeFacet.oraclesCrossChainAccounting.selector;
        s[3] = IBridgeFacet.quoteAccountingFee.selector;
        s[4] = IBridgeFacet.executeBridging.selector;
        s[5] = IBridgeFacet.initVaultActionRequest.selector;
        s[6] = IBridgeFacet.updateAccountingInfoForRequest.selector;
        s[7] = IBridgeFacet.executeRequest.selector;
        s[8] = IBridgeFacet.refundRequestTokens.selector;
        s[9] = IBridgeFacet.getRequestInfo.selector;
        s[10] = IBridgeFacet.getFinalizationResult.selector;
    }

    // ── ConfigurationFacet selectors ──────────────────────────────────
    function _getConfigurationFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](26);
        s[0] = IConfigurationFacet.setFeeRecipient.selector;
        s[1] = IConfigurationFacet.setTimeLockPeriod.selector;
        s[2] = IConfigurationFacet.setDepositCapacity.selector;
        s[3] = IConfigurationFacet.setDepositWhitelist.selector;
        s[4] = IConfigurationFacet.enableDepositWhitelist.selector;
        s[5] = IConfigurationFacet.disableDepositWhitelist.selector;
        s[6] = IConfigurationFacet.getAvailableToDeposit.selector;
        s[7] = IConfigurationFacet.addAvailableAsset.selector;
        s[8] = IConfigurationFacet.addAvailableAssets.selector;
        s[9] = IConfigurationFacet.enableAssetToDeposit.selector;
        s[10] = IConfigurationFacet.disableAssetToDeposit.selector;
        s[11] = IConfigurationFacet.setWithdrawalFee.selector;
        s[12] = IConfigurationFacet.setWithdrawalTimelock.selector;
        s[13] = IConfigurationFacet.updateWithdrawalQueueStatus.selector;
        s[14] = IConfigurationFacet.setMaxWithdrawalDelay.selector;
        s[15] = IConfigurationFacet.setGasLimitForAccounting.selector;
        s[16] = IConfigurationFacet.setMaxSlippagePercent.selector;
        s[17] = IConfigurationFacet.setCrossChainAccountingManager.selector;
        s[18] = IConfigurationFacet.getEscrow.selector;
        s[19] = IConfigurationFacet.getWithdrawalFee.selector;
        s[20] = IConfigurationFacet.getWithdrawalQueueStatus.selector;
        s[21] = IConfigurationFacet.getMaxWithdrawalDelay.selector;
        s[22] = IConfigurationFacet.isAssetDepositable.selector;
        s[23] = IConfigurationFacet.isAssetAvailable.selector;
        s[24] = IConfigurationFacet.isHub.selector;
        s[25] = IConfigurationFacet.getCrossChainAccountingManager.selector;
    }

    // ════════════════════════════════════════════════════════════════════
    //  INTERNAL: Setup mock calls for registry
    // ════════════════════════════════════════════════════════════════════

    function _setupRegistryMocks() internal {
        // Hub vault queries the registry for oracle, escrow, etc.
        // These are on the MockMoreVaultsRegistry, but some functions
        // are called directly by the Diamond via delegatecall on facets.
        // We mock the calls that the vault will make to the registry.

        // Mock isCrossChainVault to return false by default (no spokes registered)
        vm.mockCall(
            address(hubFactory),
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector, HUB_EID, hubVault),
            abi.encode(false)
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //  ORACLE INTERFACE (imported for _enableOracleAccounting)
    // ════════════════════════════════════════════════════════════════════
}

// Re-export IOracleRegistry types needed by _enableOracleAccounting
import {IOracleRegistry} from "../../src/interfaces/IOracleRegistry.sol";
import {IAggregatorV2V3Interface} from "../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";
