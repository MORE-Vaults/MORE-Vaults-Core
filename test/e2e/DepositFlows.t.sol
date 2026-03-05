// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseE2ETest} from "./BaseE2ETest.sol";
import {IVaultFacet} from "../../src/interfaces/facets/IVaultFacet.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";
import {IConfigurationFacet} from "../../src/interfaces/facets/IConfigurationFacet.sol";
import {IVaultsFactory} from "../../src/interfaces/IVaultsFactory.sol";
import {IMoreVaultsRegistry} from "../../src/interfaces/IMoreVaultsRegistry.sol";
import {MoreVaultsLib} from "../../src/libraries/MoreVaultsLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IAggregatorV2V3Interface} from "../../src/interfaces/Chainlink/IAggregatorV2V3Interface.sol";
import {MockCCManager} from "../mocks/MockCCManager.sol";

contract DepositFlowsTest is BaseE2ETest {
    MockCCManager internal ccManager;

    function setUp() public override {
        super.setUp();
        ccManager = new MockCCManager();
    }

    // ── Helper: setup cross-chain with ccManager ──────────────────────
    function _setupCrossChainAsync() internal {
        _registerSpoke();

        // Mock isCrossChainAccountingManager on registry so setCrossChainAccountingManager succeeds
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(IMoreVaultsRegistry.isCrossChainAccountingManager.selector, address(ccManager)),
            abi.encode(true)
        );

        // setCrossChainAccountingManager requires msg.sender == address(this) (diamond self-call)
        vm.prank(hubVault);
        IConfigurationFacet(hubVault).setCrossChainAccountingManager(address(ccManager));
    }

    // ================================================================
    //  D1 -- Hub simple deposit (ERC4626 standard)
    // ================================================================
    function test_D1_simpleDeposit() public {
        // underlying is already added as available + depositable by VaultFacet.initialize
        _giveTokensAndApprove(user1, 1000e18);

        vm.prank(user1);
        uint256 shares = IVaultFacet(hubVault).deposit(1000e18, user1);

        assertGt(shares, 0, "D1: shares must be > 0");
        assertEq(IERC20(hubVault).balanceOf(user1), shares, "D1: user1 share balance mismatch");
    }

    // ================================================================
    //  D2 -- Hub simple multi-asset deposit
    // ================================================================
    function test_D2_multiAssetDeposit() public {
        // Enable weth as depositable asset
        oracleRegistry.setAssetPrice(address(weth), 2000e8);

        // Mock aggregator.decimals() for the oracle used in convertToUnderlying
        // The mock oracle returns address(0xDEAD) as aggregator for all assets
        vm.mockCall(
            address(0xDEAD),
            abi.encodeWithSelector(IAggregatorV2V3Interface.decimals.selector),
            abi.encode(uint8(8))
        );

        vm.prank(owner);
        IConfigurationFacet(hubVault).addAvailableAsset(address(weth));
        // enableAssetToDeposit requires msg.sender == address(this) (diamond self-call)
        vm.prank(hubVault);
        IConfigurationFacet(hubVault).enableAssetToDeposit(address(weth));

        uint256 underlyingAmount = 500e18;
        uint256 wethAmount = 1e18;

        // Give user tokens
        underlying.mint(user1, underlyingAmount);
        weth.mint(user1, wethAmount);
        vm.startPrank(user1);
        underlying.approve(hubVault, underlyingAmount);
        weth.approve(hubVault, wethAmount);
        vm.stopPrank();

        // Build multi-asset deposit arrays
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlying);
        tokens[1] = address(weth);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = underlyingAmount;
        amounts[1] = wethAmount;

        uint256 minShares = 0;

        // Call multi-asset deposit via low-level call (uses overloaded selector)
        vm.prank(user1);
        (bool ok, bytes memory data) = hubVault.call(
            abi.encodeWithSelector(
                bytes4(keccak256("deposit(address[],uint256[],address,uint256)")),
                tokens,
                amounts,
                user1,
                minShares
            )
        );
        assertTrue(ok, "D2: multi-asset deposit call failed");

        uint256 shares = abi.decode(data, (uint256));
        assertGt(shares, 0, "D2: shares must be > 0");
        assertEq(IERC20(hubVault).balanceOf(user1), shares, "D2: user1 share balance mismatch");
    }

    // ================================================================
    //  D3 -- Hub cross-chain, oracle ON, deposit sync
    // ================================================================
    function test_D3_crossChainOracleOn_deposit() public {
        _registerSpoke();
        _enableOracleAccounting();

        _giveTokensAndApprove(user1, 1000e18);

        vm.prank(user1);
        uint256 shares = IVaultFacet(hubVault).deposit(1000e18, user1);

        assertGt(shares, 0, "D3: shares must be > 0");
        assertEq(IERC20(hubVault).balanceOf(user1), shares, "D3: user1 share balance mismatch");
    }

    // ================================================================
    //  D4 -- Hub cross-chain, oracle OFF, deposit async via LZ Read
    // ================================================================
    function test_D4_crossChainOracleOff_deposit_async() public {
        _setupCrossChainAsync();

        _giveTokensAndApprove(user1, 1000e18);

        // User initiates async deposit
        vm.prank(user1);
        bytes32 guid = IBridgeFacet(hubVault).initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT,
            abi.encode(uint256(1000e18), user1),
            0, // no slippage check
            ""
        );

        // Verify request created
        MoreVaultsLib.CrossChainRequestInfo memory info = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertEq(info.initiator, user1, "D4: initiator mismatch");
        assertFalse(info.fulfilled, "D4: request should not be fulfilled yet");
        assertFalse(info.finalized, "D4: request should not be finalized yet");

        // Simulate LZ Read response (0 spoke USD because no assets in spoke)
        _simulateLzReadResponse(guid, 0, true);

        // Verify shares received
        uint256 userShares = IERC20(hubVault).balanceOf(user1);
        assertGt(userShares, 0, "D4: user1 should have received shares");

        // Verify finalization
        MoreVaultsLib.CrossChainRequestInfo memory finalInfo = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertTrue(finalInfo.finalized, "D4: request should be finalized");
    }

    // ================================================================
    //  D5 -- Hub cross-chain, oracle OFF, MINT async
    // ================================================================
    function test_D5_crossChainOracleOff_mint_async() public {
        _setupCrossChainAsync();

        // First do a small deposit to establish share price (avoid 0 supply edge case)
        _giveTokensAndApprove(user2, 100e18);
        vm.prank(user2);
        bytes32 seedGuid = IBridgeFacet(hubVault).initVaultActionRequest(
            MoreVaultsLib.ActionType.DEPOSIT,
            abi.encode(uint256(100e18), user2),
            0,
            ""
        );
        _simulateLzReadResponse(seedGuid, 0, true);

        // Calculate shares manually: shares = assets * totalSupply / totalAssets
        uint256 currentSupply = IERC20(hubVault).totalSupply();
        // totalAssets = 100e18 (what user2 deposited, no spoke value)
        uint256 sharesToMint = (1000e18 * currentSupply) / 100e18;
        uint256 maxAssets = 1000e18; // max amount in (slippage protection)

        _giveTokensAndApprove(user1, maxAssets);

        // User initiates async mint
        vm.prank(user1);
        bytes32 guid = IBridgeFacet(hubVault).initVaultActionRequest(
            MoreVaultsLib.ActionType.MINT,
            abi.encode(sharesToMint, user1),
            maxAssets, // amountLimit = maxAmountIn for mint
            ""
        );

        // Verify request created
        MoreVaultsLib.CrossChainRequestInfo memory info = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertEq(info.initiator, user1, "D5: initiator mismatch");
        assertEq(uint8(info.actionType), uint8(MoreVaultsLib.ActionType.MINT), "D5: action type mismatch");

        // Simulate LZ Read response
        _simulateLzReadResponse(guid, 0, true);

        // Verify shares received
        uint256 userShares = IERC20(hubVault).balanceOf(user1);
        assertGt(userShares, 0, "D5: user1 should have received shares");
        assertEq(userShares, sharesToMint, "D5: user1 should have exact shares minted");

        // Verify finalization
        MoreVaultsLib.CrossChainRequestInfo memory finalInfo = IBridgeFacet(hubVault).getRequestInfo(guid);
        assertTrue(finalInfo.finalized, "D5: request should be finalized");
    }
}
