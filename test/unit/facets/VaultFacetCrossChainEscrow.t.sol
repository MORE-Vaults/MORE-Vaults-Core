// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {BridgeFacet} from "../../../src/facets/BridgeFacet.sol";
import {ConfigurationFacet} from "../../../src/facets/ConfigurationFacet.sol";
import {MoreVaultsDiamond} from "../../../src/MoreVaultsDiamond.sol";
import {DiamondCutFacet} from "../../../src/facets/DiamondCutFacet.sol";
import {AccessControlFacet} from "../../../src/facets/AccessControlFacet.sol";
import {IDiamondCut} from "../../../src/interfaces/facets/IDiamondCut.sol";
import {IBridgeFacet} from "../../../src/interfaces/facets/IBridgeFacet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockVaultsFactory} from "../../mocks/MockVaultsFactory.sol";
import {MockMoreVaultsRegistry} from "../../mocks/MockMoreVaultsRegistry.sol";
import {MockOracleRegistry} from "../../mocks/MockOracleRegistry.sol";
import {MockBridgeAdapter} from "../../mocks/MockBridgeAdapter.sol";
import {MockMoreVaultsComposer} from "../../mocks/MockMoreVaultsComposer.sol";
import {MockMoreVaultsEscrow} from "../../mocks/MockMoreVaultsEscrow.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {MoreVaultsLib} from "../../../src/libraries/MoreVaultsLib.sol";
import {IAccessControlFacet} from "../../../src/interfaces/facets/IAccessControlFacet.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";

/**
 * @title VaultFacetCrossChainEscrowTest
 * @notice Integration tests for VaultFacet cross-chain flow: deposit transfers from escrow, withdraw/redeem burn from escrow
 */
