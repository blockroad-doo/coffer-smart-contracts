//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Penalty
/// @author Coffer Team
/// @notice Library for calculating validator penalties (slashing and missing attestations)
library Penalty {
    uint256 internal constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint256 internal constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint256 internal constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint256 internal constant BASE_REWARD = 40;
    uint256 internal constant WEI_DECIMALS = 1e18;
    uint256 internal constant GWEI_DECIMALS = 1e9;

    /// @notice Calculates total slashing penalty for a validator
    /// @param effectiveBalance is represented in wei -> maximum is 340.282.366.920.938.463.463,374607431768211456 ETH
    /// @param safeTotalStake is represented in ETH -> maximum is 4.294.967.296 ETH
    /// @return Total slashing penalty amount
    /// @dev this could theoretically overflow, but it won't since balance is manipulated with eth, e.g. msg.value only
    function slashing(uint256 effectiveBalance, uint256 safeTotalStake) internal pure returns (uint256) {
        ///penalty which validator receives when slashing occurs
        uint256 initialPenalty = effectiveBalance / INITIAL_SLASHING_PENALTY_QUOTIENT;

        uint256 correlationPenalty =
            effectiveBalance * effectiveBalance * PROPORTIONAL_SLASHING_MULTIPLIER / (safeTotalStake * WEI_DECIMALS);

        uint256 leakingPenalty =
            missingAttestations(effectiveBalance, safeTotalStake, SLASHING_PENALTY_DURATION_IN_EPOCH);

        return initialPenalty + correlationPenalty + leakingPenalty;
    }

    /// @notice this function calculates penalties for missing attestations
    /// @param effectiveBalance validators balance which is penalized
    /// @param safeTotalStake total network stake we take in order to be able to calculate penalties
    /// @param numberOfEpochs total period of validator not performing attestations
    /// @return Penalty amount for missing attestations
    function missingAttestations(uint256 effectiveBalance, uint256 safeTotalStake, uint256 numberOfEpochs)
        internal
        pure
        returns (uint256)
    {
        return effectiveBalance * BASE_REWARD * numberOfEpochs / Math.sqrt(safeTotalStake * GWEI_DECIMALS);
    }

    /// @notice This is the function which calculates maximal possible penalty
    /// that validator can get in certain period.
    /// @notice Calculates very extreme situation for holder safety.
    /// Adds up penalties in numberOfEpochs plus maximal slashing penalty.
    /// @param effectiveBalance The effective balance of the validator
    /// @param safeTotalStake The safe total stake used for penalty calculation
    /// @param numberOfEpochs The number of epochs for penalty calculation
    /// @return effectiveBalanceWithPenalty The balance after subtracting penalties
    function addMaximumPenalty(uint256 effectiveBalance, uint256 safeTotalStake, uint256 numberOfEpochs)
        internal
        pure
        returns (uint256 effectiveBalanceWithPenalty)
    {
        uint256 totalPenalty = slashing(effectiveBalance, safeTotalStake)
            + missingAttestations(effectiveBalance, safeTotalStake, numberOfEpochs);
        // Ensure penalty doesn't exceed balance (prevent underflow)
        // solhint-disable-next-line gas-strict-inequalities
        if (totalPenalty >= effectiveBalance) {
            effectiveBalanceWithPenalty = 0;
        } else {
            effectiveBalanceWithPenalty = effectiveBalance - totalPenalty;
        }
    }
}
