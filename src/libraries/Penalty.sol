//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Penalty
/// @author Blockroad Ltd
/// @notice Library for calculating validator penalties (slashing and missing attestations)
library Penalty {
    uint256 internal constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint256 internal constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint256 internal constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint256 internal constant BASE_REWARD = 40;
    uint256 internal constant WEI_DECIMALS = 1e18;
    uint256 internal constant GWEI_DECIMALS = 1e9;

    /// @notice Calculates total slashing penalty for a validator
    /// @param effectiveBalance Represented in wei.
    /// @param safeTotalStake Represented in ETH.
    /// @return Total slashing penalty amount
    /// @dev This could theoretically overflow, but it won't since the balance is set via msg.value only
    function slashing(uint256 effectiveBalance, uint256 safeTotalStake) internal pure returns (uint256) {
        /// Penalty which the validator receives when slashing occurs
        uint256 initialPenalty = effectiveBalance / INITIAL_SLASHING_PENALTY_QUOTIENT;

        uint256 correlationPenalty =
            effectiveBalance * effectiveBalance * PROPORTIONAL_SLASHING_MULTIPLIER / (safeTotalStake * WEI_DECIMALS);

        uint256 leakingPenalty =
            missingAttestations(effectiveBalance, safeTotalStake, SLASHING_PENALTY_DURATION_IN_EPOCH);

        return initialPenalty + correlationPenalty + leakingPenalty;
    }

    /// @notice This function calculates penalties for missing attestations
    /// @param effectiveBalance The validator's balance which is penalized
    /// @param safeTotalStake The total network stake used to calculate penalties
    /// @param numberOfEpochs The total period during which the validator is not performing attestations
    /// @return Penalty amount for missing attestations
    function missingAttestations(uint256 effectiveBalance, uint256 safeTotalStake, uint256 numberOfEpochs)
        internal
        pure
        returns (uint256)
    {
        return effectiveBalance * BASE_REWARD * numberOfEpochs / Math.sqrt(safeTotalStake * GWEI_DECIMALS);
    }

    /// @notice This function calculates the maximum possible penalty
    /// that a validator can get in a certain period.
    /// @notice Calculates for an extreme situation for holder safety.
    /// Adds up penalties over numberOfEpochs plus the maximum slashing penalty.
    /// Attestation penalties are summed (not maxed) because the worst case is a
    /// slash at bond end, where the 8192-epoch penalty period extends beyond
    /// maturity with no overlap.
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
