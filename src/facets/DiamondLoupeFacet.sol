// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MoreVaultsLib} from "../libraries/MoreVaultsLib.sol";
import {IDiamondLoupe} from "../interfaces/facets/IDiamondLoupe.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {BaseFacetInitializer} from "./BaseFacetInitializer.sol";

contract DiamondLoupeFacet is BaseFacetInitializer, IDiamondLoupe, IERC165 {
    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        override
        returns (bytes32)
    {
        return keccak256("MoreVaults.storage.initializable.DiamondLoupeFacet");
    }

    function facetName() external pure returns (string memory) {
        return "DiamondLoupeFacet";
    }

    function facetVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function initialize(bytes calldata) external initializerFacet {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
    }

    function onFacetRemoval(address, bool) external {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = false;
        ds.supportedInterfaces[type(IERC165).interfaceId] = false;
    }

    /**
     * @inheritdoc IDiamondLoupe
     */
    function facets() external view override returns (Facet[] memory facets_) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; ) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = ds
                .facetFunctionSelectors[facetAddress_]
                .functionSelectors;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IDiamondLoupe
     */
    function facetFunctionSelectors(
        address _facet
    ) external view override returns (bytes4[] memory facetFunctionSelectors_) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        facetFunctionSelectors_ = ds
            .facetFunctionSelectors[_facet]
            .functionSelectors;
    }

    /**
     * @inheritdoc IDiamondLoupe
     */
    function facetAddresses()
        external
        view
        override
        returns (address[] memory facetAddresses_)
    {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        facetAddresses_ = ds.facetAddresses;
    }

    /**
     * @inheritdoc IDiamondLoupe
     */
    function facetAddress(
        bytes4 _functionSelector
    ) external view override returns (address facetAddress_) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        facetAddress_ = ds
            .selectorToFacetAndPosition[_functionSelector]
            .facetAddress;
    }

    // This implements ERC-165.
    function supportsInterface(
        bytes4 _interfaceId
    ) external view override returns (bool) {
        MoreVaultsLib.MoreVaultsStorage storage ds = MoreVaultsLib
            .moreVaultsStorage();
        return ds.supportedInterfaces[_interfaceId];
    }
}
