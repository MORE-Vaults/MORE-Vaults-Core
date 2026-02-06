// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondCut, DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {IERC165, IDiamondLoupe, DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {IAccessControlFacet, AccessControlFacet} from "../../src/facets/AccessControlFacet.sol";
import {IConfigurationFacet, ConfigurationFacet} from "../../src/facets/ConfigurationFacet.sol";
import {IMulticallFacet, MulticallFacet} from "../../src/facets/MulticallFacet.sol";
import {IVaultFacet, IERC4626, IERC20, VaultFacet} from "../../src/facets/VaultFacet.sol";
import {IERC4626Facet, ERC4626Facet} from "../../src/facets/ERC4626Facet.sol";
import {IERC7540Facet, ERC7540Facet} from "../../src/facets/ERC7540Facet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IBridgeFacet} from "../../src/interfaces/facets/IBridgeFacet.sol";

contract DeployConfig {
    // Roles
    address public owner;
    address public curator;
    address public guardian;
    address public feeRecipient;
    address public minter = address(0xd061D61a4d941c39E5453435B6345Dc261C2fcE0);

    // Tokens
    address public assetToDeposit;
    address public wrappedNative;
    address public usd;

    uint96 public fee;
    uint256 public depositCapacity;
    uint256 public timeLockPeriod;
    uint256 public maxSlippagePercent;

    string public vaultName;
    string public vaultSymbol;

    struct FacetAddresses {
        address diamondCut;
        address diamondLoupe;
        address accessControl;
        address configuration;
        address multicall;
        address vault;
        address erc4626;
        address erc7540;
        address bridge;
    }

    function initParamsForProtocolDeployment(
        address _wrappedNative,
        address _usd
    ) external {
        wrappedNative = _wrappedNative;
        usd = _usd;
    }

    function initParamsForVaultCreation(
        address _owner,
        address _curator,
        address _guardian,
        address _feeRecipient,
        address _assetToDeposit,
        uint96 _fee,
        uint256 _depositCapacity,
        uint256 _timeLockPeriod,
        uint256 _maxSlippagePercent,
        string memory _vaultName,
        string memory _vaultSymbol
    ) external {
        owner = _owner;
        curator = _curator;
        guardian = _guardian;
        feeRecipient = _feeRecipient;
        assetToDeposit = _assetToDeposit;
        fee = _fee;
        depositCapacity = _depositCapacity;
        timeLockPeriod = _timeLockPeriod;
        maxSlippagePercent = _maxSlippagePercent;
        vaultName = _vaultName;
        vaultSymbol = _vaultSymbol;
    }

    function getCuts(
        FacetAddresses memory facetAddresses
    ) external view returns (IDiamondCut.FacetCut[] memory) {
        /// DEFAULT FACETS

        // selectors for diamond loupe
        bytes4[] memory functionSelectorsLoupeFacet = new bytes4[](5);
        functionSelectorsLoupeFacet[0] = IDiamondLoupe.facets.selector;
        functionSelectorsLoupeFacet[1] = IDiamondLoupe
            .facetFunctionSelectors
            .selector;
        functionSelectorsLoupeFacet[2] = IDiamondLoupe.facetAddresses.selector;
        functionSelectorsLoupeFacet[3] = IDiamondLoupe.facetAddress.selector;
        functionSelectorsLoupeFacet[4] = IERC165.supportsInterface.selector;

        // selectors for access control
        bytes4[] memory functionSelectorsAccessControlFacet = new bytes4[](8);
        functionSelectorsAccessControlFacet[0] = IAccessControlFacet
            .transferOwnership
            .selector;
        functionSelectorsAccessControlFacet[1] = IAccessControlFacet
            .acceptOwnership
            .selector;
        functionSelectorsAccessControlFacet[2] = IAccessControlFacet
            .transferCuratorship
            .selector;
        functionSelectorsAccessControlFacet[3] = IAccessControlFacet
            .transferGuardian
            .selector;
        functionSelectorsAccessControlFacet[4] = IAccessControlFacet
            .owner
            .selector;
        functionSelectorsAccessControlFacet[5] = IAccessControlFacet
            .pendingOwner
            .selector;
        functionSelectorsAccessControlFacet[6] = IAccessControlFacet
            .curator
            .selector;
        functionSelectorsAccessControlFacet[7] = IAccessControlFacet
            .guardian
            .selector;

        bytes memory initDataAccessControlFacet = abi.encode(
            owner,
            curator,
            guardian
        );

        // selectors for configuration
        bytes4[] memory functionSelectorsConfigurationFacet = new bytes4[](37);
        functionSelectorsConfigurationFacet[0] = ConfigurationFacet
            .setFeeRecipient
            .selector;
        functionSelectorsConfigurationFacet[1] = IConfigurationFacet
            .setTimeLockPeriod
            .selector;
        functionSelectorsConfigurationFacet[2] = IConfigurationFacet
            .setDepositCapacity
            .selector;
        functionSelectorsConfigurationFacet[3] = IConfigurationFacet
            .setDepositWhitelist
            .selector;
        functionSelectorsConfigurationFacet[4] = IConfigurationFacet
            .enableDepositWhitelist
            .selector;
        functionSelectorsConfigurationFacet[5] = IConfigurationFacet
            .disableDepositWhitelist
            .selector;
        functionSelectorsConfigurationFacet[6] = IConfigurationFacet
            .getAvailableToDeposit
            .selector;
        functionSelectorsConfigurationFacet[7] = IConfigurationFacet
            .addAvailableAsset
            .selector;
        functionSelectorsConfigurationFacet[8] = IConfigurationFacet
            .addAvailableAssets
            .selector;
        functionSelectorsConfigurationFacet[9] = IConfigurationFacet
            .enableAssetToDeposit
            .selector;
        functionSelectorsConfigurationFacet[10] = IConfigurationFacet
            .disableAssetToDeposit
            .selector;
        functionSelectorsConfigurationFacet[11] = IConfigurationFacet
            .setWithdrawalFee
            .selector;
        functionSelectorsConfigurationFacet[12] = IConfigurationFacet
            .setWithdrawalTimelock
            .selector;
        functionSelectorsConfigurationFacet[13] = IConfigurationFacet
            .updateWithdrawalQueueStatus
            .selector;
        functionSelectorsConfigurationFacet[14] = IConfigurationFacet
            .setGasLimitForAccounting
            .selector;
        functionSelectorsConfigurationFacet[15] = IConfigurationFacet
            .setMaxSlippagePercent
            .selector;
        functionSelectorsConfigurationFacet[16] = IConfigurationFacet
            .setCrossChainAccountingManager
            .selector;
        functionSelectorsConfigurationFacet[17] = ConfigurationFacet
            .getWithdrawalFee
            .selector;
        functionSelectorsConfigurationFacet[18] = ConfigurationFacet
            .getWithdrawalQueueStatus
            .selector;
        functionSelectorsConfigurationFacet[19] = ConfigurationFacet
            .getDepositableAssets
            .selector;
        functionSelectorsConfigurationFacet[20] = ConfigurationFacet
            .isAssetAvailable
            .selector;
        functionSelectorsConfigurationFacet[21] = ConfigurationFacet
            .isAssetDepositable
            .selector;
        functionSelectorsConfigurationFacet[22] = ConfigurationFacet
            .isDepositWhitelistEnabled
            .selector;
        functionSelectorsConfigurationFacet[23] = ConfigurationFacet
            .isHub
            .selector;
        functionSelectorsConfigurationFacet[24] = ConfigurationFacet
            .getAvailableAssets
            .selector;
        functionSelectorsConfigurationFacet[25] = ConfigurationFacet
            .fee
            .selector;
        functionSelectorsConfigurationFacet[26] = ConfigurationFacet
            .feeRecipient
            .selector;
        functionSelectorsConfigurationFacet[27] = ConfigurationFacet
            .depositCapacity
            .selector;
        functionSelectorsConfigurationFacet[28] = ConfigurationFacet
            .timeLockPeriod
            .selector;
        functionSelectorsConfigurationFacet[29] = ConfigurationFacet
            .getWithdrawalTimelock
            .selector;
        functionSelectorsConfigurationFacet[30] = ConfigurationFacet
            .lockedTokensAmountOfAsset
            .selector;
        functionSelectorsConfigurationFacet[31] = ConfigurationFacet
            .getStakingAddresses
            .selector;
        functionSelectorsConfigurationFacet[32] = ConfigurationFacet
            .tokensHeld
            .selector;
        functionSelectorsConfigurationFacet[33] = ConfigurationFacet
            .getCrossChainAccountingManager
            .selector;
        functionSelectorsConfigurationFacet[34] = ConfigurationFacet
            .getMaxSlippagePercent
            .selector;
        functionSelectorsConfigurationFacet[35] = ConfigurationFacet
            .getMaxWithdrawalDelay
            .selector;
        functionSelectorsConfigurationFacet[36] = ConfigurationFacet
            .setMaxWithdrawalDelay
            .selector;
        bytes memory initDataConfigurationFacet = abi.encode(
            maxSlippagePercent
        );

        // selectors for multicall
        bytes4[] memory functionSelectorsMulticallFacet = new bytes4[](5);
        functionSelectorsMulticallFacet[0] = IMulticallFacet
            .submitActions
            .selector;
        functionSelectorsMulticallFacet[1] = IMulticallFacet
            .executeActions
            .selector;
        functionSelectorsMulticallFacet[2] = IMulticallFacet
            .vetoActions
            .selector;
        functionSelectorsMulticallFacet[3] = IMulticallFacet
            .getPendingActions
            .selector;
        functionSelectorsMulticallFacet[4] = IMulticallFacet
            .getCurrentNonce
            .selector;
        bytes memory initDataMulticallFacet = abi.encode(timeLockPeriod);

        // selectors for vault
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
        functionSelectorsVaultFacet[25] = bytes4(
            keccak256("deposit(address[],uint256[],address)")
        );
        functionSelectorsVaultFacet[26] = IVaultFacet.paused.selector;
        functionSelectorsVaultFacet[27] = IVaultFacet.pause.selector;
        functionSelectorsVaultFacet[28] = IVaultFacet.unpause.selector;
        functionSelectorsVaultFacet[29] = IVaultFacet.totalAssetsUsd.selector;
        functionSelectorsVaultFacet[30] = IVaultFacet.setFee.selector;
        functionSelectorsVaultFacet[31] = IVaultFacet.requestRedeem.selector;
        functionSelectorsVaultFacet[32] = IVaultFacet.requestWithdraw.selector;
        functionSelectorsVaultFacet[33] = IVaultFacet.clearRequest.selector;
        functionSelectorsVaultFacet[34] = IVaultFacet
            .getWithdrawalRequest
            .selector;

        bytes memory initDataVaultFacet = abi.encode(
            vaultName,
            vaultSymbol,
            assetToDeposit,
            feeRecipient,
            fee,
            depositCapacity
        );

        /// OPTIONAL FACETS
        // selectors for erc4626Facet
        bytes4[] memory functionSelectorsERC4626Facet = new bytes4[](6);
        functionSelectorsERC4626Facet[0] = IERC4626Facet
            .erc4626Deposit
            .selector;
        functionSelectorsERC4626Facet[1] = IERC4626Facet.erc4626Mint.selector;
        functionSelectorsERC4626Facet[2] = IERC4626Facet
            .erc4626Withdraw
            .selector;
        functionSelectorsERC4626Facet[3] = IERC4626Facet.erc4626Redeem.selector;
        functionSelectorsERC4626Facet[4] = IERC4626Facet
            .genericAsyncActionExecution
            .selector;
        functionSelectorsERC4626Facet[5] = IERC4626Facet
            .accountingERC4626Facet
            .selector;

        bytes32 facetSelectorERC4626 = bytes4(
            keccak256(abi.encodePacked("accountingERC4626Facet()"))
        );
        bytes memory initDataERC4626Facet = abi.encode(facetSelectorERC4626);

        // selectors for erc7540Facet
        bytes4[] memory functionSelectorsERC7540Facet = new bytes4[](7);
        functionSelectorsERC7540Facet[0] = IERC7540Facet
            .erc7540Deposit
            .selector;
        functionSelectorsERC7540Facet[1] = IERC7540Facet.erc7540Mint.selector;
        functionSelectorsERC7540Facet[2] = IERC7540Facet
            .erc7540Withdraw
            .selector;
        functionSelectorsERC7540Facet[3] = IERC7540Facet.erc7540Redeem.selector;
        functionSelectorsERC7540Facet[4] = IERC7540Facet
            .erc7540RequestDeposit
            .selector;
        functionSelectorsERC7540Facet[5] = IERC7540Facet
            .erc7540RequestRedeem
            .selector;
        functionSelectorsERC7540Facet[6] = IERC7540Facet
            .accountingERC7540Facet
            .selector;

        bytes32 facetSelectorERC7540 = bytes4(
            keccak256(abi.encodePacked("accountingERC7540Facet()"))
        );
        bytes memory initDataERC7540Facet = abi.encode(facetSelectorERC7540);

        // selectors for bridge
        bytes4[] memory functionSelectorsBridgeFacet = new bytes4[](12);
        functionSelectorsBridgeFacet[0] = IBridgeFacet.executeBridging.selector;
        functionSelectorsBridgeFacet[1] = IBridgeFacet.quoteAccountingFee.selector;
        functionSelectorsBridgeFacet[2] = IBridgeFacet
            .initVaultActionRequest
            .selector;
        functionSelectorsBridgeFacet[3] = IBridgeFacet
            .updateAccountingInfoForRequest
            .selector;
        functionSelectorsBridgeFacet[4] = IBridgeFacet.executeRequest.selector;
        functionSelectorsBridgeFacet[5] = IBridgeFacet.getRequestInfo.selector;
        functionSelectorsBridgeFacet[6] = IBridgeFacet.accountingBridgeFacet.selector;
        functionSelectorsBridgeFacet[7] = IBridgeFacet.setOraclesCrossChainAccounting.selector;
        functionSelectorsBridgeFacet[8] = IBridgeFacet.oraclesCrossChainAccounting.selector;
        functionSelectorsBridgeFacet[9] = IBridgeFacet.getFinalizationResult.selector;
        functionSelectorsBridgeFacet[10] = IBridgeFacet.sendNativeTokenBackToInitiator.selector;
        functionSelectorsBridgeFacet[11] = IBridgeFacet.refundStuckDepositInComposer.selector;
        bytes memory initDataBridgeFacet = abi.encode();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.diamondLoupe,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsLoupeFacet,
            initData: ""
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.accessControl,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsAccessControlFacet,
            initData: initDataAccessControlFacet
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.configuration,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsConfigurationFacet,
            initData: initDataConfigurationFacet
        });
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.multicall,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsMulticallFacet,
            initData: initDataMulticallFacet
        });
        cuts[4] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.vault,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsVaultFacet,
            initData: initDataVaultFacet
        });
        cuts[5] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.erc4626,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsERC4626Facet,
            initData: initDataERC4626Facet
        });
        cuts[6] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.erc7540,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsERC7540Facet,
            initData: initDataERC7540Facet
        });
        cuts[7] = IDiamondCut.FacetCut({
            facetAddress: facetAddresses.bridge,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectorsBridgeFacet,
            initData: initDataBridgeFacet
        });

        return cuts;
    }
}
