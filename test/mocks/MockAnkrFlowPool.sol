// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAnkrFlowStakingPool} from "../../src/interfaces/external/ankr/IAnkrFlowStakingPool.sol";
import {IAnkrCertificateToken} from "../../src/interfaces/external/ankr/IAnkrCertificateToken.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAnkrCertificateToken is ERC20, IAnkrCertificateToken {
    uint256 public ratio = 1e18;

    constructor() ERC20("ankrFLOW", "ankrFLOW") {}

    function setRatio(uint256 newRatio) external {
        ratio = newRatio;
    }

    function sharesToBonds(uint256 shares) external view returns (uint256) {
        return (shares * ratio) / 1e18;
    }

    function bondsToShares(uint256 bonds) external view returns (uint256) {
        return (bonds * 1e18) / ratio;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAnkrFlowPool is IAnkrFlowStakingPool {
    error NothingToClaim();
    error TransferFailed();
    error InsufficientPending();

    address public bearingToken;
    address public certificateToken;

    uint256 public totalPending;
    mapping(address => uint256) public pendingUnstakesOf;
    mapping(address => uint256) public manualClaimsOf;
    mapping(address => uint256[]) internal pendingRequests;

    constructor(address _bearingToken, address _certificateToken) {
        bearingToken = _bearingToken;
        certificateToken = _certificateToken;
    }

    receive() external payable {}

    function stakeCerts() external payable {
        uint256 shares = IAnkrCertificateToken(certificateToken).bondsToShares(msg.value);
        MockAnkrCertificateToken(certificateToken).mint(msg.sender, shares);
    }

    function unstakeCerts(uint256 shares) external {
        uint256 bonds = IAnkrCertificateToken(certificateToken).sharesToBonds(shares);
        MockAnkrCertificateToken(certificateToken).burn(msg.sender, shares);
        pendingUnstakesOf[msg.sender] += bonds;
        totalPending += bonds;
        pendingRequests[msg.sender].push(bonds);
    }

    function claimManually(address receiverAddress) external {
        uint256 amount = manualClaimsOf[receiverAddress];
        if (amount == 0) revert NothingToClaim();
        manualClaimsOf[receiverAddress] = 0;
        (bool success,) = receiverAddress.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function getTokens() external view returns (address, address) {
        return (bearingToken, certificateToken);
    }

    function getPendingRequestsOf(address claimer) external view returns (uint256[] memory) {
        return pendingRequests[claimer];
    }

    function getPendingUnstakesOf(address claimer) external view returns (uint256) {
        return pendingUnstakesOf[claimer];
    }

    function getForManualClaimOf(address claimer) external view returns (uint256) {
        return manualClaimsOf[claimer];
    }

    function isMarkedForManualClaim(address claimer) external view returns (bool) {
        return manualClaimsOf[claimer] > 0;
    }

    function settlePending(address claimer, uint256 bonds, bool toManual) external {
        if (pendingUnstakesOf[claimer] < bonds) revert InsufficientPending();
        pendingUnstakesOf[claimer] -= bonds;
        totalPending -= bonds;
        _removeFirstPendingRequest(claimer, bonds);

        if (toManual) {
            manualClaimsOf[claimer] += bonds;
            return;
        }

        (bool success,) = claimer.call{value: bonds}("");
        if (!success) revert TransferFailed();
    }

    function _removeFirstPendingRequest(address claimer, uint256 bonds) private {
        uint256[] storage requests = pendingRequests[claimer];
        for (uint256 i; i < requests.length;) {
            if (requests[i] == bonds) {
                requests[i] = requests[requests.length - 1];
                requests.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }
}
