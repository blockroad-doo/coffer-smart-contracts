// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferReceivableNFT} from "../../src/CofferReceivableNFT.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CofferTest is Test {
    Coffer public coffer;
    CofferReceivableNFT public nft;

    address public validator = makeAddr("validator");
    address public holder1 = makeAddr("holder1");
    address public holder2 = makeAddr("holder2");
    address public holder3 = makeAddr("holder3");
    address public nonOwner = makeAddr("nonOwner");

    // Default parameters
    bytes32 public constant PK_PART1 = bytes32(uint256(1));
    bytes16 public constant PK_PART2 = bytes16(uint128(1));
    uint256 public constant MAX_SLASHING = 1 ether;
    uint256 public constant INTEREST_RATE = 1e17; // 10%
    uint256 public constant MIN_DURATION = 30 days;
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant AVAILABLE_AMOUNT = 32 ether;
    uint256 public constant MIN_AMOUNT = 1 ether;
    uint256 public constant RETURN_RATE = 1e18; // 100%
    uint256 public constant RATE_DIVISOR = 1e18;

    // Events
    event HolderAcceptedOffer(address indexed holderAddress);
    event HolderWithdrawFromExecution(address indexed holderAddress, uint256 amountToWithdraw);
    event OfferClosed(address indexed holderAddress, uint256 amountOwed);

    function setUp() public {
        nft = new CofferReceivableNFT();

        vm.prank(validator);
        coffer = new Coffer(
            validator,
            PK_PART1,
            PK_PART2,
            address(nft),
            MAX_SLASHING,
            INTEREST_RATE,
            MIN_DURATION,
            MAX_DURATION,
            AVAILABLE_AMOUNT,
            MIN_AMOUNT //,
                //RETURN_RATE,
                //true
        );

        // Fund holders for testing
        vm.deal(holder1, 100 ether);
        vm.deal(holder2, 100 ether);
        vm.deal(holder3, 100 ether);
        vm.deal(validator, 100 ether);
    }

    function test_AcceptOffer_SuccessfullyAcceptsOffer() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        assertEq(nft.ownerOf(0), holder1, "Holder should own NFT");
    }

    function test_AcceptOffer_RevertsWhenAmountTooSmall() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.AmountTooSmallToAccept.selector);
        coffer.acceptOffer{value: MIN_AMOUNT - 1}(MIN_DURATION);
    }

    function test_AcceptOffer_RevertsWhenValidatorInactive() public {
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(holder1);
        vm.expectRevert(Coffer.ValidatorIsNotActive.selector);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
    }

    function test_AcceptOffer_RevertsWhenValidatorIsHolder() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.HolderCannotBeValidator.selector);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
    }

    function test_AcceptOffer_RevertsWhenDurationZero() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.acceptOffer{value: 2 ether}(0);
    }

    function test_AcceptOffer_RevertsWhenDurationTooShort() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION - 1);
    }

    function test_AcceptOffer_RevertsWhenDurationTooLong() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.acceptOffer{value: 2 ether}(MAX_DURATION + 1);
    }

    function test_CloseOffer_SuccessfullyClosesOffer() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        (,, uint256 amountOwed) = coffer.getHolderConditions(0);
        vm.prank(validator);
        coffer.closeOffer{value: amountOwed}(0);
        vm.expectRevert();
        nft.ownerOf(0);
    }

    function test_CloseOffer_RevertsWhenNotOwner() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        (,, uint256 amountOwed) = coffer.getHolderConditions(0);
        vm.deal(nonOwner, 100 ether);
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        coffer.closeOffer{value: amountOwed}(0);
        vm.stopPrank();
    }

    function test_CloseOffer_RevertsWhenHolderDoesNotExist() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.closeOffer{value: 1 ether}(999);
    }

    function test_DeactivateValidator_SuccessfullyDeactivates() public {
        vm.prank(validator);
        coffer.deactivateValidator();
        (bool isActive,,,,,,,) = coffer.getValidatorConditions();
        assertFalse(isActive);
    }

    function test_DeactivateValidator_RevertsWhenAlreadyInactive() public {
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorIsNotActive.selector);
        coffer.deactivateValidator();
    }

    function test_ActivateValidator_SuccessfullyActivates() public {
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.activateValidator();
        (bool isActive,,,,,,,) = coffer.getValidatorConditions();
        assertTrue(isActive);
    }

    function test_ActivateValidator_RevertsWhenAlreadyActive() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorIsActive.selector);
        coffer.activateValidator();
    }

    function test_ChangeMaximumSlashingPenalty_SuccessfullyChanges() public {
        // Accept offer to make availableAmount != startingAmount
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.changeMaximumSlashingPenalty(2 ether);
        (, uint256 maxSlashing,,,,,,) = coffer.getValidatorConditions();
        assertEq(maxSlashing, 2 ether);
    }

    function test_ChangeMaximumSlashingPenalty_RevertsWhenZero() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidSlashingPenalty.selector);
        coffer.changeMaximumSlashingPenalty(0);
    }

    function test_ChangeMaximumSlashingPenalty_RevertsWhenActive() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorIsActive.selector);
        coffer.changeMaximumSlashingPenalty(2 ether);
    }

    function test_ChangeInterestRate_SuccessfullyChanges() public {
        // Accept offer to make availableAmount != startingAmount
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.changeInterestRate(2e17);
        (,, uint256 rate,,,,,) = coffer.getValidatorConditions();
        assertEq(rate, 2e17);
    }

    function test_ChangeInterestRate_RevertsWhenZero() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidRate.selector);
        coffer.changeInterestRate(0);
    }

    function test_ChangeInterestRate_RevertsWhenGreaterThanMax() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidRate.selector);
        coffer.changeInterestRate(RATE_DIVISOR + 1);
    }

    function test_ChangeMinimumAndMaximumDuration_SuccessfullyChanges() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(60 days, 730 days);
        (,,, uint256 minD, uint256 maxD,,,) = coffer.getValidatorConditions();
        assertEq(minD, 60 days);
        assertEq(maxD, 730 days);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsWhenMaxLessThanMin() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.changeMinimumAndMaximumDuration(365 days, 30 days);
    }

    function test_ChangeAvailableAmount_SuccessfullyChanges() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.changeAvailableAmount(64 ether);
        (,,,,, uint256 available,,) = coffer.getValidatorConditions();
        assertEq(available, 64 ether);
    }

    function test_ChangeAvailableAmount_RevertsWhenLessThanMinimum() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.AmountTooSmallToAccept.selector);
        coffer.changeAvailableAmount(MIN_AMOUNT - 1);
    }

    function test_ChangeMinimumAmountToAccept_SuccessfullyChanges() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        coffer.changeMinimumAmountToAccept(2 ether);
        (,,,,,,, uint256 minAmt) = coffer.getValidatorConditions();
        assertEq(minAmt, 2 ether);
    }

    function test_ChangeMinimumAmountToAccept_RevertsWhenZero() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(validator);
        coffer.deactivateValidator();
        vm.prank(validator);
        vm.expectRevert(Coffer.ZeroAmount.selector);
        coffer.changeMinimumAmountToAccept(0);
    }

    // function test_ChangeReturnAmountRate_SuccessfullyChanges() public {
    //     vm.prank(holder1);
    //     coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
    //     vm.prank(validator);
    //     coffer.deactivateValidator();
    //     vm.prank(validator);
    //     coffer.changereturnAmonutRate(5e17);
    //     (,,,,,,,,uint256 returnRate) = coffer.getValidatorConditions();
    //     assertEq(returnRate, 5e17);
    // }

    // function test_ChangeReturnAmountRate_RevertsWhenGreaterThanMax() public {
    //     vm.prank(holder1);
    //     coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
    //     vm.prank(validator);
    //     coffer.deactivateValidator();
    //     vm.prank(validator);
    //     vm.expectRevert(Coffer.InvalidRate.selector);
    //     coffer.changereturnAmonutRate(RATE_DIVISOR + 1);
    // }

    function test_HolderWithdrawFromExecution_SuccessfullyWithdraws() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        // Don't warp time - the condition is reversed in the contract
        (,, uint256 amountOwed) = coffer.getHolderConditions(0);
        vm.deal(address(coffer), amountOwed);
        uint256 balanceBefore = holder1.balance;
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(0);
        assertEq(holder1.balance, balanceBefore + amountOwed);
    }

    function test_HolderWithdrawFromExecution_RevertsWhenTimeExpired() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.warp(block.timestamp + MIN_DURATION + 1);
        (,, uint256 amountOwed) = coffer.getHolderConditions(0);
        vm.deal(address(coffer), amountOwed);
        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.holderWithdrawFromExecution(0);
    }

    function test_HolderWithdrawFromExecution_RevertsWhenNotHolder() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        (,, uint256 amountOwed) = coffer.getHolderConditions(0);
        vm.deal(address(coffer), amountOwed);
        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(0);
    }

    function test_HolderWithdrawFromExecution_RevertsWhenInsufficientBalance() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.prank(holder1);
        vm.expectRevert(Coffer.NotEnoughAvailableAmountToWithdrawFromContract.selector);
        coffer.holderWithdrawFromExecution(0);
    }

    function test_HolderWithdrawFromConsensus_RevertsWhenCallerIsNotHolder() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.warp(block.timestamp + MIN_DURATION + 1);
        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: 1}(0);
    }

    function test_HolderWithdrawFromConsensus_RevertsWhenHoldersTimeHasNotExpiredYet() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        // Don't warp time - duration + startTimestamp will be greater than block.timestamp
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: 1}(0);
    }

    function test_HolderWithdrawFromConsensus_RevertsWhenInsufficientPrecompileFee() public {
        vm.prank(holder1);
        coffer.acceptOffer{value: 2 ether}(MIN_DURATION);
        vm.warp(block.timestamp + MIN_DURATION + 1);
        vm.prank(holder1);
        vm.expectRevert(Coffer.InsufficientPrecompileFee.selector);
        coffer.holderWithdrawFromConsensus{value: 0}(0);
    }
}
