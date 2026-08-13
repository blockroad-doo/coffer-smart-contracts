//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Interest} from "../../src/libraries/Interest.sol";

/**
 * @title InterestTest
 * @notice Comprehensive unit tests for Interest library with realistic boundaries
 * @dev Tests follow logical progression: happy cases, zero handling, boundary conditions, precision
 */
contract InterestTest is BaseTest {
    // ========================================
    // CONSTANTS FOR TESTING
    // ========================================

    // Realistic maximum values as per requirements
    uint256 constant MAX_BOND_AMOUNT = type(uint128).max; // full uint128 range (bond values are uint128)
    uint256 constant MAX_BOND_DURATION = 1_576_800_000; // 50 years max
    uint256 constant MAX_INTEREST_RATE = 1e8; // 100% max

    uint256 constant SECONDS_IN_YEAR = 31_536_000;

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
    }

    // ========================================
    // HAPPY CASES - COMMON SCENARIOS
    // ========================================

    function test_CalculateInterest_StandardValidatorBond() public {
        // Scenario: Standard 32 ETH validator bond for 1 year at 5%
        uint128 amount = 32 ether;
        uint32 duration = ONE_YEAR;
        uint32 rate = MEDIUM_RATE; // 5% = 5e6

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Expected: 32 ETH * 5% * 1 year = 1.6 ETH
        uint256 expectedInterest = 1.6 ether;
        assertEq(interest, expectedInterest, "Interest calculation for standard bond incorrect");
    }

    function test_CalculateInterest_ShortTermBond() public {
        // Scenario: 10 ETH for 1 month at 10%
        uint128 amount = 10 ether;
        uint32 duration = ONE_MONTH;
        uint32 rate = 1e7; // 10%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Expected: 10 ETH * 10% * (30.44 days / 365 days) ≈ 0.0834 ETH
        uint256 expectedInterest = (uint256(amount) * rate * duration) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "Interest calculation for short term bond incorrect");
    }

    function test_CalculateInterest_LargeBond() public pure {
        // Scenario: 10,000 ETH for 2 years at 3%
        uint128 amount = 10_000 ether;
        uint32 duration = 2 * ONE_YEAR;
        uint32 rate = 3e6; // 3%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Expected: 10,000 ETH * 3% * 2 years = 600 ETH
        uint256 expectedInterest = 600 ether;
        assertEq(interest, expectedInterest, "Interest calculation for large bond incorrect");
    }

    function test_CalculateInterest_MediumTermHighRate() public {
        // Scenario: 100 ETH for 6 months at 20%
        uint128 amount = 100 ether;
        uint32 duration = 15_768_000;
        uint32 rate = 2e7; // 20%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Expected: 100 ETH * 20% * 0.5 years = 10 ETH
        uint256 expectedInterest = 10 ether;
        assertEq(interest, expectedInterest, "Interest calculation for medium term high rate incorrect");
    }

    function test_CalculateInterest_MinimalViableBond() public {
        // Scenario: 0.1 ETH for 1 week at 1%
        uint128 amount = 0.1 ether;
        uint32 duration = ONE_WEEK;
        uint32 rate = MIN_RATE; // 1%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Calculate expected
        uint256 expectedInterest = (uint256(amount) * rate * duration) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);

        assertEq(interest, expectedInterest, "Interest calculation for minimal bond incorrect");
        assertTrue(interest > 0, "Minimal bond should generate some interest");
    }

    // ========================================
    // ZERO HANDLING
    // ========================================

    function test_CalculateInterest_ZeroAmount() public {
        uint256 interest = Interest.calculateInterest(0, ONE_YEAR, MEDIUM_RATE);
        assertEq(interest, 0, "Zero amount should return zero interest");
    }

    function test_CalculateInterest_ZeroDuration() public {
        uint256 interest = Interest.calculateInterest(100 ether, 0, MEDIUM_RATE);
        assertEq(interest, 0, "Zero duration should return zero interest");
    }

    function test_CalculateInterest_ZeroRate() public {
        uint256 interest = Interest.calculateInterest(100 ether, ONE_YEAR, 0);
        assertEq(interest, 0, "Zero rate should return zero interest");
    }

    function test_CalculateInterest_AllZeros() public {
        uint256 interest = Interest.calculateInterest(0, 0, 0);
        assertEq(interest, 0, "All zeros should return zero interest");
    }

    // ========================================
    // BOUNDARY CONDITIONS - AMOUNTS
    // ========================================

    function test_CalculateInterest_OneWei() public {
        uint256 interest = Interest.calculateInterest(1, ONE_YEAR, MEDIUM_RATE);
        // 1 wei * 5% * 1 year should be 0 due to rounding
        assertEq(interest, 0, "One wei should round to zero interest");
    }

    function test_CalculateInterest_OneEther() public {
        uint128 amount = 1 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MEDIUM_RATE);

        // 1 ETH * 5% * 1 year = 0.05 ETH
        uint256 expectedInterest = 0.05 ether;
        assertEq(interest, expectedInterest, "One ether interest calculation incorrect");
    }

    function test_CalculateInterest_ThousandEther() public {
        uint128 amount = 1000 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MEDIUM_RATE);

        // 1000 ETH * 5% * 1 year = 50 ETH
        uint256 expectedInterest = 50 ether;
        assertEq(interest, expectedInterest, "Thousand ether interest calculation incorrect");
    }

    function test_CalculateInterest_NearMaxRealisticAmount() public {
        // Test with 999,999 ETH (just under max)
        uint128 amount = 999_999 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MIN_RATE);

        // 999,999 ETH * 1% * 1 year = 9,999.99 ETH
        uint256 expectedInterest = (uint256(amount) * MIN_RATE * ONE_YEAR) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "Near max amount interest calculation incorrect");
    }

    // ========================================
    // BOUNDARY CONDITIONS - DURATIONS
    // ========================================

    function test_CalculateInterest_OneSecond() public {
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, 1, MEDIUM_RATE);

        // Should be extremely small but non-zero
        uint256 expectedInterest = (uint256(amount) * MEDIUM_RATE * 1) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "One second interest calculation incorrect");
    }

    function test_CalculateInterest_OneDay() public {
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_DAY, MEDIUM_RATE);

        // 100 ETH * 5% * (1/365) ≈ 0.0137 ETH
        uint256 expectedInterest = (uint256(amount) * MEDIUM_RATE * ONE_DAY) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "One day interest calculation incorrect");
    }

    function test_CalculateInterest_OneYear() public {
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MEDIUM_RATE);

        // 100 ETH * 5% * 1 year = 5 ETH
        uint256 expectedInterest = 5 ether;
        assertEq(interest, expectedInterest, "One year interest calculation incorrect");
    }

    function test_CalculateInterest_FortyNineYears() public {
        uint128 amount = 100 ether;
        uint32 duration = 49 * ONE_YEAR;
        uint256 interest = Interest.calculateInterest(amount, duration, MIN_RATE);

        // 100 ETH * 1% * 49 years = 49 ETH
        uint256 expectedInterest = 49 ether;
        assertEq(interest, expectedInterest, "49 years interest calculation incorrect");
    }

    function test_CalculateInterest_MaxRealisticDuration() public {
        // Test with exactly 50 years
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, MAX_BOND_DURATION, MIN_RATE);

        // 100 ETH * 1% * 50 years = 50 ETH
        uint256 expectedInterest = 50 ether;
        assertEq(interest, expectedInterest, "Max duration interest calculation incorrect");
    }

    // ========================================
    // BOUNDARY CONDITIONS - RATES
    // ========================================

    function test_CalculateInterest_MinimalRate() public {
        // 0.01% rate (1e6 with 1e8 divisor)
        uint128 amount = 1000 ether;
        uint32 rate = 1e6; // 0.01%
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, rate);

        // 1000 ETH * 0.01% * 1 year = 10 ETH
        uint256 expectedInterest = 10 ether;
        assertEq(interest, expectedInterest, "Minimal rate interest calculation incorrect");
    }

    function test_CalculateInterest_OnePercent() public {
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MIN_RATE);

        // 100 ETH * 1% * 1 year = 1 ETH
        uint256 expectedInterest = 1 ether;
        assertEq(interest, expectedInterest, "One percent interest calculation incorrect");
    }

    function test_CalculateInterest_FiftyPercent() public {
        uint128 amount = 100 ether;
        uint32 rate = 5e7; // 50%
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, rate);

        // 100 ETH * 50% * 1 year = 50 ETH
        uint256 expectedInterest = 50 ether;
        assertEq(interest, expectedInterest, "Fifty percent interest calculation incorrect");
    }

    function test_CalculateInterest_NinetyNinePercent() public {
        uint128 amount = 100 ether;
        uint32 rate = 99e6; // 99%
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, rate);

        // 100 ETH * 99% * 1 year = 99 ETH
        uint256 expectedInterest = 99 ether;
        assertEq(interest, expectedInterest, "99 percent interest calculation incorrect");
    }

    function test_CalculateInterest_MaxRate() public {
        // Test with exactly 100% rate
        uint128 amount = 100 ether;
        uint256 interest = Interest.calculateInterest(amount, ONE_YEAR, MAX_INTEREST_RATE);

        // 100 ETH * 100% * 1 year = 100 ETH
        uint256 expectedInterest = 100 ether;
        assertEq(interest, expectedInterest, "Max rate interest calculation incorrect");
    }

    // ========================================
    // EXTREME REALISTIC SCENARIOS
    // ========================================

    function test_CalculateInterest_MaxEverything() public {
        // Maximum representable inputs: uint128-max amount (bond values are uint128), 50-year max duration, 100% rate
        uint256 amount = MAX_BOND_AMOUNT;
        uint256 duration = MAX_BOND_DURATION;
        uint256 rate = MAX_INTEREST_RATE;

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // interest = amount * rate * duration / (MAX_RATE * SECONDS_IN_YEAR); at max rate/duration that is 50x principal.
        uint256 expectedInterest = (amount * rate * duration) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "Maximum scenario calculation incorrect");

        // Ensure no overflow occurred
        assertTrue(interest > amount, "Interest should be greater than principal");
    }

    function test_CalculateInterest_LargeAmountShortDuration() public {
        // Large amount but very short duration
        uint128 amount = 500_000 ether;
        uint32 duration = ONE_DAY;
        uint32 rate = HIGH_RATE; // 100%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // 500,000 ETH * 100% * (1/365) ≈ 1,369.86 ETH
        uint256 expectedInterest = (uint256(amount) * rate * duration) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "Large amount short duration calculation incorrect");
    }

    function test_CalculateInterest_SmallAmountLongDuration() public {
        // Small amount but very long duration
        uint128 amount = 0.1 ether;
        uint256 duration = MAX_BOND_DURATION; // 50 years
        uint32 rate = HIGH_RATE; // 100%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // 0.1 ETH * 100% * 50 years = 5 ETH
        uint256 expectedInterest = 5 ether;
        assertEq(interest, expectedInterest, "Small amount long duration calculation incorrect");
    }

    // ========================================
    // PRECISION TESTS
    // ========================================

    function test_CalculateInterest_PrecisionLoss() public {
        // Test case where precision loss might occur
        uint128 amount = 1.234567891234567891 ether;
        uint32 duration = 123_456; // ~1.4 days
        uint32 rate = 1234567; // ~1.234567%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Manual calculation to verify
        uint256 expectedInterest = (uint256(amount) * rate * duration) / (uint256(RATE_DIVISOR) * SECONDS_IN_YEAR);
        assertEq(interest, expectedInterest, "Precision calculation mismatch");
    }

    function test_CalculateInterest_RoundingDown() public {
        // Test that rounding always goes down (no unexpected rounding up)
        uint128 amount = 1 gwei;
        uint32 duration = 1; // 1 second
        uint32 rate = 1e6; // 1%

        uint256 interest = Interest.calculateInterest(amount, duration, rate);

        // Should round down to 0
        assertEq(interest, 0, "Should round down to zero");
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    function test_CalculateInterest_GasUsage() public {
        uint128 amount = 100 ether;
        uint32 duration = ONE_YEAR;
        uint32 rate = MEDIUM_RATE;

        uint256 gasBefore = gasleft();
        Interest.calculateInterest(amount, duration, rate);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for interest calculation", gasUsed);

        // Interest calculation should be very efficient
        assertTrue(gasUsed < 10000, "Interest calculation uses too much gas");
    }

    /// @notice Interest math does not overflow at the uint128 input maximum (bond amounts are uint128;
    /// 100%/yr over the 50-year max duration = 50x principal, computed in uint256 without reverting).
    /// Salvaged from VerifyGweiCastBoundary.t.sol when the holder consensus path (F-04 guard) was removed.
    function test_Interest_NoOverflow_AtUint128Max() public pure {
        uint256 maxInterest = Interest.calculateInterest(type(uint128).max, 1_576_800_000, 1e8);
        assertGt(maxInterest, 0, "interest computed at max inputs without overflow");
    }
}
