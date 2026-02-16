//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest} from "./BaseTest.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PenaltyTest
 * @notice Comprehensive unit tests for Penalty library
 * @dev Tests follow logical progression: happy cases, boundary conditions, edge cases
 *      Following DRY principles with helper functions for common operations
 */
contract PenaltyTest is BaseTest {
    // ========================================
    // TEST CONSTANTS
    // ========================================

    // Penalty library constants (must match library)
    uint16 constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint8 constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint32 constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint8 constant BASE_REWARD = 40;
    uint64 constant WEI_DECIMALS = 1e18;
    uint64 constant GWEI_DECIMALS = 1e9;

    // Realistic validator balance limits (max 2048 ETH as specified)
    uint128 constant MIN_VALIDATOR_BALANCE = 1 wei;
    uint128 constant SMALL_VALIDATOR_BALANCE = 1 ether;
    uint128 constant STANDARD_VALIDATOR_BALANCE = 32 ether;
    uint128 constant LARGE_VALIDATOR_BALANCE = 1000 ether;
    uint128 constant MAX_VALIDATOR_BALANCE = 2048 ether; // Absolute maximum

    // Safe total stake values (in ETH)
    uint32 constant MIN_SAFE_TOTAL_STAKE = 1; // 1 ETH
    uint32 constant SAFE_TOTAL_STAKE_1M = 1_000_000; // 1M ETH
    uint32 constant SAFE_TOTAL_STAKE_10M = 10_000_000; // 10M ETH
    uint32 constant SAFE_TOTAL_STAKE_20M = 20_000_000; // 20M ETH
    uint32 constant SAFE_TOTAL_STAKE_100M = 100_000_000; // 100M ETH
    uint32 constant MAX_SAFE_TOTAL_STAKE = type(uint32).max; // ~4.29B ETH

    // Epoch values
    uint32 constant MIN_EPOCHS = 0;
    uint32 constant ONE_EPOCH = 1;
    uint32 constant TEN_EPOCHS = 10;
    uint32 constant HUNDRED_EPOCHS = 100;
    uint32 constant THOUSAND_EPOCHS = 1000;
    uint32 constant MAX_EPOCHS = SLASHING_PENALTY_DURATION_IN_EPOCH; // 8192

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
    }

    // ========================================
    // HELPER FUNCTIONS (DRY)
    // ========================================

    /**
     * @dev Calculate expected initial penalty component
     */
    function calculateExpectedInitialPenalty(uint128 effectiveBalance) internal pure returns (uint128) {
        return effectiveBalance / INITIAL_SLASHING_PENALTY_QUOTIENT;
    }

    /**
     * @dev Calculate expected correlation penalty component
     */
    function calculateExpectedCorrelationPenalty(uint128 effectiveBalance, uint32 safeTotalStake)
        internal
        pure
        returns (uint128)
    {
        // Formula matches library: (effectiveBalance * effectiveBalance * MULTIPLIER / safeTotalStake) * WEI_DECIMALS
        uint256 penalty = uint256(effectiveBalance) * effectiveBalance * PROPORTIONAL_SLASHING_MULTIPLIER
            / uint128(safeTotalStake) * WEI_DECIMALS;
        return uint128(penalty);
    }

    /**
     * @dev Calculate expected leaking penalty component
     */
    function calculateExpectedLeakingPenalty(uint128 effectiveBalance, uint32 safeTotalStake, uint32 epochs)
        internal
        pure
        returns (uint128)
    {
        uint256 penalty = uint256(effectiveBalance) * BASE_REWARD * epochs
            / Math.sqrt(uint256(safeTotalStake) * GWEI_DECIMALS);
        return uint128(penalty);
    }

    /**
     * @dev Calculate full expected slashing penalty (all components)
     */
    function calculateExpectedSlashingPenalty(uint128 effectiveBalance, uint32 safeTotalStake)
        internal
        pure
        returns (uint128)
    {
        uint128 initial = calculateExpectedInitialPenalty(effectiveBalance);
        uint128 correlation = calculateExpectedCorrelationPenalty(effectiveBalance, safeTotalStake);
        uint128 leaking = calculateExpectedLeakingPenalty(effectiveBalance, safeTotalStake, MAX_EPOCHS);
        return initial + correlation + leaking;
    }

    /**
     * @dev Assert slashing penalty matches expected value
     */
    function assertSlashingPenalty(uint128 effectiveBalance, uint32 safeTotalStake, string memory errorMessage)
        internal
    {
        uint128 actual = Penalty.slashing(effectiveBalance, safeTotalStake);
        uint128 expected = calculateExpectedSlashingPenalty(effectiveBalance, safeTotalStake);
        assertEq(actual, expected, errorMessage);
    }

    /**
     * @dev Assert missing attestations penalty matches expected value
     */
    function assertMissingAttestationsPenalty(
        uint128 effectiveBalance,
        uint32 safeTotalStake,
        uint32 epochs,
        string memory errorMessage
    ) internal {
        uint128 actual = Penalty.missingAttestations(effectiveBalance, safeTotalStake, epochs);
        uint128 expected = calculateExpectedLeakingPenalty(effectiveBalance, safeTotalStake, epochs);
        assertEq(actual, expected, errorMessage);
    }

    // ========================================
    // SLASHING FUNCTION - HAPPY CASES
    // ========================================

    function test_Slashing_StandardValidator() public {
        // Standard 32 ETH validator with 20M ETH total stake
        assertSlashingPenalty(STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, "Standard validator slashing incorrect");
    }

    function test_Slashing_MaximumValidator() public {
        // Maximum 2048 ETH validator with 20M ETH total stake
        assertSlashingPenalty(MAX_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, "Maximum validator slashing incorrect");
    }

    function test_Slashing_VariousTotalStakes() public {
        // Test with different total stake values
        uint128 balance = STANDARD_VALIDATOR_BALANCE;

        assertSlashingPenalty(balance, SAFE_TOTAL_STAKE_1M, "1M total stake slashing incorrect");
        assertSlashingPenalty(balance, SAFE_TOTAL_STAKE_10M, "10M total stake slashing incorrect");
        assertSlashingPenalty(balance, SAFE_TOTAL_STAKE_100M, "100M total stake slashing incorrect");
    }

    function test_Slashing_LargeValidatorSmallStake() public {
        // Large validator (1000 ETH) with small total stake (1M ETH)
        // This creates higher correlation penalty
        assertSlashingPenalty(
            LARGE_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_1M, "Large validator with small stake slashing incorrect"
        );
    }

    // ========================================
    // SLASHING FUNCTION - BOUNDARY CONDITIONS
    // ========================================

    function test_Slashing_ZeroBalance() public {
        uint128 penalty = Penalty.slashing(0, SAFE_TOTAL_STAKE_20M);
        assertEq(penalty, 0, "Zero balance should return zero penalty");
    }

    function test_Slashing_MinimumBalance() public {
        // 1 wei balance - should still calculate without reverting
        assertSlashingPenalty(MIN_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, "Minimum balance slashing incorrect");
    }

    function test_Slashing_MaximumBalance() public {
        // Test absolute maximum (2048 ETH)
        assertSlashingPenalty(
            MAX_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, "Maximum balance (2048 ETH) slashing incorrect"
        );
    }

    function test_Slashing_MinimumSafeTotalStake() public {
        // Minimum safe total stake (1 ETH)
        assertSlashingPenalty(
            STANDARD_VALIDATOR_BALANCE, MIN_SAFE_TOTAL_STAKE, "Minimum safe total stake slashing incorrect"
        );
    }

    function test_Slashing_MaximumSafeTotalStake() public {
        // Maximum safe total stake (type(uint32).max)
        assertSlashingPenalty(
            STANDARD_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE, "Maximum safe total stake slashing incorrect"
        );
    }

    function test_Slashing_JustBelowMaximum() public {
        // Test values just below maximum
        assertSlashingPenalty(
            MAX_VALIDATOR_BALANCE - 1 ether, MAX_SAFE_TOTAL_STAKE - 1, "Just below maximum values slashing incorrect"
        );
    }

    // ========================================
    // SLASHING FUNCTION - EDGE CASES
    // ========================================

    function test_Slashing_MaxBalanceMinStake() public {
        // Maximum balance with minimum stake - highest possible penalty ratio
        assertSlashingPenalty(
            MAX_VALIDATOR_BALANCE, MIN_SAFE_TOTAL_STAKE, "Max balance with min stake slashing incorrect"
        );
    }

    function test_Slashing_MinBalanceMaxStake() public {
        // Minimum balance with maximum stake - lowest possible penalty ratio
        assertSlashingPenalty(
            MIN_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE, "Min balance with max stake slashing incorrect"
        );
    }

    function test_Slashing_PrecisionLoss() public {
        // Test scenarios where division might cause precision loss
        uint128 balance = 1.23456789 ether;
        uint32 stake = 12345678;

        assertSlashingPenalty(balance, stake, "Precision loss scenario slashing incorrect");
    }

    function test_Slashing_NoOverflow() public {
        // Verify no overflow with maximum allowed values
        // This should not revert
        uint128 penalty = Penalty.slashing(MAX_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE);

        // The penalty can exceed balance in extreme cases (by design)
        // Just verify it doesn't overflow/revert
        assertTrue(penalty > 0, "Penalty should be calculated without overflow");

        // Log for verification
        emit log_named_uint("Max penalty with min stake", penalty);
        emit log_named_uint("Max validator balance", MAX_VALIDATOR_BALANCE);
    }

    // ========================================
    // MISSING ATTESTATIONS - HAPPY CASES
    // ========================================

    function test_MissingAttestations_StandardSingleEpoch() public {
        // Standard validator missing 1 epoch
        assertMissingAttestationsPenalty(
            STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, ONE_EPOCH, "Single epoch attestation penalty incorrect"
        );
    }

    function test_MissingAttestations_StandardMultipleEpochs() public {
        // Standard validator missing various epochs
        assertMissingAttestationsPenalty(
            STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, TEN_EPOCHS, "Ten epochs attestation penalty incorrect"
        );

        assertMissingAttestationsPenalty(
            STANDARD_VALIDATOR_BALANCE,
            SAFE_TOTAL_STAKE_20M,
            HUNDRED_EPOCHS,
            "Hundred epochs attestation penalty incorrect"
        );

        assertMissingAttestationsPenalty(
            STANDARD_VALIDATOR_BALANCE,
            SAFE_TOTAL_STAKE_20M,
            THOUSAND_EPOCHS,
            "Thousand epochs attestation penalty incorrect"
        );
    }

    function test_MissingAttestations_MaximumDuration() public {
        // Maximum penalty duration (8192 epochs)
        assertMissingAttestationsPenalty(
            STANDARD_VALIDATOR_BALANCE,
            SAFE_TOTAL_STAKE_20M,
            MAX_EPOCHS,
            "Maximum duration attestation penalty incorrect"
        );
    }

    function test_MissingAttestations_MaximumValidator() public {
        // Maximum validator (2048 ETH) missing attestations
        assertMissingAttestationsPenalty(
            MAX_VALIDATOR_BALANCE,
            SAFE_TOTAL_STAKE_20M,
            HUNDRED_EPOCHS,
            "Maximum validator attestation penalty incorrect"
        );
    }

    // ========================================
    // MISSING ATTESTATIONS - BOUNDARY CONDITIONS
    // ========================================

    function test_MissingAttestations_ZeroBalance() public {
        uint128 penalty = Penalty.missingAttestations(0, SAFE_TOTAL_STAKE_20M, HUNDRED_EPOCHS);
        assertEq(penalty, 0, "Zero balance should return zero penalty");
    }

    function test_MissingAttestations_ZeroEpochs() public {
        uint128 penalty = Penalty.missingAttestations(STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, 0);
        assertEq(penalty, 0, "Zero epochs should return zero penalty");
    }

    function test_MissingAttestations_MinimumValues() public {
        // Minimum non-zero values
        assertMissingAttestationsPenalty(
            MIN_VALIDATOR_BALANCE, MIN_SAFE_TOTAL_STAKE, ONE_EPOCH, "Minimum values attestation penalty incorrect"
        );
    }

    function test_MissingAttestations_MaximumValues() public {
        // Maximum values (2048 ETH, max epochs)
        assertMissingAttestationsPenalty(
            MAX_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE, MAX_EPOCHS, "Maximum values attestation penalty incorrect"
        );
    }

    function test_MissingAttestations_MaxBalanceMaxEpochs() public {
        // Maximum balance (2048 ETH) with maximum epochs
        assertMissingAttestationsPenalty(
            MAX_VALIDATOR_BALANCE,
            SAFE_TOTAL_STAKE_20M,
            MAX_EPOCHS,
            "Max balance max epochs attestation penalty incorrect"
        );
    }

    // ========================================
    // MISSING ATTESTATIONS - EDGE CASES
    // ========================================

    function test_MissingAttestations_VerySmallPenalty() public {
        // Small balance, large stake, few epochs - results in tiny penalty
        assertMissingAttestationsPenalty(
            SMALL_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE, ONE_EPOCH, "Very small penalty calculation incorrect"
        );
    }

    function test_MissingAttestations_VeryLargePenalty() public {
        // Max balance, min stake, max epochs - results in large penalty
        assertMissingAttestationsPenalty(
            MAX_VALIDATOR_BALANCE, MIN_SAFE_TOTAL_STAKE, MAX_EPOCHS, "Very large penalty calculation incorrect"
        );
    }

    function test_MissingAttestations_PrecisionWithSqrt() public {
        // Test sqrt precision with various stakes
        uint128 balance = 100 ether;
        uint32 epochs = 100;

        // Perfect square
        assertMissingAttestationsPenalty(
            balance,
            10000, // sqrt(10000 * 1e9) is clean
            epochs,
            "Perfect square stake attestation incorrect"
        );

        // Non-perfect square
        assertMissingAttestationsPenalty(
            balance,
            10001, // sqrt(10001 * 1e9) has rounding
            epochs,
            "Non-perfect square stake attestation incorrect"
        );
    }

    // ========================================
    // INTEGRATION TESTS
    // ========================================

    function test_Integration_StandardValidatorFullSlashing() public {
        // Verify all three components work together for standard validator
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;

        uint128 slashingPenalty = Penalty.slashing(balance, stake);

        // Calculate individual components
        uint128 initial = calculateExpectedInitialPenalty(balance);
        uint128 correlation = calculateExpectedCorrelationPenalty(balance, stake);
        uint128 leaking = calculateExpectedLeakingPenalty(balance, stake, MAX_EPOCHS);

        // Verify total equals sum of components
        assertEq(slashingPenalty, initial + correlation + leaking, "Total penalty != sum of components");

        // Note: In some cases, penalty can exceed balance (by design) - this is valid protocol behavior
        // Log the ratio for verification
        emit log_named_uint("Standard Validator Penalty", slashingPenalty);
        emit log_named_uint("Standard Validator Balance", balance);
        // Calculate percentage safely (penalty might exceed balance)
        if (slashingPenalty <= balance) {
            emit log_named_decimal_uint("Penalty as % of balance", slashingPenalty * 100 / balance, 2);
        } else {
            emit log_named_uint("Penalty exceeds balance by factor", slashingPenalty / balance);
        }
    }

    function test_Integration_MaxValidatorFullSlashing() public {
        // Verify all components work with maximum validator (2048 ETH)
        uint128 balance = MAX_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;

        uint128 slashingPenalty = Penalty.slashing(balance, stake);

        // Calculate individual components
        uint128 initial = calculateExpectedInitialPenalty(balance);
        uint128 correlation = calculateExpectedCorrelationPenalty(balance, stake);
        uint128 leaking = calculateExpectedLeakingPenalty(balance, stake, MAX_EPOCHS);

        // Verify total equals sum of components
        assertEq(slashingPenalty, initial + correlation + leaking, "Max validator penalty != sum of components");

        // Log for manual verification if needed
        emit log_named_uint("Max Validator Balance", balance);
        emit log_named_uint("Initial Penalty", initial);
        emit log_named_uint("Correlation Penalty", correlation);
        emit log_named_uint("Leaking Penalty", leaking);
        emit log_named_uint("Total Penalty", slashingPenalty);
    }

    function test_Integration_ComponentRelationships() public {
        // Test that penalty components have expected relationships
        uint128 balance = STANDARD_VALIDATOR_BALANCE;

        // With small total stake, correlation penalty dominates
        uint128 penalty1 = Penalty.slashing(balance, SAFE_TOTAL_STAKE_1M);

        // With large total stake, correlation penalty is smaller
        uint128 penalty2 = Penalty.slashing(balance, SAFE_TOTAL_STAKE_100M);

        // Higher total stake should result in lower penalty
        assertTrue(penalty2 < penalty1, "Higher stake should result in lower penalty");
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    function test_GasUsage_Slashing() public {
        uint256 gasBefore = gasleft();
        Penalty.slashing(STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for slashing calculation", gasUsed);
        assertTrue(gasUsed < 50000, "Slashing calculation gas usage too high");
    }

    function test_GasUsage_MissingAttestations() public {
        uint256 gasBefore = gasleft();
        Penalty.missingAttestations(STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, HUNDRED_EPOCHS);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for attestation penalty calculation", gasUsed);
        assertTrue(gasUsed < 20000, "Attestation penalty calculation gas usage too high");
    }
}
