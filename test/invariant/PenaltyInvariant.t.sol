//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";

/// @title PenaltyWrapper
/// @notice Thin public wrapper over the Penalty library for stateful invariant testing.
///         Clamps inputs to realistic bounds and accumulates state for round-trip checks.
contract PenaltyWrapper {
    uint128 constant MAX_BALANCE = 2048 ether;
    uint32 constant MAX_EPOCHS = 4_106_250;

    uint128 public lastBalance;
    uint128 public lastPenalized;
    uint32 public lastStake;
    uint32 public lastEpochs;
    uint256 public roundTripFailures;

    function _clampBalance(uint128 eb) private pure returns (uint128) {
        return eb > MAX_BALANCE ? MAX_BALANCE : (eb == 0 ? 1 : eb);
    }

    function _clampStake(uint32 s) private pure returns (uint32) {
        return s == 0 ? 1 : s;
    }

    function _clampEpochs(uint32 n) private pure returns (uint32) {
        return n > MAX_EPOCHS ? MAX_EPOCHS : n;
    }

    function slashing(uint128 eb, uint32 s) public pure returns (uint128) {
        return Penalty.slashing(_clampBalance(eb), _clampStake(s));
    }

    function missingAttestations(uint128 eb, uint32 s, uint32 n) public pure returns (uint128) {
        return Penalty.missingAttestations(_clampBalance(eb), _clampStake(s), _clampEpochs(n));
    }

    // function addMaximumPenalty(uint128 eb, uint32 s, uint32 n) public returns (uint128) {
    //     eb = _clampBalance(eb);
    //     s = _clampStake(s);
    //     n = _clampEpochs(n);

    //     uint128 result = Penalty.addMaximumPenalty(eb, s, n);

    //     // Store state for round-trip invariant.
    //     // Only check when: non-saturating, reasonable stake, balance >= 1 ether,
    //     // and result >= 10% of balance (near-saturation makes inverse ill-conditioned)
    //     if (result > 0 && s >= 1_000_000 && eb >= 1 ether && result >= eb / 10) {
    //         lastBalance = eb;
    //         lastPenalized = result;
    //         lastStake = s;
    //         lastEpochs = n;

    //         // Verify round-trip immediately. Allow tolerance for Newton iteration
    //         // imprecision from integer floor division micro-non-monotonicity.
    //         try this.tryRemoveMaximumPenalty(result, s, n) returns (uint128 recovered) {
    //             uint128 diff = recovered > eb ? recovered - eb : eb - recovered;
    //             if (diff > 256) {
    //                 roundTripFailures++;
    //             }
    //         } catch {
    //             // removeMaximumPenalty reverted (arithmetic overflow) — count as failure
    //             roundTripFailures++;
    //         }
    //     }

    //     return result;
    // }

    // function tryRemoveMaximumPenalty(uint128 pb, uint32 s, uint32 n) external pure returns (uint128) {
    //     return Penalty.removeMaximumPenalty(pb, s, n);
    // }

    // function removeMaximumPenalty(uint128 pb, uint32 s, uint32 n) public pure returns (uint128) {
    //     return Penalty.removeMaximumPenalty(pb, _clampStake(s), _clampEpochs(n));
    // }
}

