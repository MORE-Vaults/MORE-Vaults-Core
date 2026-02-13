// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IDiamondCut} from "../src/interfaces/facets/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/facets/IDiamondLoupe.sol";
import {IMulticallFacet} from "../src/interfaces/facets/IMulticallFacet.sol";
import {IConfigurationFacet} from "../src/interfaces/facets/IConfigurationFacet.sol";
import {IVaultFacet} from "../src/interfaces/facets/IVaultFacet.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

/**
 * @title UpdateVaultFacetForVault
 * @notice Script updates ONLY VaultFacet for a specific vault (diamond) via timelock submitActions.
 *
 * @dev Environment variables:
 *      - PRIVATE_KEY: sender key (curator/owner with submitActions permission)
 *      - TARGET_VAULT: target vault address (diamond)
 *      - VAULT_FACET: new VaultFacet address (must be allowed in registry and have required selectors)
 *
 * @dev Example:
 *      forge script scripts/UpdateVaultFacetForVault.s.sol:UpdateVaultFacetForVault \
 *        --chain-id <ID> --rpc-url <RPC> -vv --slow --broadcast
 * 
 *      Base mainnet:
 *      forge script scripts/UpdateVaultFacetForVault.s.sol:UpdateVaultFacetForVault --chain-id 8453 --rpc-url https://base-mainnet.g.alchemy.com/v2/FBUmQwWnyZ5v8QJq8oqJE -vv --slow --broadcast --verify --verifier etherscan --etherscan-api-key SAWW4TJWRUS434R1J29QKXUG8XBTBVTAP1
 * 
 */
