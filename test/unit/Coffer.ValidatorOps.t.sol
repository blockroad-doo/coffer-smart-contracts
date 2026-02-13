//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest, CofferEvents} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title CofferValidatorOpsTest
 * @notice Comprehensive unit tests for Coffer validator operations
 * @dev Tests repayBondsEarly, validator withdrawals, and state changes
 */
contract CofferValidatorOpsTest is BaseTest {
    address public cofferAddress;
    Coffer public targetCoffer;
    uint256 public holderId1;
    uint256 public holderId2;
    uint128 public bondAmount = 10 ether;
    uint32 public bondDuration = SIX_MONTHS;

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
        cofferAddress = createDefaultCoffer();
        targetCoffer = Coffer(payable(cofferAddress));

        // Create some bonds for testing
        holderId1 = buyBond(cofferAddress, holder1, bondAmount, bondDuration, 0);
        holderId2 = buyBond(cofferAddress, holder2, bondAmount * 2, bondDuration, 0);
    }

    // ========================================
    // REPAY BONDS EARLY - HAPPY CASES
    // ========================================

    function test_RepayBondsEarly_Success_SingleBond() public {
        // Arrange
        uint128 expectedInterest = calculateExpectedInterest(bondAmount, bondDuration, defaultInterestRate);
        uint128 totalAmount = bondAmount + expectedInterest;
        vm.deal(cofferAddress, totalAmount);

        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId1;

        uint256 holderBalanceBefore = holder1.balance;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(true, true, false, true);
        emit CofferEvents.ValidatorBondRepayed(holder1, holderId1, totalAmount);
        targetCoffer.repayBondsEarly(holderIds);
        vm.stopPrank();

        // Assert
        assertEq(holder1.balance, holderBalanceBefore + totalAmount, "Holder should receive full amount");

        // Verify holder conditions cleared
        (uint128 amount, , ) = targetCoffer.s_holderConditions(holderId1);
        assertEq(amount, 0, "Holder conditions should be cleared");

        // Verify validator conditions updated
        (uint128 availableAmount, , , , , , uint32 unrepayedBonds, , ) = targetCoffer.s_validatorConditions();
        assertEq(unrepayedBonds, 1, "Should have 1 remaining unpayed bond");
    }

    function test_RepayBondsEarly_Success_MultipleBonds() public {
        // Arrange
        uint128 interest1 = calculateExpectedInterest(bondAmount, bondDuration, defaultInterestRate);
        uint128 interest2 = calculateExpectedInterest(bondAmount * 2, bondDuration, defaultInterestRate);
        uint128 total1 = bondAmount + interest1;
        uint128 total2 = bondAmount * 2 + interest2;

        vm.deal(cofferAddress, total1 + total2);

        uint256[] memory holderIds = new uint256[](2);
        holderIds[0] = holderId1;
        holderIds[1] = holderId2;

        // Act
        vm.prank(validator);
        targetCoffer.repayBondsEarly(holderIds);

        // Assert
        (uint128 amount1, , ) = targetCoffer.s_holderConditions(holderId1);
        (uint128 amount2, , ) = targetCoffer.s_holderConditions(holderId2);
        assertEq(amount1, 0, "Holder1 conditions should be cleared");
        assertEq(amount2, 0, "Holder2 conditions should be cleared");

        (uint128 availableAmount, , , , , , uint32 unrepayedBonds, , ) = targetCoffer.s_validatorConditions();
        assertEq(unrepayedBonds, 0, "Should have no unpayed bonds");
        assertEq(availableAmount, defaultAvailableAmount, "Available amount should be fully restored");
    }

    function test_RepayBondsEarly_Success_WithMsgValue() public {
        // Arrange - Contract has insufficient balance, validator sends ETH
        uint128 interest1 = calculateExpectedInterest(bondAmount, bondDuration, defaultInterestRate);
        uint128 total1 = bondAmount + interest1;

        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId1;

        // Act - Validator sends ETH with the call
        vm.prank(validator);
        targetCoffer.repayBondsEarly{value: total1}(holderIds);

        // Assert
        (uint128 amount, , ) = targetCoffer.s_holderConditions(holderId1);
        assertEq(amount, 0, "Holder conditions should be cleared");
    }

    // ========================================
    // REPAY BONDS EARLY - REQUIRE TRIGGERS
    // ========================================

    function test_RepayBondsEarly_RevertIf_HolderDoesNotExist() public {
        // Arrange
        vm.deal(cofferAddress, 100 ether);
        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = 999; // Non-existent holder

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector));
        targetCoffer.repayBondsEarly(holderIds);
        vm.stopPrank();
    }

    function test_RepayBondsEarly_RevertIf_InsufficientBalance() public {
        // Arrange - Don't fund the contract
        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId1;

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ContractBalanceLessThanAmount.selector));
        targetCoffer.repayBondsEarly(holderIds);
        vm.stopPrank();
    }

    function test_RepayBondsEarly_RevertIf_NotOwner() public {
        // Arrange
        vm.deal(cofferAddress, 100 ether);
        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId1;

        // Act & Assert
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        targetCoffer.repayBondsEarly(holderIds);
        vm.stopPrank();
    }

    // ========================================
    // VALIDATOR WITHDRAW FROM EXECUTION - HAPPY CASES
    // ========================================

    function test_ValidatorWithdrawFromExecution_Success_NoBonds() public {
        // Arrange - Create coffer without bonds
        address noBondCoffer = createCoffer(
            validator,
            bytes32(uint256(777)),
            bytes16(uint128(777)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            false
        );
        vm.deal(noBondCoffer, 50 ether);

        uint256 validatorBalanceBefore = validator.balance;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorWithdrawFromExecution(50 ether);
        Coffer(payable(noBondCoffer)).validatorWithdrawFromExecution(50 ether);
        vm.stopPrank();

        // Assert
        assertEq(validator.balance, validatorBalanceBefore + 50 ether, "Validator should receive withdrawal");
        assertEq(noBondCoffer.balance, 0, "Contract should be empty");
    }

    function test_ValidatorWithdrawFromExecution_Success_WithBonds_UnderAvailable() public {
        // Arrange
        vm.deal(cofferAddress, 30 ether);
        (uint128 availableBefore, , , , , , , , ) = targetCoffer.s_validatorConditions();

        // Act - Withdraw less than available
        uint128 withdrawAmount = 5 ether;
        vm.prank(validator);
        targetCoffer.validatorWithdrawFromExecution(withdrawAmount);

        // Assert
        (uint128 availableAfter, , , , , , , , ) = targetCoffer.s_validatorConditions();
        assertEq(availableAfter, availableBefore - withdrawAmount, "Available amount should decrease");
    }

    function test_ValidatorWithdrawFromExecution_Success_ExactlyAvailable() public {
        // Arrange
        (uint128 availableAmount, , , , , , , , ) = targetCoffer.s_validatorConditions();
        vm.deal(cofferAddress, availableAmount);

        // Act
        vm.prank(validator);
        targetCoffer.validatorWithdrawFromExecution(availableAmount);

        // Assert
        (uint128 newAvailable, , , , , , , , ) = targetCoffer.s_validatorConditions();
        assertEq(newAvailable, 0, "Available amount should be zero");
    }

    // ========================================
    // VALIDATOR WITHDRAW FROM EXECUTION - REQUIRE TRIGGERS
    // ========================================

    function test_ValidatorWithdrawFromExecution_RevertIf_ExceedsAvailable() public {
        // Arrange
        (uint128 availableAmount, , , , , , , , ) = targetCoffer.s_validatorConditions();
        vm.deal(cofferAddress, availableAmount + 10 ether);

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ValidatorDoesNotHaveEnoughAvailableAmount.selector));
        targetCoffer.validatorWithdrawFromExecution(availableAmount + 1);
        vm.stopPrank();
    }

    function test_ValidatorWithdrawFromExecution_RevertIf_InsufficientBalance() public {
        // Arrange
        vm.deal(cofferAddress, 5 ether);

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ContractBalanceLessThanAmount.selector));
        targetCoffer.validatorWithdrawFromExecution(10 ether);
        vm.stopPrank();
    }

    function test_ValidatorWithdrawFromExecution_RevertIf_NotOwner() public {
        // Arrange
        vm.deal(cofferAddress, 10 ether);

        // Act & Assert
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        targetCoffer.validatorWithdrawFromExecution(5 ether);
        vm.stopPrank();
    }

    // ========================================
    // VALIDATOR WITHDRAW FROM CONSENSUS
    // ========================================

    function test_ValidatorWithdrawFromConsensus_Success_NoBonds() public {
        // Arrange - Create coffer without bonds
        address noBondCoffer = createCoffer(
            validator,
            bytes32(uint256(888)),
            bytes16(uint128(888)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            false
        );

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorWithdrawFromConsensus(50 ether);
        Coffer(payable(noBondCoffer)).validatorWithdrawFromConsensus{value: 1}(50 ether);
        vm.stopPrank();

        // Assert - Function executes without revert
        assertTrue(true, "Consensus withdrawal should succeed");
    }

    function test_ValidatorWithdrawFromConsensus_Success_WithBonds() public {
        // Arrange
        (uint128 availableBefore, , , , , , , , ) = targetCoffer.s_validatorConditions();
        uint128 withdrawAmount = 5 ether;

        // Act
        vm.prank(validator);
        targetCoffer.validatorWithdrawFromConsensus{value: 1}(withdrawAmount);

        // Assert
        (uint128 availableAfter, , , , , , , , ) = targetCoffer.s_validatorConditions();
        assertEq(availableAfter, availableBefore - withdrawAmount, "Available should decrease");
    }

    function test_ValidatorWithdrawFromConsensus_RevertIf_ExceedsAvailable() public {
        // Arrange
        (uint128 availableAmount, , , , , , , , ) = targetCoffer.s_validatorConditions();

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ValidatorDoesNotHaveEnoughAvailableAmount.selector));
        targetCoffer.validatorWithdrawFromConsensus{value: 1}(availableAmount + 1);
        vm.stopPrank();
    }

    function test_ValidatorWithdrawFromConsensus_RevertIf_InsufficientPrecompileFee() public {
        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.InsufficientPrecompileFee.selector));
        targetCoffer.validatorWithdrawFromConsensus{value: 0}(5 ether);
        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - ACTIVITY
    // ========================================

    function test_ChangeCofferActivity_Success_DeactivateAndReactivate() public {
        // Arrange
        (uint128 available, , , , , , , bool isActive, ) = targetCoffer.s_validatorConditions();
        assertTrue(isActive, "Should start active");

        // Act - Deactivate
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferDeactivated();
        targetCoffer.changeCofferActivity();
        vm.stopPrank();

        // Assert
        (available, , , , , , , isActive, ) = targetCoffer.s_validatorConditions();
        assertFalse(isActive, "Should be inactive");

        // Act - Reactivate
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferActivated();
        targetCoffer.changeCofferActivity();
        vm.stopPrank();

        // Assert
        (available, , , , , , , isActive, ) = targetCoffer.s_validatorConditions();
        assertTrue(isActive, "Should be active again");
    }

    function test_ChangeCofferActivity_RevertIf_NotOwner() public {
        vm.startPrank(unauthorizedUser);
        vm.expectRevert();
        targetCoffer.changeCofferActivity();
        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - INTEREST RATE
    // ========================================

    function test_ChangeInterestRate_Success() public {
        // Arrange
        (uint128 available, uint64 oldRate, , , uint32 oldVersion, , , , ) = targetCoffer.s_validatorConditions();
        uint64 newRate = LOW_RATE;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.InterestRateChanged(oldRate, newRate);
        targetCoffer.changeInterestRate(newRate);
        vm.stopPrank();

        // Assert
        (, uint64 currentRate, , , uint32 newVersion, , , , ) = targetCoffer.s_validatorConditions();
        assertEq(currentRate, newRate, "Rate should be updated");
        assertEq(newVersion, oldVersion + 1, "Version should increment");
    }

    function test_ChangeInterestRate_RevertIf_Zero() public {
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.InvalidRate.selector));
        targetCoffer.changeInterestRate(0);
        vm.stopPrank();
    }

    function test_ChangeInterestRate_RevertIf_ExceedsMax() public {
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.InvalidRate.selector));
        targetCoffer.changeInterestRate(RATE_DIVISOR + 1);
        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - DURATIONS
    // ========================================

    function test_ChangeMinimumAndMaximumDuration_Success() public {
        // Arrange
        uint32 newMin = ONE_WEEK;
        uint32 newMax = FIVE_YEARS;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.DurationRangeChanged(newMin, newMax);
        targetCoffer.changeMinimumAndMaximumDuration(newMin, newMax);
        vm.stopPrank();

        // Assert
        (, , uint32 minDur, uint32 maxDur, , , , , ) = targetCoffer.s_validatorConditions();
        assertEq(minDur, newMin, "Min duration should be updated");
        assertEq(maxDur, newMax, "Max duration should be updated");
    }

    function test_ChangeMinimumAndMaximumDuration_RevertIf_Invalid() public {
        vm.startPrank(validator);

        // Test zero minimum
        vm.expectRevert(abi.encodeWithSelector(Coffer.InvalidDuration.selector));
        targetCoffer.changeMinimumAndMaximumDuration(0, ONE_YEAR);

        // Test max < min
        vm.expectRevert(abi.encodeWithSelector(Coffer.InvalidDuration.selector));
        targetCoffer.changeMinimumAndMaximumDuration(ONE_YEAR, ONE_MONTH);

        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - MINIMUM AMOUNT
    // ========================================

    function test_ChangeMinimumAmountToAccept_Success() public {
        // Arrange
        uint128 newMinimum = 5 ether;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.MinimumAmountChanged(newMinimum);
        targetCoffer.changeMinimumAmountToAccept(newMinimum);
        vm.stopPrank();

        // Assert
        (, , , , , uint128 minAmount, , , ) = targetCoffer.s_validatorConditions();
        assertEq(minAmount, newMinimum, "Minimum amount should be updated");
    }

    function test_ChangeMinimumAmountToAccept_RevertIf_Zero() public {
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ZeroAmount.selector));
        targetCoffer.changeMinimumAmountToAccept(0);
        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - AVAILABLE AMOUNT
    // ========================================

    function test_ChangeAvailableAmount_Success_NoBonds() public {
        // Arrange - Create coffer without bonds
        address noBondCoffer = createCoffer(
            validator,
            bytes32(uint256(555)),
            bytes16(uint128(555)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            false
        );
        Coffer noBondCofferContract = Coffer(payable(noBondCoffer));

        uint128 newAmount = 200 ether;

        // Act
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, true);
        emit CofferEvents.AvailableAmountChanged(defaultAvailableAmount, newAmount);
        noBondCofferContract.changeAvailableAmount(newAmount);
        vm.stopPrank();

        // Assert
        (uint128 available, , , , uint32 version, , , , ) = noBondCofferContract.s_validatorConditions();
        assertEq(available, newAmount, "Available amount should be updated");
        assertEq(version, 1, "Version should increment");
    }

    function test_ChangeAvailableAmount_RevertIf_HasUnpayedBonds() public {
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ValidatorHasUnrepayedBonds.selector));
        targetCoffer.changeAvailableAmount(200 ether);
        vm.stopPrank();
    }

    function test_ChangeAvailableAmount_RevertIf_BelowMinimum() public {
        // Arrange - Create coffer without bonds
        address noBondCoffer = createCoffer(
            validator,
            bytes32(uint256(666)),
            bytes16(uint128(666)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            10 ether, // minimum amount to accept
            false
        );

        // Act & Assert
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.AmountTooSmallToAccept.selector));
        Coffer(payable(noBondCoffer)).changeAvailableAmount(5 ether); // Below minimum
        vm.stopPrank();
    }

    // ========================================
    // STATE CHANGE FUNCTIONS - EXIT ALLOWED
    // ========================================

    function test_ChangeExitAllowed_Success() public {
        // Arrange - Create coffer without bonds
        address noBondCoffer = createCoffer(
            validator,
            bytes32(uint256(444)),
            bytes16(uint128(444)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultAvailableAmount,
            defaultMinimumAmount,
            false // starts with exit not allowed
        );
        Coffer noBondCofferContract = Coffer(payable(noBondCoffer));

        // Act - Allow exit
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferAllowsHolderToExit();
        noBondCofferContract.changeExitAllowed();
        vm.stopPrank();

        // Assert
        (, , , , uint32 version, , , , bool exitAllowed) = noBondCofferContract.s_validatorConditions();
        assertTrue(exitAllowed, "Exit should be allowed");
        assertEq(version, 1, "Version should increment");

        // Act - Forbid exit
        vm.startPrank(validator);
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferForbidsHolderToExit();
        noBondCofferContract.changeExitAllowed();
        vm.stopPrank();

        // Assert
        (, , , , version, , , , exitAllowed) = noBondCofferContract.s_validatorConditions();
        assertFalse(exitAllowed, "Exit should be forbidden");
        assertEq(version, 2, "Version should increment again");
    }

    function test_ChangeExitAllowed_RevertIf_HasUnpayedBonds() public {
        vm.startPrank(validator);
        vm.expectRevert(abi.encodeWithSelector(Coffer.ValidatorHasUnrepayedBonds.selector));
        targetCoffer.changeExitAllowed();
        vm.stopPrank();
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    function test_RepayBondsEarly_GasUsage() public {
        // Arrange
        uint128 interest = calculateExpectedInterest(bondAmount, bondDuration, defaultInterestRate);
        vm.deal(cofferAddress, bondAmount + interest);
        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId1;

        // Act
        vm.startPrank(validator);
        uint256 gasBefore = gasleft();
        targetCoffer.repayBondsEarly(holderIds);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("Gas used for repaying bond early", gasUsed);
        assertTrue(gasUsed < 150_000, "Repay early gas usage too high");
    }
}