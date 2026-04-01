// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultFacet} from "../interfaces/facets/IVaultFacet.sol";

/// @title MoreVaultMigrator
/// @notice Migrates a user's position from one mono-chain MoreVault to another using the withdrawal queue request on the old vault.
/// @dev Flow:
///      1) User creates a withdrawal request on the old vault
///      2) User approves this migrator to spend their old vault shares (ERC20 allowance on the share token = old vault address)
///      3) After timelock, curator finalizes: redeem from old vault (using allowance) into this contract, then deposit into new vault for user.
contract MoreVaultMigrator is Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotCurator();
    error AssetMismatch(address oldAsset, address newAsset);
    error NothingToMigrate();
    error SlippageExceeded(uint256 actualShares, uint256 minShares);
    error MigratorNotEligibleForDeposit(address migrator, uint256 assetsToDeposit, uint256 maxAllowed);
    error UserNotEligibleForDeposit(address user, uint256 assetsToDeposit, uint256 maxAllowed);

    event CuratorSet(address indexed previousCurator, address indexed newCurator);
    event MigrationFinalized(
        address indexed user,
        uint256 sharesRedeemed,
        uint256 assetsReceived,
        uint256 newSharesMinted
    );

    IVaultFacet public immutable oldVault;
    IVaultFacet public immutable newVault;
    address public curator;

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    constructor(address _oldVault, address _newVault, address _owner, address _curator) Ownable(_owner) {
        if (_oldVault == address(0) || _newVault == address(0) || _owner == address(0) || _curator == address(0)) {
            revert ZeroAddress();
        }
        oldVault = IVaultFacet(_oldVault);
        newVault = IVaultFacet(_newVault);
        curator = _curator;
        emit CuratorSet(address(0), _curator);

        address oldAsset = oldVault.asset();
        address newAsset = newVault.asset();
        if (oldAsset != newAsset) revert AssetMismatch(oldAsset, newAsset);
    }

    /// @notice Update curator address.
    /// @dev Owner-controlled; typically set to the vault curator/multisig.
    function setCurator(address _newCurator) external onlyOwner {
        if (_newCurator == address(0)) revert ZeroAddress();
        address prev = curator;
        curator = _newCurator;
        emit CuratorSet(prev, _newCurator);
    }

    /// @notice Finalize migration for a user.
    /// @param user User who has active withdrawal request on old vault
    /// @param sharesRequested Shares to migrate; use 0 to migrate max possible by request/allowance/balance
    /// @param minNewShares Minimum shares expected from depositing into the new vault (slippage protection)
    /// @return sharesMigrated Shares actually redeemed from the old vault
    /// @return assetsReceived Underlying assets received from the old vault
    /// @return newSharesMinted Shares minted by the new vault to the user
    function finalizeMigration(address user, uint256 sharesRequested, uint256 minNewShares)
        external
        onlyCurator
        returns (uint256 sharesMigrated, uint256 assetsReceived, uint256 newSharesMinted)
    {
        if (user == address(0)) revert ZeroAddress();

        // Bound by user's matured request, allowance to migrator, and user balance.
        (uint256 reqShares,) = oldVault.getWithdrawalRequest(user);
        uint256 allowanceShares = IERC20(address(oldVault)).allowance(user, address(this));
        uint256 balanceShares = IERC20(address(oldVault)).balanceOf(user);

        uint256 target = sharesRequested == 0 ? reqShares : sharesRequested;
        sharesMigrated = _min4(target, reqShares, allowanceShares, balanceShares);
        if (sharesMigrated == 0) revert NothingToMigrate();

        // Pre-checks BEFORE redeem: verify both the user and this migrator are eligible to deposit
        // into the new vault. Both checks run before any shares are burned, so a revert here
        // preserves the user's withdrawal request on the old vault.
        //
        // Hub vaults are always ERC4626-compatible; maxDeposit never reverts for them.
        //
        // Check order:
        //   1. User check: closes the backdoor where a non-whitelisted user could end up in a
        //      whitelisted vault simply because the migrator was whitelisted.
        //   2. Migrator check: VaultFacet._validateCapacity uses msg.sender (= this contract) for
        //      the actual deposit, so the migrator must also have sufficient whitelist allocation.
        uint256 assetsToDeposit = oldVault.previewRedeem(sharesMigrated);

        uint256 maxUserDeposit = newVault.maxDeposit(user);
        if (maxUserDeposit < assetsToDeposit) {
            revert UserNotEligibleForDeposit(user, assetsToDeposit, maxUserDeposit);
        }

        uint256 maxMigratorDeposit = newVault.maxDeposit(address(this));
        if (maxMigratorDeposit < assetsToDeposit) {
            revert MigratorNotEligibleForDeposit(address(this), assetsToDeposit, maxMigratorDeposit);
        }

        // Redeem from old vault into this contract, burning user's shares via allowance.
        assetsReceived = oldVault.redeem(sharesMigrated, address(this), user);

        // Deposit into new vault for user.
        IERC20 assetToken = IERC20(oldVault.asset());
        assetToken.forceApprove(address(newVault), assetsReceived);
        newSharesMinted = newVault.deposit(assetsReceived, user);

        if (newSharesMinted < minNewShares) revert SlippageExceeded(newSharesMinted, minNewShares);

        emit MigrationFinalized(user, sharesMigrated, assetsReceived, newSharesMinted);
    }

    /// @notice Rescue any ERC20 mistakenly sent to this contract (NOT the old vault shares during an active migration).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function _min4(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256) {
        uint256 m = a < b ? a : b;
        m = m < c ? m : c;
        return m < d ? m : d;
    }
}



