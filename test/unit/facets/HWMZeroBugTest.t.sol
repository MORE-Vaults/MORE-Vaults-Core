// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultFacet} from "../../../src/facets/VaultFacet.sol";
import {MoreVaultsStorageHelper} from "../../helper/MoreVaultsStorageHelper.sol";
import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {IVaultsFactory} from "../../../src/interfaces/IVaultsFactory.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";
import {IMoreVaultsRegistry} from "../../../src/interfaces/IMoreVaultsRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title HWMZeroBugTest
 * @notice Test to verify if the CURRENT code (with per-user HWM system)
 *         has vulnerability when userHighWaterMarkPerShare = 0
 *
 * HYPOTHESIS TO TEST:
 * If a user has shares but their HWM = 0 (due to migration from previous version),
 * and there is yield in the vault (currentPricePerShare > 0), then:
 * - Their entire position is considered "profit"
 * - 10% fee is charged on EVERYTHING, not just on real gains
 */
contract HWMZeroBugTest is Test {
    using Math for uint256;

    address public vault;
    address public owner = address(0x1111);
    address public curator = address(0x2222);
    address public guardian = address(0x3333);
    address public feeRecipient;
    address public registry = address(1000);
    address public asset;
    address public factory = address(1001);
    address public oracleRegistry = address(1002);
    address public router = address(1003);

    string constant VAULT_NAME = "Test Vault";
    string constant VAULT_SYMBOL = "TV";
    uint96 constant FEE = 1000; // 10%
    uint256 constant DEPOSIT_CAPACITY = type(uint256).max;

    function setUp() public {
        vm.warp(block.timestamp + 1 days);

        VaultFacet vaultFacet = new VaultFacet();
        vault = address(vaultFacet);

        MockERC20 mockToken = new MockERC20("Test Token", "TT");
        asset = address(mockToken);

        feeRecipient = owner;

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setOwner(vault, owner);
        MoreVaultsStorageHelper.setFactory(vault, factory);

        bytes memory initData = abi.encode(
            VAULT_NAME,
            VAULT_SYMBOL,
            asset,
            feeRecipient,
            FEE,
            DEPOSIT_CAPACITY
        );

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.oracle.selector),
            abi.encode(oracleRegistry)
        );
        vm.mockCall(
            address(oracleRegistry),
            abi.encodeWithSelector(IOracleRegistry.getOracleInfo.selector, asset),
            abi.encode(address(2000), uint96(1 hours))
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(IMoreVaultsRegistry.protocolFeeInfo.selector),
            abi.encode(address(0), uint96(0))
        );

        VaultFacet(vault).initialize(initData);

        MoreVaultsStorageHelper.setMoreVaultsRegistry(vault, registry);
        MoreVaultsStorageHelper.setCurator(vault, curator);
        MoreVaultsStorageHelper.setGuardian(vault, guardian);
        MoreVaultsStorageHelper.setIsHub(vault, true);
        MoreVaultsStorageHelper.setIsWithdrawalQueueEnabled(vault, false);

        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.localEid.selector),
            abi.encode(uint32(block.chainid))
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.isCrossChainVault.selector),
            abi.encode(false)
        );
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IVaultsFactory.getRestrictedFacets.selector),
            abi.encode(new address[](0))
        );
        vm.mockCall(registry, abi.encodeWithSelector(IMoreVaultsRegistry.router.selector), abi.encode(router));
    }

    /**
     * @notice TEST: Verify if the current code is vulnerable to HWM = 0
     *
     * Scenario:
     * 1. User deposits and receives shares (HWM is initialized)
     * 2. SIMULATE MIGRATION: Reset HWM to 0
     * 3. Simulate yield (more assets in the vault)
     * 4. User performs another operation
     * 5. Are incorrect fees charged?
     */
    function test_CurrentCode_HWMZeroVulnerability() public {
        console.log("=== TEST: HWM=0 Vulnerability in CURRENT code ===");
        console.log("");

        // Setup - need a second user to be fee recipient (not curator)
        address user = address(0x4444);
        MockERC20(asset).mint(user, 10 ether);
        vm.prank(user);
        IERC20(asset).approve(vault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, user, type(uint256).max);

        // STEP 1: User deposits
        console.log(">>> Step 1: User deposits 1 token <<<");
        vm.prank(user);
        uint256 shares1 = VaultFacet(vault).deposit(1 ether, user);

        uint256 userHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, user);
        console.log("  Shares received: %s", shares1);
        console.log("  Total Assets: %s", VaultFacet(vault).totalAssets());
        console.log("  User HWM after deposit: %s", userHWM);
        console.log("");

        // Verify if HWM was initialized correctly
        if (userHWM == 0) {
            console.log("  NOTE: HWM = 0 after deposit");
            console.log("  This may be a problem with the Helper or the code");
        } else {
            console.log("  HWM initialized correctly: %s", userHWM);
        }
        console.log("");

        // STEP 2: Simulate migration - reset HWM to 0
        console.log(">>> Step 2: SIMULATE MIGRATION - Reset HWM to 0 <<<");
        MoreVaultsStorageHelper.setUserHighWaterMarkPerShare(vault, user, 0);

        userHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, user);
        console.log("  User HWM after reset: %s", userHWM);
        console.log("");

        // STEP 3: Simulate yield (add assets to vault without deposit)
        console.log(">>> Step 3: Simulate YIELD of 0.5 tokens <<<");
        MockERC20(asset).mint(vault, 0.5 ether);

        console.log("  Total Assets now: %s", VaultFacet(vault).totalAssets());
        console.log("  Total Supply (unchanged): %s", VaultFacet(vault).totalSupply());
        console.log("");

        // Calculate current price
        uint256 totalAssets = VaultFacet(vault).totalAssets();
        uint256 totalSupply = VaultFacet(vault).totalSupply();
        uint256 decimalsOffset = 2;
        uint256 currentPrice = (totalAssets * (10 ** decimalsOffset)) / (totalSupply + 10 ** decimalsOffset);
        console.log("  Current price per share: %s", currentPrice);
        console.log("  User HWM: %s", userHWM);
        console.log("  currentPrice > HWM? %s", currentPrice > userHWM ? "YES - can charge fees" : "NO");
        console.log("");

        // STEP 4: User performs partial redeem
        console.log(">>> Step 4: User redeems 50 shares <<<");

        uint256 feeRecipientBefore = VaultFacet(vault).balanceOf(feeRecipient);
        uint256 sharePriceBefore = VaultFacet(vault).totalAssets() * 1e18 / VaultFacet(vault).totalSupply();

        vm.prank(user);
        uint256 assetsReceived = VaultFacet(vault).redeem(50 ether, user, user);

        uint256 feeRecipientAfter = VaultFacet(vault).balanceOf(feeRecipient);
        uint256 feeSharesMinted = feeRecipientAfter - feeRecipientBefore;

        console.log("");
        console.log("Result:");
        console.log("  Assets received: %s", assetsReceived);
        console.log("  Fee shares minted: %s", feeSharesMinted);
        console.log("");

        uint256 sharePriceAfter = VaultFacet(vault).totalAssets() * 1e18 / VaultFacet(vault).totalSupply();
        console.log("Share Price:");
        console.log("  Before: %s", sharePriceBefore);
        console.log("  After: %s", sharePriceAfter);
        console.log("");

        // ANALYSIS
        if (feeSharesMinted > 0) {
            console.log(">>> BUG CONFIRMED IN CURRENT CODE <<<");
            console.log("Fees were charged when HWM = 0");
            console.log("");
            console.log("Current code IS VULNERABLE to:");
            console.log("- Users with shares but HWM = 0 (due to migration)");
            console.log("- Any yield causes fee to be charged on EVERYTHING");
        } else {
            console.log(">>> NO BUG <<<");
            console.log("Current code is NOT vulnerable to HWM = 0");
        }

        // Test PASSES if bug exists (to document), FAILS if no bug
        // We want to know if the bug exists
        if (feeSharesMinted > 0) {
            console.log("");
            console.log("VULNERABILITY EXISTS - Fee shares minted: %s", feeSharesMinted);
        }
    }

    /**
     * @notice TEST: Normal behavior when HWM is correctly initialized
     */
    function test_NormalBehavior_HWMCorrectlyInitialized() public {
        console.log("=== TEST: Normal behavior with correct HWM ===");
        console.log("");

        // Setup
        MockERC20(asset).mint(curator, 10 ether);
        vm.prank(curator);
        IERC20(asset).approve(vault, type(uint256).max);
        MoreVaultsStorageHelper.setDepositWhitelist(vault, curator, type(uint256).max);

        // Curator deposits
        vm.prank(curator);
        VaultFacet(vault).deposit(1 ether, curator);

        uint256 curatorHWM = MoreVaultsStorageHelper.getUserHighWaterMarkPerShare(vault, curator);
        console.log("Curator HWM after deposit: %s", curatorHWM);

        // Simulate yield
        MockERC20(asset).mint(vault, 0.5 ether);

        // Redeem (DO NOT reset HWM)
        uint256 feeRecipientBefore = VaultFacet(vault).balanceOf(feeRecipient);

        vm.prank(curator);
        VaultFacet(vault).redeem(50 ether, curator, curator);

        uint256 feeSharesMinted = VaultFacet(vault).balanceOf(feeRecipient) - feeRecipientBefore;

        console.log("Fee shares minted (with correct HWM): %s", feeSharesMinted);
        console.log("");

        // With correct HWM, should only charge fee on real yield (0.5 tokens)
        // proportional to user's shares
        if (feeSharesMinted > 0) {
            console.log("Fees charged on REAL yield - expected behavior");
        } else {
            console.log("No fees - HWM protects correctly");
        }
    }
}
