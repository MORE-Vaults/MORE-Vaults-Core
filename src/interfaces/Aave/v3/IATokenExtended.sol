// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import {IAToken} from "@aave-v3-core/contracts/interfaces/IAToken.sol";

interface IATokenExtended is IAToken {
    function POOL() external view returns (address);

    function getIncentivesController() external view returns (address);
}