contract UpdateVaultFacetForVault is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("TARGET_VAULT");
        address newVaultFacet = vm.envAddress("VAULT_FACET");

        if (vault == address(0)) revert("Missing TARGET_VAULT env");
        if (newVaultFacet == address(0)) revert("Missing VAULT_FACET env");

        vm.startBroadcast(deployerPrivateKey);

        console.log("Target vault:", vault);
        console.log("New VaultFacet:", newVaultFacet);

        // totalAssets sanity check (before submitting to timelock)
        uint256 totalAssetsBefore;
        try IERC4626(vault).totalAssets() returns (uint256 assets) {
            totalAssetsBefore = assets;
            console.log("Total assets before:", totalAssetsBefore);
        } catch {
            console.log("WARNING: failed to read totalAssets before");
        }

        IDiamondCut.FacetCut[] memory cuts = _buildVaultFacetOnlyCuts(vault, newVaultFacet);

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts);

        uint256 timeLockPeriod = IConfigurationFacet(vault).timeLockPeriod();

        try IMulticallFacet(vault).submitActions(actions) returns (uint256 nonce) {
            console.log("submitActions success");
            console.log("Actions nonce:", nonce);
            if (timeLockPeriod == 0) {
                console.log("TimeLock period is 0 - actions can be executed immediately");
            } else {
                console.log("TimeLock period:", timeLockPeriod, "seconds");
                console.log("Current timestamp:", block.timestamp);
                console.log("Actions executable after:", block.timestamp + timeLockPeriod);
            }
        } catch Error(string memory reason) {
            console.log("submitActions failed, reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("submitActions failed (low-level)");
            console.logBytes(lowLevelData);
        }

        // totalAssets sanity check (after submitActions — state should not change)
        uint256 totalAssetsAfter;
        try IERC4626(vault).totalAssets() returns (uint256 assets) {
            totalAssetsAfter = assets;
            console.log("Total assets after:", totalAssetsAfter);
            if (totalAssetsBefore == totalAssetsAfter) {
                console.log("Total assets unchanged - OK");
            } else {
                console.log("WARNING: totalAssets changed!");
                console.log("Before:", totalAssetsBefore);
                console.log("After:", totalAssetsAfter);
            }
        } catch {
            console.log("WARNING: failed to read totalAssets after");
        }

        vm.stopBroadcast();
    }

    function _buildVaultFacetOnlyCuts(address vault, address newVaultFacet)
        internal
        view
        returns (IDiamondCut.FacetCut[] memory)
    {
        // initData for VaultFacet (used only if asset() is not yet initialized; otherwise initialize() will just exit)
        IERC20Metadata vaultToken = IERC20Metadata(vault);
        string memory vaultName = vaultToken.name();
        string memory vaultSymbol = vaultToken.symbol();
        address assetToDeposit = IERC4626(vault).asset();

        IConfigurationFacet vaultCfg = IConfigurationFacet(vault);
        address feeRecipient = vaultCfg.feeRecipient();
        uint96 fee = vaultCfg.fee();
        uint256 depositCapacity = vaultCfg.depositCapacity();

        bytes memory initDataVaultFacet = abi.encode(
            vaultName, vaultSymbol, assetToDeposit, feeRecipient, fee, depositCapacity
        );

        // VaultFacet selectors — keep in sync with what was added to registry (see DeployFacetsPostAudit)
        bytes4[] memory functionSelectorsVaultFacet = new bytes4[](35);
        functionSelectorsVaultFacet[0] = IERC20Metadata.name.selector;
        functionSelectorsVaultFacet[1] = IERC20Metadata.symbol.selector;
        functionSelectorsVaultFacet[2] = IERC20Metadata.decimals.selector;
        functionSelectorsVaultFacet[3] = IERC20.balanceOf.selector;
        functionSelectorsVaultFacet[4] = IERC20.approve.selector;
        functionSelectorsVaultFacet[5] = IERC20.transfer.selector;
        functionSelectorsVaultFacet[6] = IERC20.transferFrom.selector;
        functionSelectorsVaultFacet[7] = IERC20.allowance.selector;
        functionSelectorsVaultFacet[8] = IERC20.totalSupply.selector;
        functionSelectorsVaultFacet[9] = IERC4626.asset.selector;
        functionSelectorsVaultFacet[10] = IERC4626.totalAssets.selector;
        functionSelectorsVaultFacet[11] = IERC4626.convertToAssets.selector;
        functionSelectorsVaultFacet[12] = IERC4626.convertToShares.selector;
        functionSelectorsVaultFacet[13] = IERC4626.maxDeposit.selector;
        functionSelectorsVaultFacet[14] = IERC4626.previewDeposit.selector;
        functionSelectorsVaultFacet[15] = IERC4626.deposit.selector;
        functionSelectorsVaultFacet[16] = IERC4626.maxMint.selector;
        functionSelectorsVaultFacet[17] = IERC4626.previewMint.selector;
        functionSelectorsVaultFacet[18] = IERC4626.mint.selector;
        functionSelectorsVaultFacet[19] = IERC4626.maxWithdraw.selector;
        functionSelectorsVaultFacet[20] = IERC4626.previewWithdraw.selector;
        functionSelectorsVaultFacet[21] = IERC4626.withdraw.selector;
        functionSelectorsVaultFacet[22] = IERC4626.maxRedeem.selector;
        functionSelectorsVaultFacet[23] = IERC4626.previewRedeem.selector;
        functionSelectorsVaultFacet[24] = IERC4626.redeem.selector;
        // NOTE: selector is intentionally the same as in your deploy scripts/registry
        functionSelectorsVaultFacet[25] = bytes4(keccak256("deposit(address[],uint256[],address)"));
        functionSelectorsVaultFacet[26] = IVaultFacet.paused.selector;
        functionSelectorsVaultFacet[27] = IVaultFacet.pause.selector;
        functionSelectorsVaultFacet[28] = IVaultFacet.unpause.selector;
        functionSelectorsVaultFacet[29] = IVaultFacet.totalAssetsUsd.selector;
        functionSelectorsVaultFacet[30] = IVaultFacet.setFee.selector;
        functionSelectorsVaultFacet[31] = IVaultFacet.requestRedeem.selector;
        functionSelectorsVaultFacet[32] = IVaultFacet.requestWithdraw.selector;
        functionSelectorsVaultFacet[33] = IVaultFacet.clearRequest.selector;
        functionSelectorsVaultFacet[34] = IVaultFacet.getWithdrawalRequest.selector;

        IDiamondLoupe loupe = IDiamondLoupe(vault);
        address oldVaultFacet = loupe.facetAddress(functionSelectorsVaultFacet[0]); // name()

        if (oldVaultFacet == address(0)) {
            IDiamondCut.FacetCut[] memory addOnly = new IDiamondCut.FacetCut[](1);
            addOnly[0] = IDiamondCut.FacetCut({
                facetAddress: newVaultFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: functionSelectorsVaultFacet,
                initData: initDataVaultFacet
            });
            return addOnly;
        }

        bytes4[] memory existedSelectors = loupe.facetFunctionSelectors(oldVaultFacet);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: existedSelectors,
            initData: ""
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: newVaultFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsVaultFacet,
            initData: initDataVaultFacet
        });
        return cuts;
    }
}



