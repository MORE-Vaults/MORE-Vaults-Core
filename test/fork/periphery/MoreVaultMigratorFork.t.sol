// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IOracleRegistry} from "../../../src/interfaces/IOracleRegistry.sol";

import {IVaultFacet} from "../../../src/interfaces/facets/IVaultFacet.sol";
import {MoreVaultMigrator} from "../../../src/periphery/MoreVaultMigrator.sol";

/// @dev Minimal local vault for fork migration destination.
contract LocalNewVault is ERC4626, IVaultFacet {
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Local New Vault Share", "lnvSHARE") {}

    // IVaultFacet compatibility stubs (unused in this test)
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 shares)
    {
        return ERC4626.deposit(assets, receiver);
    }
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 assets)
    {
        return ERC4626.mint(shares, receiver);
    }
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 shares)
    {
        return ERC4626.withdraw(assets, receiver, owner);
    }
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IVaultFacet)
        returns (uint256 assets)
    {
        return ERC4626.redeem(shares, receiver, owner);
    }
    function pause() external override {}
    function unpause() external override {}
    function paused() external pure override returns (bool) { return false; }
    function totalAssets() public view override(ERC4626, IVaultFacet) returns (uint256) { return ERC4626.totalAssets(); }
    function totalAssetsUsd() external pure override returns (uint256, bool) { return (0, false); }
    function getWithdrawalRequest(address) external pure override returns (uint256, uint256) { return (0, 0); }
    function deposit(address[] calldata, uint256[] calldata, address, uint256)
        external
        payable
        override
        returns (uint256)
    {
        revert("not used");
    }
    function setFee(uint96) external override {}
    function requestRedeem(uint256, address) external pure override { revert("not used"); }
    function requestWithdraw(uint256, address) external pure override { revert("not used"); }
    function clearRequest() external override {}
    function accrueFees(address) external override {}
    function initialize(bytes calldata) external override {}
    function onFacetRemoval(bool) external override {}
    function facetName() external pure returns (string memory) { return "LocalNewVault"; }
    function facetVersion() external pure returns (string memory) { return "1.0.0"; }
}

