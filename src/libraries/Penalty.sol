//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Penalty
/// @author Blockroad Ltd
/// @notice Library for calculating validator penalties (slashing and missing attestations)
/// @notice Penalty input is balance, not effective_balance. The Ethereum consensus-spec slashing formulas take
/// effective_balance as their formal input. This library is a faithful implementation of those formulas, but the
/// protocol passes the validator's actual balance. Main reason is flooring would discard up to 1 ETH per
/// provisioning call of real consensus collateral. For example: three 1.4 ETH top-ups would back bonds against
/// only 3 ETH instead of 4 ETH. Since balance >= effective_balance, the estimate produced here is at most slightly
/// over-conservative versus the spec value. The direction is strictly holder-favorable.
library Penalty {
    /// @dev Snapshots Ethereum consensus spec MIN_SLASHING_PENALTY_QUOTIENT
    ///      (post-Electra value, 4096). Historical forks have changed this parameter.
    ///      See README "Risk Factors" for fork-risk disclosure.
    uint256 internal constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;

    /// @dev Snapshots Ethereum consensus spec PROPORTIONAL_SLASHING_MULTIPLIER.
    ///      Historical values: 1 (Phase 0), 2 (Altair), 3 (Bellatrix and later).
    ///      See README "Risk Factors" for fork-risk disclosure.
    uint256 internal constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;

    /// @dev Snapshots Ethereum consensus spec EPOCHS_PER_SLASHINGS_VECTOR
    ///      (8192 epochs, approximately 36 days). See README "Risk Factors" for fork-risk disclosure.
    uint256 internal constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;

    /// @dev Sum of penalty-bearing attestation flag weights from Ethereum consensus spec:
    ///      TIMELY_SOURCE_WEIGHT (14) + TIMELY_TARGET_WEIGHT (26) = 40.
    ///      TIMELY_HEAD is not penalized on miss (per get_flag_index_deltas).
    ///      BASE_REWARD_FACTOR (64) and WEIGHT_DENOMINATOR (64) cancel in closed form.
    ///      See README "Risk Factors" for fork-risk disclosure.
    uint256 internal constant MISSED_ATTESTATION_FACTOR = 40;
    uint256 internal constant WEI_DECIMALS = 1e18;
    uint256 internal constant GWEI_DECIMALS = 1e9;

    /// @notice Calculates total slashing penalty for a validator
    /// @notice The correlation-penalty term assumes this validator is the sole slashed validator within the
    /// SLASHING_PENALTY_DURATION_IN_EPOCH window (currently 8192 epochs, roughly 36 days). In a large correlated
    /// slashing event the true consensus-layer penalty saturates at the full effective balance, so the value
    /// returned here is an underestimate and issueSize provisioned against it can sit above the validator's actual
    /// post-penalty balance. See README "Risk Factors" for correlated-slashing disclosure.
    /// @param balance Represented in wei.
    /// @param safeTotalStake Safe total network stake for penalty calculation
    /// @return Total slashing penalty amount
    function slashing(uint256 balance, uint256 safeTotalStake) internal pure returns (uint256) {
        /// Penalty which the validator receives when slashing occurs
        uint256 initialPenalty = balance / INITIAL_SLASHING_PENALTY_QUOTIENT;

        uint256 correlationPenalty =
            balance * balance * PROPORTIONAL_SLASHING_MULTIPLIER / (safeTotalStake * WEI_DECIMALS);

        uint256 leakingPenalty = missingAttestations(balance, safeTotalStake, SLASHING_PENALTY_DURATION_IN_EPOCH);

        return initialPenalty + correlationPenalty + leakingPenalty;
    }

    /// @notice This function calculates penalties for missing attestations
    /// @param balance The validator's balance which is penalized
    /// @param safeTotalStake The total network stake used to calculate penalties
    /// @param numberOfEpochs The total period during which the validator is not performing attestations
    /// @return Penalty amount for missing attestations
    function missingAttestations(uint256 balance, uint256 safeTotalStake, uint256 numberOfEpochs)
        internal
        pure
        returns (uint256)
    {
        uint256 denominator = Math.sqrt(safeTotalStake * GWEI_DECIMALS);
        return balance * MISSED_ATTESTATION_FACTOR * numberOfEpochs / denominator;
    }

    /// @notice This function calculates the maximum possible penalty
    /// that a validator can get in a certain period.
    /// @notice Calculates for an extreme situation for holder safety.
    /// Adds up penalties over numberOfEpochs plus the maximum slashing penalty.
    /// Attestation penalties are summed (not maxed) because the worst case is a
    /// slash at bond end, where the 8192-epoch penalty period extends beyond
    /// maturity with no overlap.
    /// @param balance The validator's balance to compute the maximum penalty against
    /// @param safeTotalStake The safe total stake used for penalty calculation
    /// @param numberOfEpochs The number of epochs for penalty calculation
    /// @return balanceWithPenalty The balance after subtracting penalties
    function addMaximumPenalty(uint256 balance, uint256 safeTotalStake, uint256 numberOfEpochs)
        internal
        pure
        returns (uint256 balanceWithPenalty)
    {
        uint256 totalPenalty =
            slashing(balance, safeTotalStake) + missingAttestations(balance, safeTotalStake, numberOfEpochs);
        // Ensure penalty doesn't exceed balance (prevent underflow)
        // solhint-disable-next-line gas-strict-inequalities
        if (totalPenalty >= balance) {
            balanceWithPenalty = 0;
        } else {
            balanceWithPenalty = balance - totalPenalty;
        }
    }
}
