// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGenericMoreVaultFacetInitializable} from "./IGenericMoreVaultFacetInitializable.sol";

interface IConfigurationFacet is IGenericMoreVaultFacetInitializable {
    /**
     * @dev Custom errors
     */
    error InvalidAddress();
    error InvalidPeriod();
    error AssetAlreadyAvailable();
    error AssetNotAvailable();
    error TimeLockPeriodNotExpired();
    error NothingSubmitted();
    error ArraysLengthsMismatch();
    error InvalidManager();
    error SlippageTooHigh();
    error FeeIsTooHigh();

    /**
     * @dev Events
     */
    /// @notice Emitted when the MoreVaults registry is set
    event MoreVaultRegistrySet(address indexed previousRegistry, address indexed newRegistry);
    /// @notice Emitted when a new asset is added
    event AssetAdded(address indexed asset);
    /// @notice Emitted when an asset is removed
    event AssetRemoved(address indexed asset);
    /// @notice Emitted when the withdrawal fee is set
    event WithdrawalFeeSet(uint96 fee);
    /// @notice Emitted when the withdrawal queue status is set
    event WithdrawalQueueStatusSet(bool status);
    /// @notice Emitted when the withdrawal timelock is set
    event WithdrawalTimelockSet(uint64 duration);
    /// @notice Emitted when the cross chain accounting manager is set
    event CrossChainAccountingManagerSet(address indexed manager);
    /// @notice Emitted when the max slippage percent is set
    event MaxSlippagePercentSet(uint256 percent);
    /// @notice Emitted when the max withdrawal delay is set
    event MaxWithdrawalDelaySet(uint32 delay);

    /**
     * @notice Sets fee recipient address, callable by owner
     * @param recipient New fee recipient address
     */
    function setFeeRecipient(address recipient) external;

    /**
     * @notice Sets time lock period, callable by owner through `submitActions` and timelocked
     * @param period New time lock period (in seconds)
     */
    function setTimeLockPeriod(uint256 period) external;

    /**
     * @notice Sets deposit capacity, callable by curator or owner
     * @param capacity New deposit capacity
     */
    function setDepositCapacity(uint256 capacity) external;

    /**
     * @notice Sets deposit whitelist, callable by owner
     * @param depositors Array of depositors
     * @param undelyingAssetCaps Array of underlying asset caps
     */
    function setDepositWhitelist(address[] calldata depositors, uint256[] calldata undelyingAssetCaps) external;

    /**
     * @notice Enables deposit whitelist, callable by owner
     */
    function enableDepositWhitelist() external;

    /**
     * @notice Disables deposit whitelist, callable by owner through `submitActions` and timelocked
     */
    function disableDepositWhitelist() external;

    /**
     * @notice Disables deposit whitelist
     */
    /**
     * @notice Gets deposit whitelist
     * @param depositor Depositor address
     * @return Undelying asset cap
     */
    function getDepositWhitelist(address depositor) external view returns (uint256);

    /**
     * @notice Adds new available asset, callable by curator or owner
     * @param asset Asset address to add
     */
    function addAvailableAsset(address asset) external;

    /**
     * @notice Batch adds new available assets, callable by curator or owner
     * @param assets Array of asset addresses to add
     */
    function addAvailableAssets(address[] calldata assets) external;

    /**
     * @notice Enables asset to deposit, callable by curator or owner through `submitActions` and timelocked
     * @param asset Asset address to enable
     */
    function enableAssetToDeposit(address asset) external;

    /**
     * @notice Disables asset to deposit, callable by curator
     * @param asset Asset address to disable
     */
    function disableAssetToDeposit(address asset) external;

    /**
     * @notice Set the withdrawal fee, callable by owner through `submitActions` and timelocked
     * @param _fee New withdrawal fee
     */
    function setWithdrawalFee(uint96 _fee) external;

    /**
     * @notice Update the withdraw timelock duration, callable by owner through `submitActions` and timelocked
     * @param duration New withdraw timelock duration
     */
    function setWithdrawalTimelock(uint64 duration) external;

    /**
     * @notice Update the withdrawal queue status, callable by owner through `submitActions` and timelocked
     * @param _status New withdrawal queue status
     */
    function updateWithdrawalQueueStatus(bool _status) external;