contract VaultFacetCrossChainEscrowTest is Test {
    address public vault;
    VaultFacet public vaultFacet;
    BridgeFacet public bridgeFacet;
    ConfigurationFacet public configurationFacet;
    MockERC20 public underlying;
    MockVaultsFactory public factory;
    MockMoreVaultsRegistry public registry;
    MockOracleRegistry public oracle;
    MockBridgeAdapter public adapter;
    MockMoreVaultsComposer public composer;
    MockMoreVaultsEscrow public escrow;

    address public owner = address(1);
    address public curator = address(2);
    address public feeRecipient = address(4);
    address public user = address(0x1111);
    address public receiver = address(0x2222);

    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant INITIAL_VAULT_ASSETS = 200 ether;

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        // Deploy tokens and mocks
        underlying = new MockERC20("Underlying", "UND");
        underlying.mint(user, 1000 ether);

        factory = new MockVaultsFactory();
        registry = new MockMoreVaultsRegistry();
        oracle = new MockOracleRegistry();
        adapter = new MockBridgeAdapter();
        composer = new MockMoreVaultsComposer();

        escrow = new MockMoreVaultsEscrow();

        // Deploy facets
        DiamondCutFacet diamondCutFacet = new DiamondCutFacet();
        AccessControlFacet accessControlFacet = new AccessControlFacet();
        vaultFacet = new VaultFacet();
        bridgeFacet = new BridgeFacet();
        configurationFacet = new ConfigurationFacet();

        // Deploy diamond
        registry.setOracle(address(oracle));
        registry.setEscrow(address(escrow));
        oracle.setAssetPrice(address(underlying), 1e8);

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isPermissionless.selector),
            abi.encode(false)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(diamondCutFacet)),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, IDiamondCut.diamondCut.selector),
            abi.encode(address(diamondCutFacet))
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(accessControlFacet)),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                IAccessControlFacet.moreVaultsRegistry.selector
            ),
            abi.encode(address(accessControlFacet))
        );

        bytes memory accessControlInitData = abi.encode(owner, curator, address(3));
        IDiamondCut.FacetCut[] memory initialCuts = _buildFacetCuts(address(registry));

        vault = address(
            new MoreVaultsDiamond(
                address(diamondCutFacet),
                address(accessControlFacet),
                address(registry),
                address(0),
                address(factory),
                true,
                initialCuts,
                accessControlInitData
            )
        );

        // Configure vault
        MoreVaultsStorageHelper.setCrossChainAccountingManager(vault, address(adapter));
        MoreVaultsStorageHelper.setOraclesCrossChainAccounting(vault, false);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, false);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, user, 10_000_000 ether);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, receiver, 10_000_000 ether);

        uint32[] memory eids = new uint32[](1);
        eids[0] = 101;
        address[] memory spokes = new address[](1);
        spokes[0] = address(0xBEEF01);
        factory.setLocalEid(100);
        factory.setHubToSpokes(100, vault, eids, spokes);
        factory.setVaultComposer(vault, address(composer));

        adapter.setReceiptGuid(keccak256("cross-chain-deposit"));
        adapter.setFee(0, 0);

        // Set underlying token in escrow for this vault
        escrow.setUnderlyingToken(vault, address(underlying));

        // BridgeFacet is initialized via initData in diamondCut

        // Seed vault with initial assets for share calculation
        underlying.mint(vault, INITIAL_VAULT_ASSETS);
    }

    function _buildFacetCuts(address registry_) internal returns (IDiamondCut.FacetCut[] memory) {
        bytes4[] memory vaultSelectors = new bytes4[](12);
        vaultSelectors[0] = VaultFacet.initialize.selector;
        vaultSelectors[1] = IERC4626.deposit.selector;
        vaultSelectors[2] = IERC4626.withdraw.selector;
        vaultSelectors[3] = IERC4626.redeem.selector;
        vaultSelectors[4] = IERC4626.totalAssets.selector;
        vaultSelectors[5] = IERC4626.asset.selector;
        vaultSelectors[6] = IERC4626.previewWithdraw.selector;
        vaultSelectors[7] = IERC4626.previewRedeem.selector;
        vaultSelectors[8] = IERC20.balanceOf.selector;
        vaultSelectors[9] = IERC20.totalSupply.selector;
        vaultSelectors[10] = IERC20.approve.selector;
        vaultSelectors[11] = IERC20.transferFrom.selector;

        bytes4[] memory bridgeSelectors = new bytes4[](4);
        bridgeSelectors[0] = IBridgeFacet.initVaultActionRequest.selector;
        bridgeSelectors[1] = IBridgeFacet.executeRequest.selector;
        bridgeSelectors[2] = IBridgeFacet.updateAccountingInfoForRequest.selector;
        bridgeSelectors[3] = IBridgeFacet.getRequestInfo.selector;

        vm.mockCall(
            registry_,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(vaultFacet)),
            abi.encode(true)
        );
        vm.mockCall(
            registry_,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(bridgeFacet)),
            abi.encode(true)
        );
        vm.mockCall(
            registry_,
            abi.encodeWithSelector(IMoreVaultsRegistry.isFacetAllowed.selector, address(configurationFacet)),
            abi.encode(true)
        );
        for (uint256 i = 0; i < vaultSelectors.length; i++) {
            vm.mockCall(
                registry_,
                abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, vaultSelectors[i]),
                abi.encode(address(vaultFacet))
            );
        }
        for (uint256 i = 0; i < bridgeSelectors.length; i++) {
            vm.mockCall(
                registry_,
                abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, bridgeSelectors[i]),
                abi.encode(address(bridgeFacet))
            );
        }
        vm.mockCall(
            registry_,
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(address(oracle))
        );
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, address(underlying)),
            abi.encode(address(0x1000), uint96(1000))
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(vaultFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: vaultSelectors,
            initData: abi.encode("Test Vault", "TV", address(underlying), feeRecipient, uint96(0), uint256(0))
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(bridgeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: bridgeSelectors,
            initData: ""
        });
        bytes4[] memory configSelectors = new bytes4[](2);
        configSelectors[0] = ConfigurationFacet.getEscrow.selector;
        configSelectors[1] = ConfigurationFacet.getCrossChainAccountingManager.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(configurationFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: configSelectors,
            initData: abi.encode(uint256(0))
        });

        vm.mockCall(
            registry_,
            abi.encodeWithSelector(IMoreVaultsRegistry.selectorToFacet.selector, ConfigurationFacet.getEscrow.selector),
            abi.encode(address(configurationFacet))
        );
        vm.mockCall(
            registry_,
            abi.encodeWithSelector(
                IMoreVaultsRegistry.selectorToFacet.selector,
                ConfigurationFacet.getCrossChainAccountingManager.selector
            ),
            abi.encode(address(configurationFacet))
        );

        return cuts;
    }

    /**
     * @notice Cross-chain DEPOSIT: assets must be transferred FROM escrow to vault (not from user)
     */
    function test_crossChainDeposit_TransfersAssetsFromEscrow() public {
        factory.setIsCrossChainVault(100, vault, true);

        uint256 escrowBalanceBefore = underlying.balanceOf(address(escrow));
        uint256 vaultBalanceBefore = underlying.balanceOf(vault);
        uint256 userBalanceBefore = underlying.balanceOf(user);

        vm.startPrank(user);
        underlying.approve(address(escrow), DEPOSIT_AMOUNT);
        bytes memory callData = abi.encode(DEPOSIT_AMOUNT, receiver);
        bytes32 guid = IBridgeFacet(vault).initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT,
            callData,
            0,
            bytes("")
        );
        vm.stopPrank();

        // Escrow should have received assets from user (lockTokens)
        assertEq(
            underlying.balanceOf(address(escrow)),
            escrowBalanceBefore + DEPOSIT_AMOUNT,
            "Escrow should hold locked assets"
        );
        assertEq(underlying.balanceOf(user), userBalanceBefore - DEPOSIT_AMOUNT, "User should have sent assets");

        vm.prank(address(adapter));
        IBridgeFacet(vault).updateAccountingInfoForRequest(guid, 0, true);

        vm.prank(address(adapter));
        IBridgeFacet(vault).executeRequest(guid);

        // After executeRequest: vault pulls from escrow via transferFrom in _deposit
        assertEq(
            underlying.balanceOf(vault),
            vaultBalanceBefore + DEPOSIT_AMOUNT,
            "Vault should have received assets from escrow"
        );
        assertEq(
            underlying.balanceOf(address(escrow)),
            escrowBalanceBefore,
            "Escrow should have released assets to vault"
        );
        assertGt(IERC20(vault).balanceOf(receiver), 0, "Receiver should have shares");
    }

    /**
     * @notice Cross-chain WITHDRAW: shares must be burned FROM escrow (not from owner)
     */
    function test_crossChainWithdraw_BurnsSharesFromEscrow() public {
        // First do a normal deposit to get shares (ERC4626 mode for direct user calls)
        factory.setIsCrossChainVault(100, vault, false);
        vm.startPrank(user);
        underlying.approve(vault, DEPOSIT_AMOUNT);
        IERC4626(vault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        uint256 userShares = IERC20(vault).balanceOf(user);
        uint256 withdrawAssets = IERC4626(vault).previewRedeem(userShares / 2);
        uint256 sharesToWithdraw = IERC4626(vault).previewWithdraw(withdrawAssets);

        // Now enable cross-chain mode for the withdraw flow
        factory.setIsCrossChainVault(100, vault, true);

        // Lock shares in escrow for cross-chain withdraw
        vm.startPrank(user);
        IERC20(vault).approve(address(escrow), sharesToWithdraw);
        bytes memory callData = abi.encode(withdrawAssets, receiver, user);
        bytes32 guid = IBridgeFacet(vault).initVaultActionRequest(
            MoreVaultsLib.ActionType.WITHDRAW,
            callData,
            sharesToWithdraw,
            bytes("")
        );
        vm.stopPrank();

        uint256 escrowSharesBefore = IERC20(vault).balanceOf(address(escrow));
        assertEq(escrowSharesBefore, sharesToWithdraw, "Escrow should hold locked shares");

        vm.prank(address(adapter));
        IBridgeFacet(vault).updateAccountingInfoForRequest(guid, 0, true);

        uint256 receiverAssetsBefore = underlying.balanceOf(receiver);
        uint256 totalSupplyBefore = IERC20(vault).totalSupply();

        vm.prank(address(adapter));
        IBridgeFacet(vault).executeRequest(guid);

        // Shares burned from escrow
        assertEq(
            IERC20(vault).balanceOf(address(escrow)),
            0,
            "Escrow shares should be burned"
        );
        assertEq(
            IERC20(vault).totalSupply(),
            totalSupplyBefore - sharesToWithdraw,
            "Total supply should decrease"
        );
        assertGt(underlying.balanceOf(receiver), receiverAssetsBefore, "Receiver should get assets");
    }

    /**
     * @notice Cross-chain REDEEM: shares must be burned FROM escrow (not from owner)
     */
    function test_crossChainRedeem_BurnsSharesFromEscrow() public {
        factory.setIsCrossChainVault(100, vault, false);
        vm.startPrank(user);
        underlying.approve(vault, DEPOSIT_AMOUNT);
        IERC4626(vault).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
        factory.setIsCrossChainVault(100, vault, true);

        uint256 userShares = IERC20(vault).balanceOf(user);
        uint256 sharesToRedeem = userShares / 2;

        vm.startPrank(user);
        IERC20(vault).approve(address(escrow), sharesToRedeem);
        bytes memory callData = abi.encode(sharesToRedeem, receiver, user);
        bytes32 guid = IBridgeFacet(vault).initVaultActionRequest(
            MoreVaultsLib.ActionType.REDEEM,
            callData,
            0,
            bytes("")
        );
        vm.stopPrank();

        uint256 escrowSharesBefore = IERC20(vault).balanceOf(address(escrow));
        assertEq(escrowSharesBefore, sharesToRedeem, "Escrow should hold locked shares");

        vm.prank(address(adapter));
        IBridgeFacet(vault).updateAccountingInfoForRequest(guid, 0, true);

        uint256 receiverAssetsBefore = underlying.balanceOf(receiver);
        uint256 totalSupplyBefore = IERC20(vault).totalSupply();

        vm.prank(address(adapter));
        IBridgeFacet(vault).executeRequest(guid);

        assertEq(
            IERC20(vault).balanceOf(address(escrow)),
            0,
            "Escrow shares should be burned"
        );
        assertEq(
            IERC20(vault).totalSupply(),
            totalSupplyBefore - sharesToRedeem,
            "Total supply should decrease"
        );
        assertGt(underlying.balanceOf(receiver), receiverAssetsBefore, "Receiver should get assets");
    }
}
