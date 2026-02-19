//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

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
            / (uint128(safeTotalStake) * WEI_DECIMALS);

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

    function addMaximumPenalty(uint128 effectiveBalance, uint32 safeTotalStake, uint32 numberOfEpochs) internal pure returns (uint128 effectiveBalanceWithPenalty) {
        uint128 totalPenalty = slashing(effectiveBalance, safeTotalStake) + missingAttestations(effectiveBalance, safeTotalStake, numberOfEpochs);
        // Ensure penalty doesn't exceed balance (prevent underflow)
        if (totalPenalty >= effectiveBalance) {
            effectiveBalanceWithPenalty = 0;
        } else {
            effectiveBalanceWithPenalty = effectiveBalance - totalPenalty;
        }
    }

    // /// @notice Inverse of addMaximumPenalty: given the penalized balance, recover the original effectiveBalance
    // /// @dev Computes a closed-form quadratic estimate, then uses Newton's method to converge
    // ///      on the exact answer. The forward function has micro-non-monotonicity at the wei level
    // ///      due to integer floor division, so binary search is unreliable; Newton's method on
    // ///      the real-valued derivative converges in 2-3 iterations.
    // function removeMaximumPenalty(uint128 penalizedBalance, uint32 safeTotalStake, uint32 numberOfEpochs)
    //     internal
    //     pure
    //     returns (uint128)
    // {
    //     if (penalizedBalance == 0) return 0;

    //     // Step 1: Quadratic estimate
    //     uint128 guess = _quadraticEstimate(penalizedBalance, safeTotalStake, numberOfEpochs);

    //     // Step 2: Newton iteration on f(eb) = addMaximumPenalty(eb) - penalizedBalance = 0
    //     // f'(eb) ≈ K - 2*C*eb where K and C are the linear and quadratic penalty coefficients
    //     // We iterate: eb_new = eb - f(eb)/f'(eb)
    //     // Typically converges in 2-3 iterations.
    //     for (uint256 i = 0; i < 8; i++) {
    //         uint128 fwd = addMaximumPenalty(guess, safeTotalStake, numberOfEpochs);
    //         if (fwd == penalizedBalance) break;

    //         // f'(eb) ≈ 1 - 1/Q - B*(D+n)/sqrt(s*G) - 2*M*eb/(s*W)
    //         uint256 P = 1e18;
    //         uint256 sqrtSG = Math.sqrt(uint256(safeTotalStake) * GWEI_DECIMALS);
    //         uint256 deriv = P - P / INITIAL_SLASHING_PENALTY_QUOTIENT
    //             - uint256(BASE_REWARD) * (uint256(SLASHING_PENALTY_DURATION_IN_EPOCH) + numberOfEpochs) * P / sqrtSG
    //             - 2 * uint256(PROPORTIONAL_SLASHING_MULTIPLIER) * uint256(guess) * P / (uint256(safeTotalStake) * WEI_DECIMALS);

    //         if (deriv == 0) break;

    //         if (fwd < penalizedBalance) {
    //             uint256 diff = uint256(penalizedBalance) - fwd;
    //             guess += uint128(diff * P / deriv + 1);
    //         } else {
    //             uint256 diff = uint256(fwd) - penalizedBalance;
    //             uint128 adjustment = uint128(diff * P / deriv);
    //             guess = adjustment >= guess ? 0 : guess - adjustment;
    //         }
    //     }

    //     // Due to integer floor division in the forward function, multiple eb values
    //     // can map to the same penalized balance (non-monotonicity at wei level means
    //     // forward(eb) can jump down by several wei). We want the largest such eb.
    //     // Scan a small window upward from guess and keep the largest exact match.
    //     {
    //         uint128 best = guess;
    //         for (uint128 d = 1; d <= 8; d++) {
    //             if (addMaximumPenalty(guess + d, safeTotalStake, numberOfEpochs) == penalizedBalance) {
    //                 best = guess + d;
    //             }
    //         }
    //         guess = best;
    //     }

    //     return guess;
    // }

    // function _quadraticEstimate(uint128 penalizedBalance, uint32 safeTotalStake, uint32 numberOfEpochs)
    //     private
    //     pure
    //     returns (uint128)
    // {
    //     uint256 P = 1e36;

    //     uint256 a = Math.sqrt(uint256(safeTotalStake) * GWEI_DECIMALS);
    //     a = uint256(BASE_REWARD) * (uint256(SLASHING_PENALTY_DURATION_IN_EPOCH) + numberOfEpochs) * P / a;

    //     uint256 K_scaled = P - P / INITIAL_SLASHING_PENALTY_QUOTIENT - a;

    //     a = uint256(PROPORTIONAL_SLASHING_MULTIPLIER) * P / (uint256(safeTotalStake) * WEI_DECIMALS);

    //     uint256 disc = K_scaled * K_scaled - 4 * a * uint256(penalizedBalance);

    //     return uint128(2 * uint256(penalizedBalance) * P / (K_scaled + Math.sqrt(disc)));
    // }
}