/// @title PenaltyInvariantTest
/// @notice Fuzz and invariant tests for the Penalty library
contract PenaltyInvariantTest is Test {
    PenaltyWrapper public wrapper;

    // Constants matching the library
    uint16 constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint8 constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint32 constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint8 constant BASE_REWARD = 40;
    uint64 constant WEI_DECIMALS = 1e18;
    uint64 constant GWEI_DECIMALS = 1e9;

    // Input bounds
    uint128 constant MAX_BALANCE = 2048 ether;
    uint32 constant MAX_EPOCHS = 4_106_250; // 50 years

    function setUp() public {
        wrapper = new PenaltyWrapper();
        targetContract(address(wrapper));
    }

    // ========================================
    // BOUND HELPERS
    // ========================================

    function _boundBalance(uint128 eb) internal pure returns (uint128) {
        return uint128(bound(uint256(eb), 1, MAX_BALANCE));
    }

    function _boundStake(uint32 s) internal pure returns (uint32) {
        return uint32(bound(uint256(s), 1, type(uint32).max));
    }

    function _boundEpochs(uint32 n) internal pure returns (uint32) {
        return uint32(bound(uint256(n), 0, MAX_EPOCHS));
    }

    // // ========================================
    // // FUZZ TEST #1: Round-trip — remove undoes add
    // // ========================================

    // function testFuzz_RoundTrip_RemoveUndoesAdd(uint128 eb, uint32 s, uint32 n) public pure {
    //     // Use minimum 1 ether to avoid arithmetic overflow in _quadraticEstimate for tiny balances
    //     eb = uint128(bound(uint256(eb), 1 ether, MAX_BALANCE));
    //     s = uint32(bound(uint256(s), 1_000_000, type(uint32).max));
    //     n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

    //     uint128 penalized = Penalty.addMaximumPenalty(eb, s, n);
    //     // Skip saturated (0) and near-saturated cases (< 10% of balance)
    //     // where the inverse is numerically ill-conditioned
    //     vm.assume(penalized >= eb / 10);

    //     uint128 recovered = Penalty.removeMaximumPenalty(penalized, s, n);
    //     // The Newton iteration + scan window in removeMaximumPenalty has imprecision
    //     // due to integer floor division micro-non-monotonicity in the forward function
    //     assertApproxEqAbs(recovered, eb, 256, "Round-trip: remove should approximately undo add");
    // }

    // ========================================
    // FUZZ TEST #2: addMaximumPenalty never exceeds balance
    // ========================================

    function testFuzz_AddMaximumPenalty_NeverExceedsBalance(uint128 eb, uint32 s, uint32 n) public pure {
        eb = uint128(bound(uint256(eb), 0, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

        uint128 result = Penalty.addMaximumPenalty(eb, s, n);
        assertLe(result, eb, "addMaximumPenalty result must never exceed input balance");
    }

    // ========================================
    // FUZZ TEST #3: slashing equals component sum
    // ========================================

    function testFuzz_Slashing_EqualsComponentSum(uint128 eb, uint32 s) public pure {
        eb = uint128(bound(uint256(eb), 0, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));

        uint128 totalSlashing = Penalty.slashing(eb, s);

        // Compute individual components (same formulas as library)
        uint128 initialPenalty = eb / INITIAL_SLASHING_PENALTY_QUOTIENT;

        uint256 correlationPenalty = uint256(eb) * eb * PROPORTIONAL_SLASHING_MULTIPLIER
            / (uint128(s) * WEI_DECIMALS);

        uint256 leakingPenalty =
            Penalty.missingAttestations(eb, s, SLASHING_PENALTY_DURATION_IN_EPOCH);

        // forge-lint: disable-next-line(unsafe-typecast) bounded by eb and s inputs
        uint128 expectedTotal = initialPenalty + uint128(correlationPenalty) + uint128(leakingPenalty);
        assertEq(totalSlashing, expectedTotal, "Slashing must equal sum of initial + correlation + leaking");
    }

    // ========================================
    // FUZZ TEST #4: slashing monotonic with balance
    // ========================================

    function testFuzz_Slashing_MonotonicWithBalance(uint128 eb1, uint128 eb2, uint32 s) public pure {
        eb1 = uint128(bound(uint256(eb1), 0, MAX_BALANCE));
        eb2 = uint128(bound(uint256(eb2), 0, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));

        if (eb1 > eb2) (eb1, eb2) = (eb2, eb1);

        uint128 penalty1 = Penalty.slashing(eb1, s);
        uint128 penalty2 = Penalty.slashing(eb2, s);
        assertLe(penalty1, penalty2, "Slashing must be monotonically increasing with balance");
    }

    // ========================================
    // FUZZ TEST #5: slashing anti-monotonic with stake
    // ========================================

    function testFuzz_Slashing_AntiMonotonicWithStake(uint128 eb, uint32 s1, uint32 s2) public pure {
        eb = uint128(bound(uint256(eb), 0, MAX_BALANCE));
        s1 = uint32(bound(uint256(s1), 1, type(uint32).max));
        s2 = uint32(bound(uint256(s2), 1, type(uint32).max));

        if (s1 > s2) (s1, s2) = (s2, s1);

        uint128 penalty1 = Penalty.slashing(eb, s1);
        uint128 penalty2 = Penalty.slashing(eb, s2);
        assertGe(penalty1, penalty2, "Slashing must be anti-monotonic with stake (higher stake -> lower penalty)");
    }

    // ========================================
    // FUZZ TEST #6: missingAttestations linear with epochs
    // ========================================

    function testFuzz_MissingAttestations_LinearWithEpochs(uint128 eb, uint32 s, uint32 n1, uint32 n2) public pure {
        eb = uint128(bound(uint256(eb), 1, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        // Bound so n1 + n2 doesn't exceed MAX_EPOCHS
        n1 = uint32(bound(uint256(n1), 0, MAX_EPOCHS / 2));
        n2 = uint32(bound(uint256(n2), 0, MAX_EPOCHS / 2));

        uint128 combined = Penalty.missingAttestations(eb, s, n1 + n2);
        uint128 separate1 = Penalty.missingAttestations(eb, s, n1);
        uint128 separate2 = Penalty.missingAttestations(eb, s, n2);

        // Due to integer floor division, attest(n1+n2) may differ from attest(n1)+attest(n2) by at most 1 wei
        uint128 separateSum = separate1 + separate2;
        assertApproxEqAbs(combined, separateSum, 1, "missingAttestations should be linear with epochs (+-1 wei)");
    }

    // ========================================
    // FUZZ TEST #7: zero balance => zero penalty
    // ========================================

    function testFuzz_ZeroBalance_ZeroPenalty(uint32 s, uint32 n) public pure {
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

        assertEq(Penalty.slashing(0, s), 0, "slashing(0, s) must be 0");
        assertEq(Penalty.missingAttestations(0, s, n), 0, "missingAttestations(0, s, n) must be 0");
        assertEq(Penalty.addMaximumPenalty(0, s, n), 0, "addMaximumPenalty(0, s, n) must be 0");
    }

    // ========================================
    // FUZZ TEST #8: zero epochs => zero attestation penalty
    // ========================================

    function testFuzz_ZeroEpochs_ZeroAttestationPenalty(uint128 eb, uint32 s) public pure {
        eb = uint128(bound(uint256(eb), 0, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));

        assertEq(
            Penalty.missingAttestations(eb, s, 0),
            0,
            "missingAttestations with 0 epochs must return 0"
        );
    }

    // ========================================
    // FUZZ TEST #9: addMaximumPenalty monotonic with epochs
    // ========================================

    function testFuzz_AddMaximumPenalty_MonotonicWithEpochs(uint128 eb, uint32 s, uint32 n1, uint32 n2) public pure {
        eb = uint128(bound(uint256(eb), 1, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        n1 = uint32(bound(uint256(n1), 0, MAX_EPOCHS));
        n2 = uint32(bound(uint256(n2), 0, MAX_EPOCHS));

        if (n1 > n2) (n1, n2) = (n2, n1);

        uint128 result1 = Penalty.addMaximumPenalty(eb, s, n1);
        uint128 result2 = Penalty.addMaximumPenalty(eb, s, n2);

        // More epochs => more penalty => lower or equal remaining balance
        assertGe(result1, result2, "addMaximumPenalty: more epochs must yield lower or equal remaining balance");
    }

    // // ========================================
    // // FUZZ TEST #10: removeMaximumPenalty(0) == 0
    // // ========================================

    // function testFuzz_RemoveMaximumPenalty_ZeroInput(uint32 s, uint32 n) public pure {
    //     s = uint32(bound(uint256(s), 1, type(uint32).max));
    //     n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

    //     assertEq(
    //         Penalty.removeMaximumPenalty(0, s, n),
    //         0,
    //         "removeMaximumPenalty(0, s, n) must return 0"
    //     );
    // }

    // ========================================
    // FUZZ TEST #11: addMaximumPenalty saturates to zero
    // ========================================

    function testFuzz_AddMaximumPenalty_SaturationToZero(uint128 eb, uint32 s, uint32 n) public pure {
        eb = uint128(bound(uint256(eb), 1, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

        uint128 result = Penalty.addMaximumPenalty(eb, s, n);

        // Compute total penalty
        uint128 slashPenalty = Penalty.slashing(eb, s);
        uint128 attestPenalty = Penalty.missingAttestations(eb, s, n);
        uint128 totalPenalty = slashPenalty + attestPenalty;

        if (totalPenalty >= eb) {
            assertEq(result, 0, "When total penalty >= balance, result must be 0");
        } else {
            assertEq(result, eb - totalPenalty, "When penalty < balance, result must be balance - penalty");
        }
    }

    // ========================================
    // FUZZ TEST #12: addMaximumPenalty matches decomposition
    // ========================================

    function testFuzz_AddMaximumPenalty_MatchesDecomposition(uint128 eb, uint32 s, uint32 n) public pure {
        eb = uint128(bound(uint256(eb), 1, MAX_BALANCE));
        s = uint32(bound(uint256(s), 1, type(uint32).max));
        n = uint32(bound(uint256(n), 0, MAX_EPOCHS));

        uint128 result = Penalty.addMaximumPenalty(eb, s, n);

        // Decompose: addMaximumPenalty = eb - slashing(eb) - missingAttestations(eb, s, n), clamped to 0
        uint128 slashPenalty = Penalty.slashing(eb, s);
        uint128 attestPenalty = Penalty.missingAttestations(eb, s, n);
        uint128 totalPenalty = slashPenalty + attestPenalty;

        uint128 expected = totalPenalty >= eb ? 0 : eb - totalPenalty;
        assertEq(result, expected, "addMaximumPenalty must match eb - slashing - attestation (clamped)");
    }

    // ========================================
    // FUZZ TEST #13: correlation penalty quadratic scaling
    // ========================================

    function testFuzz_CorrelationPenalty_QuadraticScaling(uint128 eb, uint32 s) public pure {
        // Bound eb so that 2*eb doesn't exceed MAX_BALANCE
        eb = uint128(bound(uint256(eb), 1, MAX_BALANCE / 2));
        s = uint32(bound(uint256(s), 1, type(uint32).max));

        uint256 corr1 = uint256(eb) * eb * PROPORTIONAL_SLASHING_MULTIPLIER
            / (uint128(s) * WEI_DECIMALS);

        uint128 eb2 = eb * 2;
        uint256 corr2 = uint256(eb2) * eb2 * PROPORTIONAL_SLASHING_MULTIPLIER
            / (uint128(s) * WEI_DECIMALS);

        // corr(2*eb) should be 4 * corr(eb), with tolerance for integer floor division
        // 4 * corr1 may differ from corr2 by up to 4 wei due to independent floor divisions
        // forge-lint: disable-next-line(unsafe-typecast) test helper, bounded by inputs
        uint128 corr2Casted = uint128(corr2);
        // forge-lint: disable-next-line(unsafe-typecast) test helper, bounded by inputs
        uint128 corr1x4Casted = uint128(corr1 * 4);
        assertApproxEqAbs(
            corr2Casted,
            corr1x4Casted,
            4,
            "Doubling balance should quadruple correlation penalty (+-4 wei)"
        );
    }

    // // ========================================
    // // STATEFUL INVARIANT: round-trip never fails
    // // ========================================

    // /// @notice Foundry calls PenaltyWrapper's 4 public functions randomly.
    // ///         After each sequence, we check that no round-trip failures accumulated.
    // function invariant_RoundTripNeverFails() public view {
    //     assertEq(wrapper.roundTripFailures(), 0, "Round-trip invariant: no failures should accumulate");
    // }
}
