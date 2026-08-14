//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";

/// @notice Full-range fuzz checks of the FeeCurve math, complementing the
/// sampled invariants in FeeCurveInvariant.t.sol.
contract FeeCurveMathFuzz is Test {
    FeeCurve public feeCurve;

    function setUp() public {
        feeCurve = new FeeCurve(address(this), address(0xdead));
    }

    /// @notice Monotonic non-decrease for ANY two ordered days
    function testFuzz_FeeMonotonicNonDecreasing(uint256 d1, uint256 d2) public view {
        d1 = bound(d1, 0, 3650);
        d2 = bound(d2, d1, 3650);
        assertLe(feeCurve.feeBpsAtDay(d1), feeCurve.feeBpsAtDay(d2), "fee must not decrease");
    }

    /// @notice Bounds on the entire domain, plateau included
    function testFuzz_FeeBoundsWholeDomain(uint256 d) public view {
        d = bound(d, 0, 100_000);
        uint256 fee = feeCurve.feeBpsAtDay(d);
        assertGe(fee, 100, "fee >= 100 bps");
        assertLe(fee, 990, "fee <= 990 bps");
    }

    /// @notice Plateau beyond the last breakpoint
    function testFuzz_FeePlateauAfterYearTen(uint256 k) public view {
        k = bound(k, 0, 1_000_000);
        assertEq(feeCurve.feeBpsAtDay(3650 + k), 990, "plateau at 990 bps");
    }

    /// @notice Day-0 fee is exactly 100 bps (1%)
    function test_DayZeroFeeIsOnePercent() public view {
        assertEq(feeCurve.feeBpsAtDay(0), 100);
    }

    /// @notice currentFeeBps reflects the warped clock day
    function testFuzz_CurrentFeeMatchesDay(uint256 daysSinceStart) public {
        daysSinceStart = bound(daysSinceStart, 0, 100_000);
        vm.warp(feeCurve.START_TIME() + daysSinceStart * 1 days);
        assertEq(feeCurve.currentFeeBps(), feeCurve.feeBpsAtDay(daysSinceStart));
    }

    /// @notice getFee returns the current bps and the configured recipient
    function testFuzz_GetFeeConsistent(uint256 daysSinceStart) public {
        daysSinceStart = bound(daysSinceStart, 0, 100_000);
        vm.warp(feeCurve.START_TIME() + daysSinceStart * 1 days);
        (uint256 bps, address recipient) = feeCurve.getFee();
        assertEq(bps, feeCurve.currentFeeBps());
        assertEq(recipient, feeCurve.feeRecipient());
    }
}