    /**
     * @notice Update the max withdrawal delay, callable by owner through `submitActions` and timelocked
     * @param _delay New max withdrawal delay
     */
    function setMaxWithdrawalDelay(uint32 _delay) external;

    /**
     * @notice Sets gas limit for accounting, callable by curator or owner through `submitActions` and timelocked
     * @param _availableTokenAccountingGas Gas limit for available token accounting
     * @param _heldTokenAccountingGas Gas limit for held token accounting
     * @param _facetAccountingGas Gas limit for facet accounting
     * @param _newLimit New gas limit
     */
    function setGasLimitForAccounting(
        uint48 _availableTokenAccountingGas,
        uint48 _heldTokenAccountingGas,
        uint48 _facetAccountingGas,
        uint48 _newLimit
    ) external;

    /**
     * @notice Sets max slippage percent, callable by curator or owner through `submitActions` and timelocked
     * @param _newPercent New max slippage percent
     */
    function setMaxSlippagePercent(uint256 _newPercent) external;

    /**
     * @notice Sets cross chain accounting manager, callable by owner through `submitActions` and timelocked
     * @param manager New cross chain accounting manager
     */
    function setCrossChainAccountingManager(address manager) external;

    /**
     * @notice Get the current withdrawal fee
     * @return The current withdrawal fee in basis points
     */
    function getWithdrawalFee() external view returns (uint96);

    /**
     * @notice Get the current withdrawal queue status
     * @return The current withdrawal queue status
     */
    function getWithdrawalQueueStatus() external view returns (bool);

    /**
     * @notice Get the current max withdrawal delay
     * @return The current max withdrawal delay
     */
    function getMaxWithdrawalDelay() external view returns (uint32);
    
    /**
     * @notice Gets list of depositable assets
     * @return Array of depositable asset addresses
     */
    function getDepositableAssets() external view returns (address[] memory);

    /**
     * @notice Checks if asset is available
     * @param asset Asset address to check
     * @return true if asset is available
     */
    function isAssetAvailable(address asset) external view returns (bool);

    /**
     * @notice Checks if asset is depositable
     * @param asset Asset address to check
     * @return true if asset is depositable
     */
    function isAssetDepositable(address asset) external view returns (bool);

    /**
     * @notice Checks if deposit whitelist is enabled
     * @return true if deposit whitelist is enabled
     */
    function isDepositWhitelistEnabled() external view returns (bool);

    /**
     * @notice Checks if vault is hub
     * @return true if vault is hub
     */
    function isHub() external view returns (bool);

    /**
     * @notice Gets list of all available assets
     * @return Array of available asset addresses
     */
    function getAvailableAssets() external view returns (address[] memory);

    /**
     * @notice Gets fee amount
     * @return Fee amount
     */
    function fee() external view returns (uint96);

    /**
     * @notice Gets fee recipient address
     * @return Fee recipient address
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Gets deposit capacity
     * @return Deposit capacity
     */
    function depositCapacity() external view returns (uint256);

    /**
     * @notice Gets time lock period
     * @return Time lock period
     */
    function timeLockPeriod() external view returns (uint256);

    /// @notice Returns the withdrawal timelock duration
    /// @return duration The withdrawal timelock duration
    function getWithdrawalTimelock() external view returns (uint64);

    /// @notice Get the lockedTokens amount of an asset
    /// @param asset The asset to get the lockedTokens amount of
    /// @return The lockedTokens amount of the asset
    function lockedTokensAmountOfAsset(address asset) external view returns (uint256);

    /// @notice Get the staking addresses for a given staking facet
    /// @param stakingFacetId The staking facet to get the staking addresses of
    /// @return The staking addresses for the given staking facet
    function getStakingAddresses(bytes32 stakingFacetId) external view returns (address[] memory);

    /// @notice Returns array of tokens held in the vault based on their IDs
    /// @param tokenId token type ID
    /// @return array of token addresses
    function tokensHeld(bytes32 tokenId) external view returns (address[] memory);

    /// @notice Get the cross chain accounting manager
    /// @return The cross chain accounting manager
    function getCrossChainAccountingManager() external view returns (address);

    /// @notice Get the max slippage percent
    /// @return The max slippage percent
    function getMaxSlippagePercent() external view returns (uint256);
}
