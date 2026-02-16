//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest} from "./BaseTest.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title CofferFactoryTest
 * @notice Comprehensive unit tests for CofferFactory contract
 * @dev Tests follow logical progression: happy cases, require triggers, modifiers, edge cases
 */
contract CofferFactoryTest is BaseTest {
    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
    }

    // ========================================
    // HAPPY CASES
    // ========================================

    function test_CreateCoffer_Success() public {
        // Act
        address cofferAddr = createDefaultCoffer();

        // Assert
        assertTrue(cofferAddr != address(0), "Coffer address should not be zero");

        // Verify coffer parameters
        Coffer createdCoffer = Coffer(payable(cofferAddr));
        assertEq(createdCoffer.owner(), validator, "Validator should be owner");
        assertEq(createdCoffer.i_public_key_part1(), validPublicKeyPart1, "Public key part1 mismatch");
        assertEq(createdCoffer.i_public_key_part2(), validPublicKeyPart2, "Public key part2 mismatch");
        assertEq(createdCoffer.i_cofferBondNftAddress(), address(bondNft), "NFT address mismatch");

        // Verify validator conditions
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 unrepaidBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = createdCoffer.s_validatorConditions();

        assertEq(availableAmount, defaultAvailableAmount, "Available amount mismatch");
        assertEq(interestRate, defaultInterestRate, "Interest rate mismatch");
        assertEq(minimumDuration, defaultMinDuration, "Min duration mismatch");
        assertEq(maximumDuration, defaultMaxDuration, "Max duration mismatch");
        assertEq(version, 0, "Initial version should be 0");
        assertEq(minimumAmountToAccept, defaultMinimumAmount, "Min amount to accept mismatch");
        assertEq(unrepaidBonds, 0, "Should have no unpayed bonds initially");
        assertTrue(isActive, "Coffer should be active initially");
        assertEq(exitAllowed, defaultExitAllowed, "Exit allowed mismatch");
    }

    function test_CreateMultipleCoffers_DifferentValidators() public {
        // Arrange
        address validator2 = makeAddr("validator2");
        vm.deal(validator2, 100 ether);

        // Act - Create first coffer
        address coffer1 = createDefaultCoffer();

        // Act - Create second coffer with different validator
        address coffer2 = createCoffer(
            validator2,
            bytes32(uint256(10)),
            bytes16(uint128(20)),
            LOW_RATE,
            ONE_WEEK,
            SIX_MONTHS,
            50 ether,
            0.5 ether,
            defaultSafeTotalStake,
            true
        );

        // Assert
        assertTrue(coffer1 != coffer2, "Coffers should have different addresses");
        assertEq(Coffer(payable(coffer1)).owner(), validator, "Coffer1 owner mismatch");
        assertEq(Coffer(payable(coffer2)).owner(), validator2, "Coffer2 owner mismatch");
    }

    function test_CreateCoffer_WithMinimumValidParameters() public {
        // Act
        address cofferAddr = createCoffer(
            validator,
            bytes32(uint256(1)),
            bytes16(uint128(1)),
            MIN_RATE, // 1%
            1, // 1 second minimum duration
            1, // 1 second maximum duration
            MIN_AMOUNT, // 0.01 ether available
            MIN_AMOUNT, // 0.01 ether minimum
            defaultSafeTotalStake,
            false
        );

        // Assert
        assertTrue(cofferAddr != address(0), "Coffer should be created");

        Coffer createdCoffer = Coffer(payable(cofferAddr));
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,,,,,
        ) = createdCoffer.s_validatorConditions();

        assertEq(availableAmount, MIN_AMOUNT, "Available amount should be minimum");
        assertEq(interestRate, MIN_RATE, "Interest rate should be minimum");
        assertEq(minimumDuration, 1, "Min duration should be 1");
        assertEq(maximumDuration, 1, "Max duration should be 1");
        assertEq(minimumAmountToAccept, MIN_AMOUNT, "Min amount to accept should be minimum");
    }

    function test_CreateCoffer_WithMaximumValidParameters() public {
        // Act
        address cofferAddr = createCoffer(
            validator,
            bytes32(type(uint256).max),
            bytes16(type(uint128).max),
            HIGH_RATE, // 100%
            1,
            MAX_REALISTIC_DURATION, // 50 years
            MAX_REALISTIC_AMOUNT, // 1 million ETH
            MIN_AMOUNT,
            defaultSafeTotalStake,
            true
        );

        // Assert
        assertTrue(cofferAddr != address(0), "Coffer should be created");

        Coffer createdCoffer = Coffer(payable(cofferAddr));
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,,,,,,
            bool exitAllowed
        ) = createdCoffer.s_validatorConditions();

        assertEq(availableAmount, MAX_REALISTIC_AMOUNT, "Available amount should be maximum");
        assertEq(interestRate, HIGH_RATE, "Interest rate should be maximum");
        assertEq(minimumDuration, 1, "Min duration should be 1");
        assertEq(maximumDuration, MAX_REALISTIC_DURATION, "Max duration should be maximum");
        assertTrue(exitAllowed, "Exit should be allowed");
    }

    // ========================================
    // TRIGGER REQUIRES - INVALID DURATION
    // ========================================

    function test_CreateCoffer_RevertIf_MinimumDurationIsZero() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            0, // Invalid: zero minimum duration
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    function test_CreateCoffer_RevertIf_MaximumDurationLessThanMinimum() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            ONE_YEAR, // minimum: 1 year
            ONE_MONTH, // maximum: 1 month (less than minimum)
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    // ========================================
    // TRIGGER REQUIRES - INVALID INTEREST RATE
    // ========================================

    function test_CreateCoffer_RevertIf_InterestRateIsZero() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.InvalidInterestRate.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            0, // Invalid: zero interest rate
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    function test_CreateCoffer_RevertIf_InterestRateExceedsMaximum() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.InvalidInterestRate.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            HIGH_RATE + 1, // Invalid: exceeds 100%
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    // ========================================
    // TRIGGER REQUIRES - INVALID AMOUNTS
    // ========================================

    function test_CreateCoffer_RevertIf_MinimumAmountToAcceptIsZero() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.MinimumAmountToAcceptIsZero.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            0, // Invalid: zero minimum amount
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    function test_CreateCoffer_RevertIf_AvailableAmountLessThanMinimum() public {
        vm.startPrank(validator);
        vm.expectRevert(CofferFactory.MinimumAmountToAcceptGreaterThanAvailableAmount.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            10 ether, // available amount
            11 ether, // minimum amount (greater than available)
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        vm.stopPrank();
    }

    // ========================================
    // EDGE CASES
    // ========================================

    function test_CreateCoffer_EdgeCase_EqualMinMaxDuration() public {
        // Arrange
        uint32 singleDuration = ONE_MONTH;

        // Act
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            singleDuration,
            singleDuration, // Same as minimum
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        // Assert
        Coffer createdCoffer = Coffer(payable(cofferAddr));
        (,, uint32 minimumDuration, uint32 maximumDuration,,,,,,) = createdCoffer.s_validatorConditions();

        assertEq(minimumDuration, singleDuration, "Min duration mismatch");
        assertEq(maximumDuration, singleDuration, "Max duration mismatch");
    }

    function test_CreateCoffer_EdgeCase_AvailableAmountEqualsMinimum() public {
        // Arrange
        uint128 singleAmount = 5 ether;

        // Act
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            singleAmount, // available amount
            singleAmount, // Same as available
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        // Assert
        Coffer createdCoffer = Coffer(payable(cofferAddr));
        (uint128 availableAmount,,,, uint128 minimumAmountToAccept,,,,,) = createdCoffer.s_validatorConditions();

        assertEq(availableAmount, singleAmount, "Available amount mismatch");
        assertEq(minimumAmountToAccept, singleAmount, "Min amount to accept mismatch");
    }

    function test_CreateCoffer_EdgeCase_MaximumInterestRate() public {
        // Act
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            HIGH_RATE, // Exactly 100%
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        // Assert
        Coffer createdCoffer = Coffer(payable(cofferAddr));
        (, uint32 interestRate,,,,,,,,) = createdCoffer.s_validatorConditions();

        assertEq(interestRate, HIGH_RATE, "Interest rate should be exactly 100%");
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    function test_CreateCoffer_GasUsage() public {
        // Measure gas for creating a coffer
        vm.startPrank(validator);

        uint256 gasBefore = gasleft();
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        // Log gas usage for optimization tracking
        emit log_named_uint("Gas used for coffer creation", gasUsed);

        // Assert reasonable gas usage (adjust threshold as needed)
        assertTrue(gasUsed < 10_000_000, "Gas usage exceeds expected threshold");
    }

    // ========================================
    // IMMUTABILITY TESTS
    // ========================================

    function test_NFTAddress_IsImmutable() public {
        // Assert that NFT address is set and immutable
        address nftAddress1 = factory.I_COFFER_BOND_NFT_ADDRESS();
        assertTrue(nftAddress1 != address(0), "NFT address should be set");

        // Deploy another factory
        CofferFactory factory2 = new CofferFactory();
        address nftAddress2 = factory2.I_COFFER_BOND_NFT_ADDRESS();

        // Each factory should have its own NFT
        assertTrue(nftAddress2 != address(0), "Second NFT address should be set");
        assertTrue(nftAddress1 != nftAddress2, "Each factory should have unique NFT");
    }
}
