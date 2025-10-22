// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib, TOTAL_ASSETS_SELECTOR, TOTAL_ASSETS_RUN_FAILED} from "../libraries/MoreVaultsLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IMulticallFacet} from "../interfaces/facets/IMulticallFacet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";
import {
    ERC4626Upgradeable,
    IERC20,
    SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

contract FixHelperFacet is BaseFacetInitializer, ContextUpgradeable, ReentrancyGuard, ERC4626Upgradeable {
    error SlippageExceeded(uint256 slippagePercent, uint256 maxSlippagePercent);

    function INITIALIZABLE_STORAGE_SLOT() internal pure override returns (bytes32) {
        return keccak256("MoreVaults.storage.initializable.FixHelperFacetV6");
    }

    function facetName() external pure returns (string memory) {
        return "FixHelperFacetV6";
    }

    function facetVersion() external pure returns (string memory) {
        return "6.0.0";
    }

    function initialize(bytes calldata) external initializerFacet {
        _burn(
            address(0x0d28781A95959d515ed4F8283964876ce2605Dc2),
            IERC20(address(this)).balanceOf(address(0x0d28781A95959d515ed4F8283964876ce2605Dc2))
        );
        // _burn(address(0x4fBB19B3dc3c63B8eC5d0077eE9783e0b1557644), IERC20(address(this)).balanceOf(address(0x4fBB19B3dc3c63B8eC5d0077eE9783e0b1557644)));
        IERC20(address(0xe17EeA6Df1A59A1b7745541A5D1B94e822D00766)).transfer(
            address(0x0d28781A95959d515ed4F8283964876ce2605Dc2), 2 ether
        );
        // MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib.moreVaultsStorage();
        // ds.maxSlippagePercent = 10000;
    }

    function onFacetRemoval(bool) external {}

    function somePlaceHolderFunction() external {}
}
