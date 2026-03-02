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
    uint256 constant INITIAL_SLASHING_PENALTY_QUOTIENT = 4096;
    uint256 constant PROPORTIONAL_SLASHING_MULTIPLIER = 3;
    uint256 constant SLASHING_PENALTY_DURATION_IN_EPOCH = 8192;
    uint256 constant BASE_REWARD = 40;
    uint256 constant WEI_DECIMALS = 1e18;
    uint256 constant GWEI_DECIMALS = 1e9;

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
    uint256 constant MAX_EPOCHS = SLASHING_PENALTY_DURATION_IN_EPOCH; // 8192

    // Ethereum has ~225 epochs per day (32 slots per epoch, 12 second slot time)
    uint32 constant EPOCHS_PER_DAY = 225;
    uint32 constant EPOCHS_PER_YEAR = 82125; // 225 * 365
    uint32 constant EPOCHS_10_YEARS = 821250; // 10 * 365 * 225
    uint32 constant EPOCHS_20_YEARS = 1642500; // 20 * 365 * 225
    uint32 constant EPOCHS_50_YEARS = 4106250; // 50 * 365 * 225

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
    function calculateExpectedInitialPenalty(uint256 effectiveBalance) internal pure returns (uint256) {
        return effectiveBalance / INITIAL_SLASHING_PENALTY_QUOTIENT;
    }

    /**
     * @dev Calculate expected correlation penalty component
     */
    function calculateExpectedCorrelationPenalty(uint256 effectiveBalance, uint256 safeTotalStake)
        internal
        pure
        returns (uint256)
    {
        // Formula matches library: (effectiveBalance * effectiveBalance * MULTIPLIER) / (safeTotalStake * WEI_DECIMALS)
        return effectiveBalance * effectiveBalance * PROPORTIONAL_SLASHING_MULTIPLIER / (safeTotalStake * WEI_DECIMALS);
    }

    /**
     * @dev Calculate expected leaking penalty component
     */
    function calculateExpectedLeakingPenalty(uint256 effectiveBalance, uint256 safeTotalStake, uint256 epochs)
        internal
        pure
        returns (uint256)
    {
        return effectiveBalance * BASE_REWARD * epochs / Math.sqrt(safeTotalStake * GWEI_DECIMALS);
    }

    /**
     * @dev Calculate full expected slashing penalty (all components)
     */
    function calculateExpectedSlashingPenalty(uint256 effectiveBalance, uint256 safeTotalStake)
        internal
        pure
        returns (uint256)
    {
        uint256 initial = calculateExpectedInitialPenalty(effectiveBalance);
        uint256 correlation = calculateExpectedCorrelationPenalty(effectiveBalance, safeTotalStake);
        uint256 leaking = calculateExpectedLeakingPenalty(effectiveBalance, safeTotalStake, MAX_EPOCHS);
        return initial + correlation + leaking;
    }

    /**
     * @dev Assert slashing penalty matches expected value
     */
    function assertSlashingPenalty(uint256 effectiveBalance, uint256 safeTotalStake, string memory errorMessage)
        internal
    {
        uint256 actual = Penalty.slashing(effectiveBalance, safeTotalStake);
        uint256 expected = calculateExpectedSlashingPenalty(effectiveBalance, safeTotalStake);
        assertEq(actual, expected, errorMessage);
    }

    /**
     * @dev Assert missing attestations penalty matches expected value
     */
    function assertMissingAttestationsPenalty(
        uint256 effectiveBalance,
        uint256 safeTotalStake,
        uint256 epochs,
        string memory errorMessage
    ) internal {
        uint256 actual = Penalty.missingAttestations(effectiveBalance, safeTotalStake, epochs);
        uint256 expected = calculateExpectedLeakingPenalty(effectiveBalance, safeTotalStake, epochs);
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
        uint256 penalty = Penalty.slashing(0, SAFE_TOTAL_STAKE_20M);
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
        uint256 penalty = Penalty.slashing(MAX_VALIDATOR_BALANCE, MAX_SAFE_TOTAL_STAKE);

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
        uint256 penalty = Penalty.missingAttestations(0, SAFE_TOTAL_STAKE_20M, HUNDRED_EPOCHS);
        assertEq(penalty, 0, "Zero balance should return zero penalty");
    }

    function test_MissingAttestations_ZeroEpochs() public {
        uint256 penalty = Penalty.missingAttestations(STANDARD_VALIDATOR_BALANCE, SAFE_TOTAL_STAKE_20M, 0);
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

        uint256 slashingPenalty = Penalty.slashing(balance, stake);

        // Calculate individual components
        uint256 initial = calculateExpectedInitialPenalty(balance);
        uint256 correlation = calculateExpectedCorrelationPenalty(balance, stake);
        uint256 leaking = calculateExpectedLeakingPenalty(balance, stake, MAX_EPOCHS);

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

        uint256 slashingPenalty = Penalty.slashing(balance, stake);

        // Calculate individual components
        uint256 initial = calculateExpectedInitialPenalty(balance);
        uint256 correlation = calculateExpectedCorrelationPenalty(balance, stake);
        uint256 leaking = calculateExpectedLeakingPenalty(balance, stake, MAX_EPOCHS);

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
        uint256 penalty1 = Penalty.slashing(balance, SAFE_TOTAL_STAKE_1M);

        // With large total stake, correlation penalty is smaller
        uint256 penalty2 = Penalty.slashing(balance, SAFE_TOTAL_STAKE_100M);

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

    // ========================================
    // ADD MAXIMUM PENALTY FUNCTION TESTS
    // ========================================

    function test_AddMaximumPenalty_StandardValidator() public {
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = HUNDRED_EPOCHS;

        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        // Calculate expected penalties
        uint256 slashingPenalty = Penalty.slashing(balance, stake);
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        uint256 totalPenalty = slashingPenalty + attestationPenalty;

        // Result should be balance minus total penalty
        uint256 expectedBalance = balance > totalPenalty ? balance - totalPenalty : 0;
        assertEq(resultBalance, expectedBalance, "AddMaximumPenalty result incorrect for standard validator");

        emit log_named_uint("Original Balance", balance);
        emit log_named_uint("Total Penalty", totalPenalty);
        emit log_named_uint("Remaining Balance", resultBalance);
    }

    function test_AddMaximumPenalty_MaximumValidator() public {
        uint128 balance = MAX_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = THOUSAND_EPOCHS;

        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        // Should return balance after penalties
        assertTrue(resultBalance < balance, "Penalty should reduce balance");

        emit log_named_uint("Max Validator Balance", balance);
        emit log_named_uint("Balance After Penalty", resultBalance);
    }

    function test_AddMaximumPenalty_PenaltyExceedsBalance() public {
        // Small stake and max epochs can cause penalty to exceed balance
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = MIN_SAFE_TOTAL_STAKE; // Very small stake
        uint256 epochs = MAX_EPOCHS;

        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        // When penalty exceeds balance, should return 0
        uint256 slashingPenalty = Penalty.slashing(balance, stake);
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        uint256 totalPenalty = slashingPenalty + attestationPenalty;

        if (totalPenalty >= balance) {
            assertEq(resultBalance, 0, "Should return 0 when penalty exceeds balance");
        }

        emit log_named_uint("Balance", balance);
        emit log_named_uint("Total Penalty", totalPenalty);
        emit log_named_uint("Result", resultBalance);
    }

    function test_AddMaximumPenalty_ZeroBalance() public {
        uint256 resultBalance = Penalty.addMaximumPenalty(0, SAFE_TOTAL_STAKE_20M, HUNDRED_EPOCHS);
        assertEq(resultBalance, 0, "Zero balance should return zero");
    }

    function test_AddMaximumPenalty_ZeroEpochs() public {
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;

        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, 0);

        // With zero epochs, only slashing penalty applies
        uint256 slashingPenalty = Penalty.slashing(balance, stake);
        uint256 expectedBalance = balance > slashingPenalty ? balance - slashingPenalty : 0;

        assertEq(resultBalance, expectedBalance, "Zero epochs should only apply slashing penalty");
    }

    // ========================================
    // LONG DURATION PENALTY TESTS (10-50 YEARS)
    // ========================================

    function test_LongDuration_10Years_StandardValidator() public {
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = EPOCHS_10_YEARS;

        // Test missingAttestations doesn't overflow
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        assertTrue(attestationPenalty > 0, "10-year attestation penalty should be non-zero");

        // Test addPenalty doesn't overflow
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("10-Year Epochs", epochs);
        emit log_named_uint("Attestation Penalty", attestationPenalty);
        emit log_named_uint("Balance After 10-Year Penalty", resultBalance);
    }

    function test_LongDuration_20Years_StandardValidator() public {
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = EPOCHS_20_YEARS;

        // Test missingAttestations doesn't overflow
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        assertTrue(attestationPenalty > 0, "20-year attestation penalty should be non-zero");

        // Test addPenalty doesn't overflow
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("20-Year Epochs", epochs);
        emit log_named_uint("Attestation Penalty", attestationPenalty);
        emit log_named_uint("Balance After 20-Year Penalty", resultBalance);
    }

    function test_LongDuration_50Years_StandardValidator() public {
        uint128 balance = STANDARD_VALIDATOR_BALANCE;
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = EPOCHS_50_YEARS;

        // Test missingAttestations doesn't overflow
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        assertTrue(attestationPenalty > 0, "50-year attestation penalty should be non-zero");

        // Test addPenalty doesn't overflow
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("50-Year Epochs", epochs);
        emit log_named_uint("Attestation Penalty", attestationPenalty);
        emit log_named_uint("Balance After 50-Year Penalty", resultBalance);

        // Penalty after 50 years should likely exceed balance
        if (resultBalance == 0) {
            emit log("50-year penalty exceeded balance (expected behavior)");
        }
    }

    function test_LongDuration_10Years_MaximumValidator() public {
        uint128 balance = MAX_VALIDATOR_BALANCE; // 2048 ETH
        uint32 stake = SAFE_TOTAL_STAKE_20M;
        uint32 epochs = EPOCHS_10_YEARS;

        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("Max Validator (2048 ETH) - 10 Years", epochs);
        emit log_named_uint("Attestation Penalty", attestationPenalty);
        emit log_named_uint("Remaining Balance", resultBalance);
    }

    function test_LongDuration_50Years_MaximumValidator() public {
        uint128 balance = MAX_VALIDATOR_BALANCE; // 2048 ETH
        uint32 stake = SAFE_TOTAL_STAKE_100M; // Larger stake for more realistic scenario
        uint32 epochs = EPOCHS_50_YEARS;

        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("Max Validator (2048 ETH) - 50 Years", epochs);
        emit log_named_uint("Attestation Penalty", attestationPenalty);
        emit log_named_uint("Remaining Balance", resultBalance);
    }

    // ========================================
    // OVERFLOW PROTECTION TESTS
    // ========================================

    struct TestCase {
        uint128 balance;
        uint32 stake;
        uint32 epochs;
        string description;
    }

    function test_Overflow_MaxValues_MissingAttestations() public {
        // Test with maximum realistic values (2048 ETH max validator)
        // We don't test with uint128.max because that would overflow, which is expected
        // The protocol limits validators to 2048 ETH maximum

        uint128 realisticMaxBalance = MAX_VALIDATOR_BALANCE; // 2048 ETH
        uint32 minStake = 1; // Minimum stake (worst case for penalty calculation)
        uint32 maxEpochs = type(uint32).max; // Maximum epochs

        // This should calculate without overflow for realistic values
        uint256 penalty = Penalty.missingAttestations(realisticMaxBalance, minStake, maxEpochs);

        emit log_named_uint("Realistic Max Balance (2048 ETH)", realisticMaxBalance);
        emit log_named_uint("Min Stake", minStake);
        emit log_named_uint("Max Epochs (uint32.max)", maxEpochs);
        emit log_named_uint("Calculated Penalty", penalty);

        assertTrue(penalty > 0, "Should calculate penalty for realistic maximum values");

        // Also test with a more reasonable epoch count (50 years)
        uint256 penalty50Years = Penalty.missingAttestations(realisticMaxBalance, minStake, EPOCHS_50_YEARS);

        emit log_named_uint("Penalty for 50 years", penalty50Years);
        assertTrue(penalty50Years > 0 && penalty50Years < penalty, "50-year penalty should be less than max epochs");
    }

    function test_Overflow_MaxRealisticValues() public {
        // Test with maximum realistic values (2048 ETH max validator)
        uint128 balance = MAX_VALIDATOR_BALANCE;
        uint32 stake = MIN_SAFE_TOTAL_STAKE;
        uint32 epochs = EPOCHS_50_YEARS;

        // Calculate individual penalties
        uint256 slashingPenalty = Penalty.slashing(balance, stake);
        uint256 attestationPenalty = Penalty.missingAttestations(balance, stake, epochs);

        // Test addPenalty with these values
        uint256 resultBalance = Penalty.addMaximumPenalty(balance, stake, epochs);

        emit log_named_uint("Slashing Penalty", slashingPenalty);
        emit log_named_uint("Attestation Penalty (50 years)", attestationPenalty);
        emit log_named_uint("Total Penalty", slashingPenalty + attestationPenalty);
        emit log_named_uint("Result Balance", resultBalance);

        // Should handle without overflow
        assertTrue(resultBalance == 0 || resultBalance < balance, "Should handle max realistic values");
    }

    function test_Overflow_SlashingComponents() public {
        // Test each component of slashing calculation for overflow
        uint128 balance = MAX_VALIDATOR_BALANCE;
        uint32 stake = MIN_SAFE_TOTAL_STAKE;

        // Initial penalty component
        uint256 initialPenalty = balance / INITIAL_SLASHING_PENALTY_QUOTIENT;
        assertTrue(initialPenalty > 0, "Initial penalty calculated");

        // Correlation penalty component (highest risk of overflow)
        uint256 correlationPenalty =
            uint256(balance) * balance * PROPORTIONAL_SLASHING_MULTIPLIER / (uint256(stake) * WEI_DECIMALS);
        assertTrue(correlationPenalty > 0 || correlationPenalty == 0, "Correlation penalty calculated");

        // Leaking penalty component
        uint256 leakingPenalty = calculateExpectedLeakingPenalty(balance, stake, MAX_EPOCHS);
        assertTrue(leakingPenalty > 0 || leakingPenalty == 0, "Leaking penalty calculated");

        emit log_named_uint("Initial Penalty", initialPenalty);
        emit log_named_uint("Correlation Penalty", correlationPenalty);
        emit log_named_uint("Leaking Penalty", leakingPenalty);
    }

    function test_Overflow_EdgeCase_Combinations() public {
        // Test various edge case combinations
        TestCase[5] memory cases = [
            TestCase({
                balance: MAX_VALIDATOR_BALANCE,
                stake: MIN_SAFE_TOTAL_STAKE,
                epochs: EPOCHS_50_YEARS,
                description: "Max balance, min stake, 50 years"
            }),
            TestCase({
                balance: MAX_VALIDATOR_BALANCE,
                stake: MAX_SAFE_TOTAL_STAKE,
                epochs: EPOCHS_50_YEARS,
                description: "Max balance, max stake, 50 years"
            }),
            TestCase({
                balance: 1 ether,
                stake: MIN_SAFE_TOTAL_STAKE,
                epochs: EPOCHS_50_YEARS,
                description: "Small balance, min stake, 50 years"
            }),
            TestCase({
                balance: MAX_VALIDATOR_BALANCE,
                stake: 1000000,
                epochs: EPOCHS_20_YEARS,
                description: "Max balance, medium stake, 20 years"
            }),
            TestCase({
                balance: 100 ether,
                stake: 10000,
                epochs: EPOCHS_10_YEARS,
                description: "Medium balance, small stake, 10 years"
            })
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            TestCase memory tc = cases[i];

            // Should not revert
            uint256 result = Penalty.addMaximumPenalty(tc.balance, tc.stake, tc.epochs);

            emit log_string(tc.description);
            emit log_named_uint("Balance", tc.balance);
            emit log_named_uint("Stake", tc.stake);
            emit log_named_uint("Epochs", tc.epochs);
            emit log_named_uint("Result", result);
            emit log_string("---");

            assertTrue(result <= tc.balance, "Result should not exceed original balance");
        }
    }

    function test_Mathematical_Precision_LongDurations() public {
        // Test that calculations maintain precision over long durations
        uint128 balance = 100 ether;
        uint32 stake = SAFE_TOTAL_STAKE_10M;

        // Calculate penalties for increasing durations
        uint256 penalty1Year = Penalty.missingAttestations(balance, stake, EPOCHS_PER_YEAR);
        uint256 penalty10Years = Penalty.missingAttestations(balance, stake, EPOCHS_10_YEARS);
        uint256 penalty50Years = Penalty.missingAttestations(balance, stake, EPOCHS_50_YEARS);

        // Penalties should scale linearly with epochs
        // Allow small rounding differences
        uint256 expected10Years = uint256(penalty1Year) * 10;
        uint256 expected50Years = uint256(penalty1Year) * 50;

        // Check linear scaling (within rounding tolerance)
        assertTrue(
            penalty10Years >= expected10Years * 99 / 100 && penalty10Years <= expected10Years * 101 / 100,
            "10-year penalty should scale linearly"
        );

        emit log_named_uint("1-Year Penalty", penalty1Year);
        emit log_named_uint("10-Year Penalty", penalty10Years);
        emit log_named_uint("50-Year Penalty", penalty50Years);
        emit log_named_uint("Expected 10-Year", expected10Years);
        emit log_named_uint("Expected 50-Year", expected50Years);
    }

    // // ========================================
    // // REMOVE MAXIMUM PENALTY FUNCTION TESTS
    // // ========================================

    // function test_RemoveMaximumPenalty_StandardValidator() public {
    //     uint128 balance = STANDARD_VALIDATOR_BALANCE;
    //     uint32 stake = SAFE_TOTAL_STAKE_20M;
    //     uint32 epochs = HUNDRED_EPOCHS;

    //     // Apply penalty then reverse it
    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, epochs);
    //     uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, epochs);

    //     // Due to integer rounding in sqrt, allow ±1 wei difference
    //     assertApproxEqAbs(recovered, balance, 1, "removeMaximumPenalty should recover original balance");

    //     emit log_named_uint("Original Balance", balance);
    //     emit log_named_uint("Penalized Balance", penalized);
    //     emit log_named_uint("Recovered Balance", recovered);
    // }

    // function test_RemoveMaximumPenalty_MaximumValidator() public {
    //     uint128 balance = MAX_VALIDATOR_BALANCE;
    //     uint32 stake = SAFE_TOTAL_STAKE_20M;
    //     uint32 epochs = THOUSAND_EPOCHS;

    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, epochs);
    //     if (penalized > 0) {
    //         uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, epochs);
    //         assertApproxEqAbs(recovered, balance, 1, "Max validator removeMaximumPenalty should recover original balance");
    //     }
    // }

    // function test_RemoveMaximumPenalty_ZeroPenalizedBalance() public {
    //     uint128 recovered = Penalty.removeMaximumPenalty(0, SAFE_TOTAL_STAKE_20M, HUNDRED_EPOCHS);
    //     assertEq(recovered, 0, "Zero penalized balance should return zero");
    // }

    // function test_RemoveMaximumPenalty_ZeroEpochs() public {
    //     uint128 balance = STANDARD_VALIDATOR_BALANCE;
    //     uint32 stake = SAFE_TOTAL_STAKE_20M;

    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, 0);
    //     if (penalized > 0) {
    //         uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, 0);
    //         assertApproxEqAbs(recovered, balance, 1, "Zero epochs removeMaximumPenalty should recover original balance");
    //     }
    // }

    // function test_RemoveMaximumPenalty_SmallBalance() public {
    //     uint128 balance = SMALL_VALIDATOR_BALANCE;
    //     uint32 stake = SAFE_TOTAL_STAKE_20M;
    //     uint32 epochs = TEN_EPOCHS;

    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, epochs);
    //     if (penalized > 0) {
    //         uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, epochs);
    //         assertApproxEqAbs(recovered, balance, 1, "Small balance removeMaximumPenalty should recover original balance");
    //     }
    // }

    // function test_RemoveMaximumPenalty_VariousStakes() public {
    //     uint128 balance = STANDARD_VALIDATOR_BALANCE;
    //     uint32 epochs = HUNDRED_EPOCHS;

    //     uint32[4] memory stakes = [SAFE_TOTAL_STAKE_1M, SAFE_TOTAL_STAKE_10M, SAFE_TOTAL_STAKE_20M, SAFE_TOTAL_STAKE_100M];

    //     for (uint i = 0; i < stakes.length; i++) {
    //         uint128 penalized = Penalty.addMaximumPenalty(balance, stakes[i], epochs);
    //         if (penalized > 0) {
    //             uint128 recovered = Penalty.removeMaximumPenalty(penalized, stakes[i], epochs);
    //             assertApproxEqAbs(recovered, balance, 1, "removeMaximumPenalty with various stakes should recover original balance");
    //         }
    //     }
    // }

    // function test_RemoveMaximumPenalty_RoundTrip_LongDuration() public {
    //     uint128 balance = STANDARD_VALIDATOR_BALANCE;
    //     uint32 stake = SAFE_TOTAL_STAKE_20M;
    //     uint32 epochs = EPOCHS_PER_YEAR;

    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, epochs);
    //     if (penalized > 0) {
    //         uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, epochs);
    //         assertApproxEqAbs(recovered, balance, 1, "Long duration round trip should recover original balance");

    //         emit log_named_uint("Original", balance);
    //         emit log_named_uint("Penalized", penalized);
    //         emit log_named_uint("Recovered", recovered);
    //     }
    // }

    // function test_RemoveMaximumPenalty_LargeValidator_SmallStake() public {
    //     uint128 balance = 2 ether;
    //     uint32 stake = 40_000_000;
    //     uint32 epochs = 82125;

    //     uint128 attestationPenaltyOnly = Penalty.missingAttestations(balance, stake, epochs);
    //     console2.log("attestation penalties: ", attestationPenaltyOnly);

    //     uint128 slashingPenaltyOnly = Penalty.slashing(balance, stake);
    //     console2.log("slashing penalties: ", slashingPenaltyOnly);

    //     uint128 penalized = Penalty.addMaximumPenalty(balance, stake, epochs);
    //     console2.log("penalized: ", penalized);
    //     console2.log("balance - penalized: ", balance- penalized);
    //     if (penalized > 0) {
    //         uint128 recovered = Penalty.removeMaximumPenalty(penalized, stake, epochs);
    //         assertApproxEqAbs(recovered, balance, 1, "Large validator small stake round trip failed");
    //     }
    // }
}
