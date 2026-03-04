//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";

contract CofferMainOpsTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Sets up a coffer with availableAmount and buys a bond, returning bondId
    function _setupBondForModifierTests() internal returns (uint256 bondId) {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2
        bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
    }

    // ========================================
    // CONSTRUCTOR (exitAllowed = false)
    // ========================================

    function test_Constructor_ExitNotAllowed_SetsOwner() public view {
        assertEq(coffer.owner(), validator);
    }

    function test_Constructor_ExitNotAllowed_SetsImmutables() public view {
        assertEq(coffer.I_COFFER_BOND_NFT_ADDRESS(), address(bondNft));
        assertEq(coffer.I_PUBLIC_KEY_PART1(), validPublicKeyPart1);
        assertEq(coffer.I_PUBLIC_KEY_PART2(), validPublicKeyPart2);
    }

    function test_Constructor_ExitNotAllowed_AvailableAmountIsZero() public view {
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, 0);
    }

    function test_Constructor_ExitNotAllowed_SetsAllValidatorConditions() public view {
        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = coffer.sValidatorConditions();

        assertEq(issueSize, 0);
        assertEq(interestRate, defaultInterestRate);
        assertEq(minimumDuration, defaultMinDuration);
        assertEq(maximumDuration, defaultMaxDuration);
        assertEq(minimumAmountToAccept, defaultMinimumAmount);
        assertEq(version, 1);
        assertEq(outstandingBonds, 0);
        assertEq(safeTotalStake, defaultSafeTotalStake);
        assertTrue(isActive);
        assertFalse(exitAllowed);
    }

    // ========================================
    // CONSTRUCTOR (exitAllowed = true)
    // ========================================

    function test_Constructor_ExitAllowed_CalculatesAvailableAmount() public {
        address exitCofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (uint128 issueSize,,,,,,,,,) = exitCoffer.sValidatorConditions();

        uint256 expected = Penalty.addMaximumPenalty(32 ether, defaultSafeTotalStake, defaultMaxDuration / 384);
        assertEq(issueSize, expected);
    }

    function test_Constructor_ExitAllowed_AvailableAmountIsPositive() public {
        address exitCofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (uint128 issueSize,,,,,,,,,) = exitCoffer.sValidatorConditions();
        assertGt(issueSize, 0);
    }

    function test_Constructor_ExitAllowed_SetsAllValidatorConditions() public {
        address exitCofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = exitCoffer.sValidatorConditions();

        uint256 expectedAvailable = Penalty.addMaximumPenalty(32 ether, defaultSafeTotalStake, defaultMaxDuration / 384);

        assertEq(issueSize, expectedAvailable);
        assertEq(interestRate, defaultInterestRate);
        assertEq(minimumDuration, defaultMinDuration);
        assertEq(maximumDuration, defaultMaxDuration);
        assertEq(minimumAmountToAccept, defaultMinimumAmount);
        assertEq(version, 1);
        assertEq(outstandingBonds, 0);
        assertEq(safeTotalStake, defaultSafeTotalStake);
        assertTrue(isActive);
        assertTrue(exitAllowed);
    }

    // ========================================
    // receive()
    // ========================================

    function test_Receive_AcceptsEthFromAnyone() public {
        vm.deal(unauthorizedUser, 10 ether);
        vm.prank(unauthorizedUser);
        (bool success,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 1 ether);
    }

    function test_Receive_AcceptsEthFromValidator() public {
        vm.prank(validator);
        (bool success,) = cofferAddr.call{value: 5 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 5 ether);
    }

    function test_Receive_AcceptsZeroValue() public {
        vm.prank(holder1);
        (bool success,) = cofferAddr.call{value: 0}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 0);
    }

    function test_Receive_AcceptsMultipleDeposits() public {
        vm.prank(holder1);
        (bool s1,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(holder2);
        (bool s2,) = cofferAddr.call{value: 2 ether}("");
        assertTrue(s2);

        assertEq(cofferAddr.balance, 3 ether);
    }

    // ========================================
    // OUTSTANDING BONDS RESTRICTIONS
    // ========================================

    function test_ChangeIssueSize_RevertsWhenIncreasedWithBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
        coffer.changeIssueSize(15 ether); // increase from 10 ether triggers revert
    }

    function test_ChangeExitAllowed_RevertsWhenForbiddingExitsWithBondsExist() public {
        vm.prank(validator);
        coffer.changeExitAllowed(); // version -> 2, exitAllowed = true

        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 3

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 3);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotForbidExitsWhileOutstandingBondExists.selector);
        coffer.changeExitAllowed(); // tries true -> false, should revert
    }

    function test_ChangeSafeTotalStake_RevertsWhenIncreasedWithBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist.selector);
        coffer.changeSafeTotalStake(30_000_000);
    }

    function test_ValidatorWithdrawFromExecution_RevertsWhenBondsExist() public {
        _setupBondForModifierTests();

        // Fund the contract so the balance check doesn't fail first
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    // ========================================
    // PRIVATE removeHolder (indirect — via holderWithdrawFromExecution)
    // ========================================

    function test_RemoveHolder_RestoresAvailableAmount() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Get availableAmount after buying bond
        (uint128 availableAfterBuy,,,,,,,,,) = coffer.sValidatorConditions();

        // Fund contract and advance time
        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 availableAfterWithdraw,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(availableAfterWithdraw, 10 ether); // fully restored
    }

    function test_RemoveHolder_DecrementsOutstandingBonds() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        (,,,,,, uint32 bondsBefore,,,) = coffer.sValidatorConditions();
        assertEq(bondsBefore, 1);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (,,,,,, uint32 bondsAfter,,,) = coffer.sValidatorConditions();
        assertEq(bondsAfter, 0);
    }

    function test_RemoveHolder_BurnsNft() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Verify NFT exists
        assertEq(bondNft.ownerOf(bondId), holder1);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        // NFT should be burned — ownerOf should revert
        vm.expectRevert();
        bondNft.ownerOf(bondId);
    }

    function test_RemoveHolder_DeletesHolderConditions() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 amount,,) = coffer.sHolderConditions(bondId);
        assertEq(amount, 0);
    }

    // ========================================
    // PRIVATE holderIsCaller (indirect)
    // ========================================

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromExecution() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromConsensus() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        advanceTime(ONE_MONTH + 1);

        uint256 fee = getWithdrawalFee();

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderIsCaller_SucceedsAfterNftTransfer() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Transfer NFT from holder1 to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        // holder2 can now withdraw
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(bondId);

        assertGt(holder2.balance, balBefore);
    }
}
