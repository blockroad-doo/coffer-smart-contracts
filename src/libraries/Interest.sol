//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/// @title Interest
/// @author Coffer Team
/// @notice Library for calculating simple interest on bond values
library Interest {
    uint256 private constant MAX_RATE = 1e8; // 1e8 = 100%
    uint256 private constant SECONDS_IN_YEAR = 31_536_000; // 365 days * 24 hours * 60 minutes * 60 seconds
    uint256 private constant MAX_RATE_IN_YEAR_SECONDS = MAX_RATE * SECONDS_IN_YEAR;

    /// @notice Function to calculate the interest based on the amount, duration, and interest rate
    /// @notice We use simple interest calculation based on time duration to calculate the interest
    /// @notice The interest is calculated as: (amount * interest rate * duration) / (RATE_DIVISOR * SECONDS_IN_YEAR)
    /// @param _amount The amount for which interest is to be calculated
    /// @param _duration The duration for which interest is to be calculated
    /// @param _rate The yearly interest rate to be applied, should be in the range (0, 1e8]
    /// @return The calculated interest amount
    function calculateInterest(uint256 _amount, uint256 _duration, uint256 _rate) internal pure returns (uint256) {
        if (_amount == 0 || _duration == 0 || _rate == 0) return 0;

        // Calculate the interest based on the amount, interest rate and duration
        return (_amount * _rate * _duration) / MAX_RATE_IN_YEAR_SECONDS;
    }
}
