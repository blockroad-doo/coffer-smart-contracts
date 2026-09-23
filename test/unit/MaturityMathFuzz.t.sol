//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";
import {Interest} from "../../src/libraries/Interest.sol";

/// @title MaturityMathFuzzTest
/// @notice Stateless fuzz of the composed conversion math (gap row G-08): the interest floor and the fee floor
///         composed into the maturity value, the buffer credit, the fee-curve interpolation, and split purchases.
///         InterestInvariant.t.sol and FeeCurveMathFuzz.t.sol fuzz each conversion alone and live under
///         test/invariant, this file composes them and lives under test/unit so the ci profile runs it.
contract MaturityMathFuzzTest is Test {
    uint256 constant MAX_RATE = 1e8;
    uint256 constant SECONDS_IN_YEAR = 31_536_000;
    uint256 constant D = MAX_RATE * SECONDS_IN_YEAR;
    uint256 constant BPS = 10000;
    uint256 constant MAX_DURATION = 1_576_800_000;
    uint256 constant MAX_DAY = 4000;
    uint256 constant MAX_FEE_BPS = 990;

    FeeCurve public feeCurve;

    function setUp() public {
        feeCurve = new FeeCurve(address(this), address(0xdead));
    }

    /// @dev The two floors of buyBond composed: interest, fee on the interest, and the stored maturity value.
    function _maturity(uint256 p, uint256 d, uint256 r, uint256 bps)
        internal
        pure
        returns (uint256 m, uint256 i, uint256 f)
    {
        i = Interest.calculateInterest(p, d, r);
        f = (i * bps) / BPS;
        m = p + i - f;
    }

    /// @dev The buffer-scaled issueSize credit of initialize and validatorAddFundsToConsensus.
    function _credit(uint256 v, uint256 b) internal pure returns (uint256) {
        return (v * (BPS - b)) / BPS;
    }

    /// @dev The segment of the FeeCurve breakpoint table containing day d, for d below the last breakpoint.
    function _segment(uint256 d) internal pure returns (uint256 d0, uint256 d1, uint256 b0, uint256 b1) {
        uint32[10] memory day = [uint32(0), 90, 180, 365, 730, 1095, 1460, 1825, 2555, 3650];
        uint32[10] memory bps = [uint32(100), 197, 283, 432, 642, 774, 857, 910, 964, 990];
        for (uint256 k = 0; k < 9; ++k) {
            if (d < day[k + 1]) return (day[k], day[k + 1], bps[k], bps[k + 1]);
        }
        revert("day beyond the table");
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ===== 1. The stored maturity value is within one wei of the exact real-number value =====
    // With a = P*r*d - I*D in [0, D) and b = I*bps - F*BPS in [0, BPS), the scaled difference between the
    // stored value and the exact value is D*b - a*(BPS - bps), which lies strictly inside (-D*BPS, D*BPS).
    function testFuzz_Maturity_TwoFloors_WithinOneWeiOfExact(uint128 p, uint32 d, uint32 r, uint256 day) public view {
        d = uint32(bound(d, 1, MAX_DURATION));
        r = uint32(bound(r, 1, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        (uint256 m, uint256 i, uint256 f) = _maturity(p, d, r, bps);
        uint256 prd = uint256(p) * r * d;

        assertTrue(i * D <= prd && prd < (i + 1) * D, "interest is the floor of the exact interest");
        assertTrue(f * BPS <= i * bps && i * bps < (f + 1) * BPS, "fee is the floor of the exact fee");
        assertGe((i - f) * BPS, i * (BPS - MAX_FEE_BPS), "net interest is at least 90.1 percent of the interest");

        uint256 scaledM = m * D * BPS;
        uint256 scaledExact = uint256(p) * D * BPS + prd * (BPS - bps);
        assertTrue(scaledM + D * BPS > scaledExact, "stored value more than one wei below the exact value");
        assertTrue(scaledM < scaledExact + D * BPS, "stored value more than one wei above the exact value");
    }

    // ===== 2. Monotone in the principal: strictly for the maturity value, weakly for the net interest =====
    // The 9.9 percent cap is what keeps the floored fee from inverting the order by one wei.
    function testFuzz_Maturity_StrictlyIncreasingInPrincipal(uint128 p1, uint128 p2, uint32 d, uint32 r, uint256 day)
        public
        view
    {
        d = uint32(bound(d, 1, MAX_DURATION));
        r = uint32(bound(r, 1, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        if (p1 > p2) (p1, p2) = (p2, p1);
        (uint256 m1,,) = _maturity(p1, d, r, bps);
        (uint256 m2,,) = _maturity(p2, d, r, bps);

        if (p1 < p2) assertLt(m1, m2, "maturity value must rise with the principal");
        assertLe(m1 - p1, m2 - p2, "net interest must not fall with the principal");
    }

    // ===== 3. Monotone in the duration and in the rate =====
    function testFuzz_Maturity_NonDecreasingInDuration(uint128 p, uint32 d1, uint32 d2, uint32 r, uint256 day)
        public
        view
    {
        d1 = uint32(bound(d1, 1, MAX_DURATION));
        d2 = uint32(bound(d2, 1, MAX_DURATION));
        r = uint32(bound(r, 1, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        if (d1 > d2) (d1, d2) = (d2, d1);
        (uint256 shorter,,) = _maturity(p, d1, r, bps);
        (uint256 longer,,) = _maturity(p, d2, r, bps);

        assertLe(shorter, longer, "a longer lock never yields a smaller maturity value");
    }

    function testFuzz_Maturity_NonDecreasingInRate(uint128 p, uint32 d, uint32 r1, uint32 r2, uint256 day) public view {
        d = uint32(bound(d, 1, MAX_DURATION));
        r1 = uint32(bound(r1, 1, MAX_RATE));
        r2 = uint32(bound(r2, 1, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        if (r1 > r2) (r1, r2) = (r2, r1);
        (uint256 lower,,) = _maturity(p, d, r1, bps);
        (uint256 higher,,) = _maturity(p, d, r2, bps);

        assertLe(lower, higher, "a higher rate never yields a smaller maturity value");
    }

    // ===== 4. The zero-interest chain =====
    function testFuzz_Maturity_ZeroInterestChain(uint128 p, uint32 d, uint32 r, uint256 day) public view {
        d = uint32(bound(d, 0, MAX_DURATION));
        r = uint32(bound(r, 0, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        (uint256 m, uint256 i, uint256 f) = _maturity(p, d, r, bps);

        assertEq(i == 0, m == p, "zero interest exactly when the maturity value equals the principal");
        if (i == 0) assertEq(f, 0, "no fee without interest");
        if (i >= 1) {
            assertLt(f, i, "the fee stays below the interest");
            assertGe(m, uint256(p) + 1, "one wei of interest already yields a positive net");
        }
    }

    // ===== 5. The buffer credit rounds down and is superadditive =====
    function testFuzz_BufferCredit_SuperadditiveAndBounded(uint128 v1, uint128 v2, uint16 b) public pure {
        b = uint16(bound(b, 0, BPS - 1));
        v1 = uint128(bound(v1, 1, type(uint128).max));
        v2 = uint128(bound(v2, 1, type(uint128).max));
        uint256 c1 = _credit(v1, b);
        uint256 c2 = _credit(v2, b);
        uint256 c12 = _credit(uint256(v1) + v2, b);

        assertLe(c1 + c2, c12, "splitting a deposit never yields more capacity than one deposit");
        assertLe(c12, c1 + c2 + 1, "one deposit yields at most one wei more than the split");
        assertLe(c1, v1, "the credit never exceeds the deposit");
        assertEq(c1 == v1, b == 0, "the credit equals the deposit exactly when the buffer is zero");
        assertGe(c1, uint256(v1) / BPS, "the credit is at least one basis point of the deposit");
        if (v1 <= v2) assertLe(c1, c2, "the credit is monotone in the deposit");
    }

    // ===== 6. The fee-curve interpolation floors inside a segment =====
    function testFuzz_FeeCurve_InterpolationFloorsWithinSegment(uint256 d) public view {
        d = bound(d, 0, 3649);
        (uint256 d0, uint256 d1, uint256 b0, uint256 b1) = _segment(d);
        uint256 f = feeCurve.feeBpsAtDay(d);
        uint256 exactScaled = b0 * (d1 - d0) + (b1 - b0) * (d - d0);

        assertLe(f * (d1 - d0), exactScaled, "interpolation rounded up");
        assertGt(f * (d1 - d0) + (d1 - d0), exactScaled, "interpolation more than one step short of exact");
        assertLt(f, b1, "the upper breakpoint is never reached inside its segment");
        if (d == d0) assertEq(f, b0, "a breakpoint day yields its exact value");
    }

    // ===== 7. The day index floors =====
    function testFuzz_FeeCurve_DayIndexFloors(uint256 secs) public {
        secs = bound(secs, 0, 4000 days);
        vm.warp(feeCurve.START_TIME() + secs);
        uint256 down = secs / 1 days;
        uint256 up = (secs + 1 days - 1) / 1 days;

        assertEq(feeCurve.currentFeeBps(), feeCurve.feeBpsAtDay(down), "the day index floors");
        assertLe(feeCurve.currentFeeBps(), feeCurve.feeBpsAtDay(up), "the floored day never yields more than the next");
    }

    // ===== 8. Split purchases extract at most dust =====
    // Each net interest sits strictly within one wei of its exact value (test 1) and the exact values are linear
    // in the principal, so four parts and the whole differ by at most four wei.
    function _sumParts(uint128[4] memory parts, uint256 d, uint256 r, uint256 bps)
        internal
        pure
        returns (uint256 sumP, uint256 sumI, uint256 sumNet)
    {
        for (uint256 k = 0; k < 4; ++k) {
            uint256 part = bound(parts[k], 0, type(uint128).max / 4);
            (, uint256 ik, uint256 fk) = _maturity(part, d, r, bps);
            sumP += part;
            sumI += ik;
            sumNet += ik - fk;
        }
    }

    function testFuzz_SplitPurchase_DustBounded(uint128[4] memory parts, uint32 d, uint32 r, uint256 day) public view {
        d = uint32(bound(d, 1, MAX_DURATION));
        r = uint32(bound(r, 1, MAX_RATE));
        uint256 bps = feeCurve.feeBpsAtDay(bound(day, 0, MAX_DAY));
        (uint256 sumP, uint256 sumI, uint256 sumNet) = _sumParts(parts, d, r, bps);
        (, uint256 wholeI, uint256 wholeF) = _maturity(sumP, d, r, bps);

        assertLe(sumI, wholeI, "splitting never adds gross interest");
        assertLt(
            sumNet * D * BPS,
            sumP * r * d * (BPS - bps) + 4 * D * BPS,
            "split net interest exceeds the exact net by four wei or more"
        );
        assertLe(_absDiff(sumNet, wholeI - wholeF), 4, "split and whole nets differ by more than four wei");
    }
}
