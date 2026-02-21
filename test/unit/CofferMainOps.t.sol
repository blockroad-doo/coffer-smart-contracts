//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest, CofferEvents} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

    /// @dev Sets up a coffer with availableAmount and buys a bond, returning holderId
    function _setupBondForModifierTests() internal returns (uint256 holderId) {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2
        holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
    }

    // ========================================
    // CONSTRUCTOR (exitAllowed = false)
    // ========================================

    function test_Constructor_ExitNotAllowed_SetsOwner() public view {
        assertEq(coffer.owner(), validator);
    }

    function test_Constructor_ExitNotAllowed_SetsImmutables() public view {
        assertEq(coffer.i_cofferBondNftAddress(), address(bondNft));
        assertEq(coffer.i_public_key_part1(), validPublicKeyPart1);
        assertEq(coffer.i_public_key_part2(), validPublicKeyPart2);
    }

    function test_Constructor_ExitNotAllowed_AvailableAmountIsZero() public view {
        (uint128 availableAmount,,,,,,,,, ) = coffer.s_validatorConditions();
        assertEq(availableAmount, 0);
    }

    function test_Constructor_ExitNotAllowed_SetsAllValidatorConditions() public view {
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = coffer.s_validatorConditions();

        assertEq(availableAmount, 0);
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

        (uint128 availableAmount,,,,,,,,, ) = exitCoffer.s_validatorConditions();

        uint128 expected = Penalty.addMaximumPenalty(
            32 ether,
            defaultSafeTotalStake,
            defaultMaxDuration / 384
        );
        assertEq(availableAmount, expected);
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

        (uint128 availableAmount,,,,,,,,, ) = exitCoffer.s_validatorConditions();
        assertGt(availableAmount, 0);
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
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = exitCoffer.s_validatorConditions();

        uint128 expectedAvailable = Penalty.addMaximumPenalty(
            32 ether,
            defaultSafeTotalStake,
            defaultMaxDuration / 384
        );

        assertEq(availableAmount, expectedAvailable);
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
        (bool success, ) = cofferAddr.call{value: 1 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 1 ether);
    }

    function test_Receive_AcceptsEthFromValidator() public {
        vm.prank(validator);
        (bool success, ) = cofferAddr.call{value: 5 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 5 ether);
    }

    function test_Receive_AcceptsZeroValue() public {
        vm.prank(holder1);
        (bool success, ) = cofferAddr.call{value: 0}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 0);
    }

    function test_Receive_AcceptsMultipleDeposits() public {
        vm.prank(holder1);
        (bool s1, ) = cofferAddr.call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(holder2);
        (bool s2, ) = cofferAddr.call{value: 2 ether}("");
        assertTrue(s2);

        assertEq(cofferAddr.balance, 3 ether);
    }

    // ========================================
    // MODIFIER _noOutstandingBonds
    // ========================================

    function test_NoOutstandingBonds_ChangeAvailableAmount_RevertsWhenBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorHasOutstandingBonds.selector);
        coffer.changeAvailableAmount(5 ether);
    }

    function test_NoOutstandingBonds_ChangeExitAllowed_RevertsWhenBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorHasOutstandingBonds.selector);
        coffer.changeExitAllowed();
    }

    function test_NoOutstandingBonds_ChangeSafeTotalStake_RevertsWhenBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorHasOutstandingBonds.selector);
        coffer.changeSafeTotalStake(30_000_000);
    }

    function test_NoOutstandingBonds_ValidatorWithdrawFromExecution_RevertsWhenBondsExist() public {
        _setupBondForModifierTests();

        // Fund the contract so the balance check doesn't fail first
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorHasOutstandingBonds.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    // ========================================
    // PRIVATE removeHolder (indirect — via holderWithdrawFromExecution)
    // ========================================

    function test_RemoveHolder_RestoresAvailableAmount() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Get availableAmount after buying bond
        (uint128 availableAfterBuy,,,,,,,,, ) = coffer.s_validatorConditions();

        // Fund contract and advance time
        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        (uint128 availableAfterWithdraw,,,,,,,,, ) = coffer.s_validatorConditions();
        assertEq(availableAfterWithdraw, 10 ether); // fully restored
    }

    function test_RemoveHolder_DecrementsOutstandingBonds() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        (,,,,, , uint32 bondsBefore,,,) = coffer.s_validatorConditions();
        assertEq(bondsBefore, 1);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        (,,,,, , uint32 bondsAfter,,,) = coffer.s_validatorConditions();
        assertEq(bondsAfter, 0);
    }

    function test_RemoveHolder_BurnsNft() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Verify NFT exists
        assertEq(bondNft.ownerOf(holderId), holder1);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        // NFT should be burned — ownerOf should revert
        vm.expectRevert();
        bondNft.ownerOf(holderId);
    }

    function test_RemoveHolder_DeletesHolderConditions() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        (uint128 amount, , ) = coffer.s_holderConditions(holderId);
        assertEq(amount, 0);
    }

    // ========================================
    // PRIVATE holderIsCaller (indirect)
    // ========================================

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromExecution() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromConsensus() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        advanceTime(ONE_MONTH + 1);

        uint256 fee = getWithdrawalFee();

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderIsCaller_SucceedsAfterNftTransfer() public {
        vm.prank(validator);
        coffer.changeAvailableAmount(10 ether); // version -> 2

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Transfer NFT from holder1 to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, holderId);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        // holder2 can now withdraw
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(holderId);

        assertGt(holder2.balance, balBefore);
    }
}
