// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC7540Facet} from "../interfaces/facets/IERC7540Facet.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC7540} from "../interfaces/IERC7540.sol";

/**
 * @title ERC7540Facet
 * @dev Facet for handling ERC7540 asynchronous token operations
 * This facet provides functionality for creating and executing asynchronous
 * deposit and withdrawal requests on ERC7540-compliant vaults
 */
contract ERC7540Facet is IERC7540Facet, BaseFacetInitializer {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Constant identifier for ERC7540 operations
    bytes32 constant ERC7540_ID = keccak256("ERC7540_ID");

    /**
     * @notice Returns the storage slot for this facet's initializable storage
     * @return bytes32 The storage slot identifier
     */
    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.ERC7540Facet");
    }

    /**
     * @notice Returns the name of this facet
     * @return string The facet name
     */
    function facetName() external pure returns (string memory) {
        return "ERC7540Facet";
    }

    /**
     * @notice Returns the version of this facet
     * @return string The facet version
     */
    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Initializes the ERC7540Facet
     * @param data Encoded data containing the facet selector
     */
    function initialize(bytes calldata data) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        bytes32 facetSelector = abi.decode(data, (bytes32));
        ds.facetsForAccounting.push(facetSelector);

        ds.supportedInterfaces[type(IERC7540Facet).interfaceId] = true;
        ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].add(ERC7540_ID);
    }

    /**
     * @notice Handles facet removal and cleanup
     * @param isReplacing Whether the facet is being replaced
     */
    function onFacetRemoval(bool isReplacing) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        ds.supportedInterfaces[type(IERC7540Facet).interfaceId] = false;

        MoreVaultsLib.removeFromFacetsForAccounting(ds, IERC7540Facet.accountingERC7540Facet.selector, isReplacing);
        if (!isReplacing) {
            ds.vaultExternalAssets[MoreVaultsLib.TokenType.HeldToken].remove(ERC7540_ID);
        }
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function accountingERC7540Facet() public view returns (uint256 sum, bool isPositive) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        for (uint256 i = 0; i < ds.tokensHeld[ERC7540_ID].length();) {
            address vault = ds.tokensHeld[ERC7540_ID].at(i);
            if (ds.isAssetAvailable[vault]) {
                unchecked {
                    ++i;
                }
                continue;
            }
            address asset = IERC4626(vault).asset();
            uint256 balance = IERC20(vault).balanceOf(address(this)) + ds.lockedTokens[vault];
            uint256 convertedToVaultUnderlying = IERC4626(vault).convertToAssets(balance);
            sum += MoreVaultsLib.convertToUnderlying(asset, convertedToVaultUnderlying, Math.Rounding.Floor);
            unchecked {
                ++i;
            }
        }
        return (sum, true);
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540RequestDeposit(address vault, uint256 assets) external returns (uint256 requestId) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        address asset = IERC4626(vault).asset();

        IERC20(asset).forceApprove(vault, assets);
        requestId = IERC7540(vault).requestDeposit(assets, address(this), address(this));
        ds.lockedTokens[asset] += assets;
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540RequestRedeem(address vault, uint256 shares) external returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        requestId = IERC7540(vault).requestRedeem(shares, address(this), address(this));
        ds.lockedTokens[vault] += shares;
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540Deposit(address vault, uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        address asset = IERC4626(vault).asset();
        shares = IERC7540(vault).deposit(assets, address(this), address(this));
        ds.tokensHeld[ERC7540_ID].add(vault);

        // Unlock assets that were locked during requestDeposit
        if (ds.lockedTokens[asset] >= assets) {
            ds.lockedTokens[asset] -= assets;
        }
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540Mint(address vault, uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        address asset = IERC4626(vault).asset();
        assets = IERC7540(vault).mint(shares, address(this), address(this));
        ds.tokensHeld[ERC7540_ID].add(vault);

        // Unlock assets that were locked during requestDeposit
        if (ds.lockedTokens[asset] >= assets) {
            ds.lockedTokens[asset] -= assets;
        }
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540Withdraw(address vault, uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        shares = IERC7540(vault).withdraw(assets, address(this), address(this));

        // Unlock shares that were locked during requestRedeem
        if (ds.lockedTokens[vault] >= shares) {
            ds.lockedTokens[vault] -= shares;
        }

        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC7540_ID], vault);
    }

    /**
     * @inheritdoc IERC7540Facet
     */
    function erc7540Redeem(address vault, uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        AccessControlLib.validateDiamond(msg.sender);
        MoreVaultsLib.validateAddressWhitelisted(vault);
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();

        assets = IERC7540(vault).redeem(shares, address(this), address(this));

        // Unlock shares that were locked during requestRedeem
        if (ds.lockedTokens[vault] >= shares) {
            ds.lockedTokens[vault] -= shares;
        }

        MoreVaultsLib.removeTokenIfnecessary(ds.tokensHeld[ERC7540_ID], vault);
    }
}
