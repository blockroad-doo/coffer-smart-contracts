//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Interest} from "../../src/libraries/Interest.sol";

/// @title InterestInvariantTest
/// @notice Fuzz and invariant tests for the Interest library
contract InterestInvariantTest is Test {
    // Constants matching the library
    uint256 constant MAX_RATE_BPS = 1e8; // 100%
    uint256 constant SECONDS_IN_YEAR = 31_536_000;

    // Realistic input bounds
    uint256 constant MAX_AMOUNT = 2048 ether;
    uint256 constant MAX_DURATION = 1_576_800_000; // 50 years

    // ========================================
    // BOUND HELPERS
    // ========================================

    function _boundAmount(uint256 a) internal pure returns (uint256) {
        return bound(a, 0, MAX_AMOUNT);
    }

    function _boundDuration(uint256 d) internal pure returns (uint256) {
        return bound(d, 0, MAX_DURATION);
    }

    function _boundRate(uint256 r) internal pure returns (uint256) {
        return bound(r, 0, MAX_RATE_BPS);
    }

    // ========================================
    // FUZZ TEST #1: zero amount => zero interest
    // ========================================

    function testFuzz_ZeroAmount_ZeroInterest(uint256 d, uint256 r) public pure {
        d = _boundDuration(d);
        r = _boundRate(r);
        assertEq(Interest.calculateInterest(0, d, r), 0, "Zero amount must yield zero interest");
    }

    // ========================================
    // FUZZ TEST #2: zero duration => zero interest
    // ========================================

    function testFuzz_ZeroDuration_ZeroInterest(uint256 a, uint256 r) public pure {
        a = _boundAmount(a);
        r = _boundRate(r);
        assertEq(Interest.calculateInterest(a, 0, r), 0, "Zero duration must yield zero interest");
    }

    // ========================================
    // FUZZ TEST #3: zero rate => zero interest
    // ========================================

    function testFuzz_ZeroRate_ZeroInterest(uint256 a, uint256 d) public pure {
        a = _boundAmount(a);
        d = _boundDuration(d);
        assertEq(Interest.calculateInterest(a, d, 0), 0, "Zero rate must yield zero interest");
    }

    // ========================================
    // FUZZ TEST #4: interest monotonic with amount
    // ========================================

    function testFuzz_MonotonicWithAmount(uint256 a1, uint256 a2, uint256 d, uint256 r) public pure {
        a1 = _boundAmount(a1);
        a2 = _boundAmount(a2);
        d = _boundDuration(d);
        r = _boundRate(r);

        if (a1 > a2) (a1, a2) = (a2, a1);

        uint256 i1 = Interest.calculateInterest(a1, d, r);
        uint256 i2 = Interest.calculateInterest(a2, d, r);
        assertLe(i1, i2, "Interest must be monotonically increasing with amount");
    }

    // ========================================
    // FUZZ TEST #5: interest monotonic with duration
    // ========================================

    function testFuzz_MonotonicWithDuration(uint256 a, uint256 d1, uint256 d2, uint256 r) public pure {
        a = _boundAmount(a);
        d1 = _boundDuration(d1);
        d2 = _boundDuration(d2);
        r = _boundRate(r);

        if (d1 > d2) (d1, d2) = (d2, d1);

        uint256 i1 = Interest.calculateInterest(a, d1, r);
        uint256 i2 = Interest.calculateInterest(a, d2, r);
        assertLe(i1, i2, "Interest must be monotonically increasing with duration");
    }

    // ========================================
    // FUZZ TEST #6: interest monotonic with rate
    // ========================================

    function testFuzz_MonotonicWithRate(uint256 a, uint256 d, uint256 r1, uint256 r2) public pure {
        a = _boundAmount(a);
        d = _boundDuration(d);
        r1 = _boundRate(r1);
        r2 = _boundRate(r2);

        if (r1 > r2) (r1, r2) = (r2, r1);

        uint256 i1 = Interest.calculateInterest(a, d, r1);
        uint256 i2 = Interest.calculateInterest(a, d, r2);
        assertLe(i1, i2, "Interest must be monotonically increasing with rate");
    }

    // ========================================
    // FUZZ TEST #7: linearity in amount
    // ========================================

    function testFuzz_LinearWithAmount(uint256 a1, uint256 a2, uint256 d, uint256 r) public pure {
        // Bound so a1 + a2 <= MAX_AMOUNT
        a1 = bound(a1, 0, MAX_AMOUNT / 2);
        a2 = bound(a2, 0, MAX_AMOUNT / 2);
        d = _boundDuration(d);
        r = _boundRate(r);

        uint256 combined = Interest.calculateInterest(a1 + a2, d, r);
        uint256 separate1 = Interest.calculateInterest(a1, d, r);
        uint256 separate2 = Interest.calculateInterest(a2, d, r);

        // Floor division on each RHS term may drop up to 1 wei; combined error <= 2 wei.
        assertApproxEqAbs(combined, separate1 + separate2, 2, "Interest must be linear in amount (+-2 wei)");
    }

    // ========================================
    // FUZZ TEST #8: linearity in duration
    // ========================================

    function testFuzz_LinearWithDuration(uint256 a, uint256 d1, uint256 d2, uint256 r) public pure {
        a = _boundAmount(a);
        d1 = bound(d1, 0, MAX_DURATION / 2);
        d2 = bound(d2, 0, MAX_DURATION / 2);
        r = _boundRate(r);

        uint256 combined = Interest.calculateInterest(a, d1 + d2, r);
        uint256 separate1 = Interest.calculateInterest(a, d1, r);
        uint256 separate2 = Interest.calculateInterest(a, d2, r);

        assertApproxEqAbs(combined, separate1 + separate2, 2, "Interest must be linear in duration (+-2 wei)");
    }

    // ========================================
    // FUZZ TEST #9: linearity in rate
    // ========================================

    function testFuzz_LinearWithRate(uint256 a, uint256 d, uint256 r1, uint256 r2) public pure {
        a = _boundAmount(a);
        d = _boundDuration(d);
        r1 = bound(r1, 0, MAX_RATE_BPS / 2);
        r2 = bound(r2, 0, MAX_RATE_BPS / 2);

        uint256 combined = Interest.calculateInterest(a, d, r1 + r2);
        uint256 separate1 = Interest.calculateInterest(a, d, r1);
        uint256 separate2 = Interest.calculateInterest(a, d, r2);

        assertApproxEqAbs(combined, separate1 + separate2, 2, "Interest must be linear in rate (+-2 wei)");
    }

    // ========================================
    // FUZZ TEST #10: max saturation (exact, no rounding)
    // ========================================

    function testFuzz_MaxSaturation_ExactAmount(uint256 a) public pure {
        a = _boundAmount(a);
        uint256 interest = Interest.calculateInterest(a, SECONDS_IN_YEAR, MAX_RATE_BPS);
        assertEq(interest, a, "Interest at max rate and one year must equal principal exactly");
    }

    // ========================================
    // FUZZ TEST #11: upper bound at max rate, duration <= 1 year
    // ========================================

    function testFuzz_UpperBound_AtMaxRate(uint256 a, uint256 d) public pure {
        a = _boundAmount(a);
        d = bound(d, 0, SECONDS_IN_YEAR);
        uint256 interest = Interest.calculateInterest(a, d, MAX_RATE_BPS);
        assertLe(interest, a, "Interest at max rate with duration <= 1 year must not exceed principal");
    }

    // ========================================
    // FUZZ TEST #12: never reverts under realistic bounds
    // ========================================

    function testFuzz_NeverReverts(uint256 a, uint256 d, uint256 r) public pure {
        a = _boundAmount(a);
        d = _boundDuration(d);
        r = _boundRate(r);
        // If this call reverts, the fuzz run fails - no assertion needed.
        Interest.calculateInterest(a, d, r);
    }
}