contract MoreVaultMigratorForkTest is Test {
    bytes4 private constant REQUEST_REDEEM_LEGACY_SELECTOR = bytes4(keccak256("requestRedeem(uint256)"));
    bytes4 private constant ORACLE_SELECTOR = bytes4(keccak256("oracle()"));
    bytes4 private constant GET_ASSET_PRICE_SELECTOR = bytes4(keccak256("getAssetPrice(address)"));
    error TimelockNotMatureYet(uint256 timelockEndsAt, uint256 currentTimestamp);
    error OracleAddressIsRequired();

    function test_fork_migrateFromOldToNewVault() external {
        string memory rpcUrl = vm.envString("FORK_RPC_URL");
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        address oldVaultAddr = vm.envAddress("FORK_OLD_VAULT");
        address depositor = vm.envOr("FORK_DEPOSITOR", makeAddr("genericDepositor"));

        IVaultFacet oldVault = IVaultFacet(oldVaultAddr);
        IERC20 asset = IERC20(oldVault.asset());
        LocalNewVault newVault = new LocalNewVault(address(asset));
        address newVaultAddr = address(newVault);

        address owner = address(this);
        address curator = address(this);
        MoreVaultMigrator migrator = new MoreVaultMigrator(oldVaultAddr, newVaultAddr, owner, curator);
        assertEq(address(asset), IVaultFacet(newVaultAddr).asset(), "asset mismatch");

        uint8 decimals = IERC20Metadata(address(asset)).decimals();
        uint256 defaultDepositAssets = 100 * (10 ** uint256(decimals));
        uint256 maxDepositAssets = oldVault.maxDeposit(depositor);
        if (maxDepositAssets > 0 && defaultDepositAssets > maxDepositAssets) {
            defaultDepositAssets = maxDepositAssets / 2;
        }
        uint256 depositAssets = vm.envOr("FORK_DEPOSIT_ASSETS", defaultDepositAssets);
        // On forked tokens totalSupply can be virtual/proxied, so avoid stdStorage totalSupply adjustment.
        deal(address(asset), depositor, depositAssets);
        vm.startPrank(depositor);
        asset.approve(oldVaultAddr, depositAssets);
        uint256 depositedShares = oldVault.deposit(depositAssets, depositor);
        vm.stopPrank();
        assertGt(depositedShares, 0, "zero deposited shares");

        uint256 requestShares = vm.envOr("FORK_REQUEST_SHARES", depositedShares / 2);
        if (requestShares == 0) {
            requestShares = depositedShares;
        }

        vm.prank(depositor);
        IERC20(oldVaultAddr).approve(address(migrator), requestShares);

        vm.prank(depositor);
        (bool ok,) = oldVaultAddr.call(abi.encodeWithSelector(REQUEST_REDEEM_LEGACY_SELECTOR, requestShares));
        require(ok, "legacy requestRedeem failed");

        (, uint256 timelockEndsAt) = oldVault.getWithdrawalRequest(depositor);
        bool wasWarped;
        if (timelockEndsAt > block.timestamp) {
            bool allowWarp = vm.envOr("FORK_ALLOW_WARP", false);
            if (!allowWarp) {
                revert TimelockNotMatureYet(timelockEndsAt, block.timestamp);
            }
            vm.warp(timelockEndsAt + 1);
            wasWarped = true;
        }

        // Fork oracles can become stale after warp. For migration-path testing we can mock fresh prices.
        bool mockOracleAfterWarp = vm.envOr("FORK_MOCK_ORACLE_AFTER_WARP", true);
        if (wasWarped && mockOracleAfterWarp) {
            _mockFreshOracleData(oldVaultAddr);
        }

        uint256 oldSharesBefore = IERC20(oldVaultAddr).balanceOf(depositor);
        uint256 newSharesBefore = IERC20(newVaultAddr).balanceOf(depositor);

        uint256 minNewShares = vm.envOr("FORK_MIN_NEW_SHARES", uint256(0));
        uint256 expectedAssetsReceived = IVaultFacet(oldVaultAddr).convertToAssets(requestShares);
        (uint256 migratedShares,, uint256 mintedNewShares) = migrator.finalizeMigration(depositor, requestShares, minNewShares);


        assertGt(migratedShares, 0, "nothing migrated");
        assertEq(mintedNewShares, expectedAssetsReceived, "zero new shares minted");
        assertEq(IERC20(oldVaultAddr).balanceOf(depositor), oldSharesBefore - migratedShares, "old shares mismatch");
        assertEq(IERC20(newVaultAddr).balanceOf(depositor), newSharesBefore + mintedNewShares, "new shares mismatch");
        assertEq(asset.balanceOf(address(migrator)), 0, "migrator should not keep assets");
    }

    function _mockFreshOracleData(address oldVaultAddr) internal {
        address oracle = vm.envOr("FORK_ORACLE", address(0));
        if (oracle == address(0)) {
            (bool ok, bytes memory data) = oldVaultAddr.staticcall(abi.encodeWithSelector(ORACLE_SELECTOR));
            if (!ok || data.length < 32) {
                revert OracleAddressIsRequired();
            }
            oracle = abi.decode(data, (address));
        }
        if (oracle == address(0)) {
            revert OracleAddressIsRequired();
        }

        uint256 mockedPrice = vm.envOr("FORK_MOCK_PRICE", uint256(1e8));
        // Mock by selector so any getAssetPrice(asset) call returns a fresh deterministic value.
        vm.mockCall(oracle, abi.encodeWithSelector(IOracleRegistry.getAssetPrice.selector), abi.encode(mockedPrice));
        address extraAsset = vm.envOr("FORK_EXTRA_PRICE_ASSET", address(0));
        if (extraAsset != address(0)) {
            vm.mockCall(oracle, abi.encodeWithSelector(GET_ASSET_PRICE_SELECTOR, extraAsset), abi.encode(mockedPrice));
        }
    }
}
