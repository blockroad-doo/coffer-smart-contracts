//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library Penalty {
    uint16 constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint8 constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint32 constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint8 constant BASE_REWARD = 40;
    uint64 constant WEI_DECIMALS = 1e18;
    uint64 constant GWEI_DECIMALS = 1e9;

    /// @param effectiveBalance is represented in wei -> maximum is 340.282.366.920.938.463.463,374607431768211456 ETH
    /// @param safeTotalStake is represented in ETH -> maximum is 4.294.967.296 ETH
    /// @dev this could theoretically overflow, but it wont since balance is manipulated with eth, e.g. msg.value only
    function slashing(uint128 effectiveBalance, uint32 safeTotalStake) internal pure returns (uint128) {
        ///penalty which validator recives when slashing occurs
        uint128 initialPenalty = effectiveBalance / INITIAL_SLASHING_PENALTY_QUOTIENT;

        uint256 correlationPenalty = uint256(effectiveBalance) * effectiveBalance * PROPORTIONAL_SLASHING_MULTIPLIER
            / uint128(safeTotalStake) * WEI_DECIMALS;

        uint256 leakingPenalty =
            missingAttestations(effectiveBalance, safeTotalStake, SLASHING_PENALTY_DURATION_IN_EPOCH);

        return initialPenalty + uint128(correlationPenalty) + uint128(leakingPenalty);
    }

    function missingAttestations(uint128 effectiveBalance, uint32 safeTotalStake, uint32 numberOfEpochs)
        internal
        pure
        returns (uint128)
    {
        uint256 returnValue =
            effectiveBalance * BASE_REWARD * numberOfEpochs / Math.sqrt(safeTotalStake * GWEI_DECIMALS);
        return uint128(returnValue);
    }
}
