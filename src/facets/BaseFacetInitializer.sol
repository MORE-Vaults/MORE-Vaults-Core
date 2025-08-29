// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @dev This is a base storage for the  initialization function for upgradeable diamond facet contracts
 **/

abstract contract BaseFacetInitializer {
    error InvalidParameters();
    error AlreadyInitialized();
    error FacetNotInitializing();

    struct Layout {
        /*
         * Indicates that the contract has been initialized.
         */
        bool _initialized;
        /*
         * Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    /**
     * @dev Returns the storage slot for this contract
     * @return bytes32 The storage slot
     */
    function INITIALIZABLE_STORAGE_SLOT()
        internal
        pure
        virtual
        returns (bytes32);

    function layoutInitializableStorage()
        internal
        pure
        returns (Layout storage l)
    {
        bytes32 slot = INITIALIZABLE_STORAGE_SLOT();
        assembly {
            l.slot := slot
        }
    }

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializerFacet() {
        if (
            layoutInitializableStorage()._initializing
                ? !_isConstructor()
                : layoutInitializableStorage()._initialized
        ) {
            revert AlreadyInitialized();
        }

        bool isTopLevelCall = !layoutInitializableStorage()._initializing;
        if (isTopLevelCall) {
            layoutInitializableStorage()._initializing = true;
            layoutInitializableStorage()._initialized = true;
        }

        _;

        if (isTopLevelCall) {
            layoutInitializableStorage()._initializing = false;
        }
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} modifier, directly or indirectly.
     */
    modifier onlyInitializingFacet() {
        if (!layoutInitializableStorage()._initializing) {
            revert FacetNotInitializing();
        }
        _;
    }

    /// @dev Returns true if and only if the function is running in the constructor
    function _isConstructor() private view returns (bool) {
        // extcodesize checks the size of the code stored in an address, and
        // address returns the current address. Since the code is still not
        // deployed when running a constructor, any checks on its code size will
        // yield zero, making it an effective way to detect if a contract is
        // under construction or not.
        address self = address(this);
        uint256 cs;
        assembly {
            cs := extcodesize(self)
        }
        return cs == 0;
    }
}
