//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest, CofferEvents, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, EXCESS_INHIBITOR} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Contract that rejects all ETH transfers
contract RejectEther {
    receive() external payable { revert(); }
}

contract CofferHolderOpsTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Standard setup: set available amount and return the current version
    function _enableBonding(uint128 available) internal returns (uint32 version) {
        vm.prank(validator);
        coffer.changeIssueSize(available); // version -> 2
        version = 2;
    }

    /// @dev Compute expected amountWithInterest for a bond
    function _expectedAmountWithInterest(uint128 amount, uint32 duration) internal view returns (uint128) {
        return amount + Interest.calculateInterest(amount, duration, defaultInterestRate);
    }

    // ========================================
    // buyBond — Happy
    // ========================================

    function test_BuyBond_MintsNftAndStoresHolderConditions() public {
        uint32 version = _enableBonding(10 ether);

        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // NFT owner is holder1
        assertEq(bondNft.ownerOf(holderId), holder1);

        // HolderConditions stored
        (uint128 amount, uint32 duration, uint32 startTs) = coffer.s_holderConditions(holderId);
        uint128 expectedAmt = _expectedAmountWithInterest(1 ether, ONE_MONTH);
        assertEq(amount, expectedAmt);
        assertEq(duration, ONE_MONTH);
        assertGt(startTs, 0);
    }

    function test_BuyBond_EmitsHolderAcceptedOffer() public {
        uint32 version = _enableBonding(10 ether);

        uint128 amtWithInterest = _expectedAmountWithInterest(1 ether, ONE_MONTH);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderAcceptedOffer(holder1, 1, 1 ether, ONE_MONTH, amtWithInterest);

        vm.prank(holder1);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
    }

    function test_BuyBond_DecrementsAvailableAmount() public {
        uint32 version = _enableBonding(10 ether);

        uint128 amtWithInterest = _expectedAmountWithInterest(1 ether, ONE_MONTH);

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 issueSize,,,,,,,,, ) = coffer.s_validatorConditions();
        assertEq(issueSize, 10 ether - amtWithInterest);
    }

    function test_BuyBond_IncrementsOutstandingBonds() public {
        uint32 version = _enableBonding(10 ether);

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (,,,,, , uint32 bonds,,,) = coffer.s_validatorConditions();
        assertEq(bonds, 1);
    }

    function test_BuyBond_SendsMsgValueToValidator() public {
        uint32 version = _enableBonding(10 ether);

        uint256 valBalBefore = validator.balance;

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        assertEq(validator.balance, valBalBefore + 1 ether);
    }

    function test_BuyBond_MultipleHolders() public {
        uint32 version = _enableBonding(10 ether);

        uint256 id1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);
        uint256 id2 = buyBond(cofferAddr, holder2, 2 ether, ONE_MONTH, version);

        assertEq(bondNft.ownerOf(id1), holder1);
        assertEq(bondNft.ownerOf(id2), holder2);

        (,,,,, , uint32 bonds,,,) = coffer.s_validatorConditions();
        assertEq(bonds, 2);
    }

    function test_BuyBond_ExactMinimumAmount() public {
        uint32 version = _enableBonding(10 ether);

        // defaultMinimumAmount is 1 ether — buy exactly that
        buyBond(cofferAddr, holder1, defaultMinimumAmount, ONE_MONTH, version);

        (,,,,, , uint32 bonds,,,) = coffer.s_validatorConditions();
        assertEq(bonds, 1);
    }

    function test_BuyBond_ExactMinimumDuration() public {
        uint32 version = _enableBonding(10 ether);

        buyBond(cofferAddr, holder1, 1 ether, defaultMinDuration, version);
    }

    function test_BuyBond_ExactMaximumDuration() public {
        uint32 version = _enableBonding(10 ether);

        buyBond(cofferAddr, holder1, 1 ether, defaultMaxDuration, version);
    }

    function test_BuyBond_ExactAvailableAmount() public {
        uint32 version = _enableBonding(2 ether);

        // We need to buy an amount whose amountWithInterest exactly equals available
        // Since interest > 0, we can't buy exactly 2 ether. Buy a smaller amount
        // that when adding interest fits.
        uint128 interest = Interest.calculateInterest(1 ether, ONE_MONTH, defaultInterestRate);
        uint128 totalNeeded = 1 ether + interest;

        // Set available to exactly what's needed
        vm.prank(validator);
        coffer.changeIssueSize(totalNeeded); // version -> 3

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 3);

        (uint128 issueSize,,,,,,,,, ) = coffer.s_validatorConditions();
        assertEq(issueSize, 0);
    }

    function test_BuyBond_ExitAllowedCofferPath() public {
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

        // exitAllowed coffer starts with availableAmount set by constructor, version=1
        buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        (,,,,, , uint32 bonds,,,) = exitCoffer.s_validatorConditions();
        assertEq(bonds, 1);
    }

    function test_BuyBond_InterestCalculationVerification() public {
        uint32 version = _enableBonding(10 ether);

        uint256 holderId = buyBond(cofferAddr, holder1, 2 ether, SIX_MONTHS, version);

        (uint128 storedAmount,,) = coffer.s_holderConditions(holderId);
        uint128 expectedInterest = Interest.calculateInterest(2 ether, SIX_MONTHS, defaultInterestRate);
        assertEq(storedAmount, 2 ether + expectedInterest);
    }

    // ========================================
    // buyBond — Reverts
    // ========================================

    function test_BuyBond_RevertsIfVersionMismatch() public {
        _enableBonding(10 ether); // version is 2

        vm.prank(holder1);
        vm.expectRevert(Coffer.ValidatorConditionsVersionMismatch.selector);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, 1); // wrong version
    }

    function test_BuyBond_RevertsIfAmountTooSmall() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.AmountTooSmallToAccept.selector);
        coffer.buyBond{value: defaultMinimumAmount - 1}(ONE_MONTH, version);
    }

    function test_BuyBond_RevertsIfNotActive() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(validator);
        coffer.changeCofferActivity(); // deactivate

        vm.prank(holder1);
        vm.expectRevert(Coffer.ValidatorIsNotActive.selector);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
    }

    function test_BuyBond_RevertsIfHolderIsValidator() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(validator);
        vm.expectRevert(Coffer.HolderCannotBeValidator.selector);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
    }

    function test_BuyBond_RevertsIfDurationTooShort() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.buyBond{value: 1 ether}(defaultMinDuration - 1, version);
    }

    function test_BuyBond_RevertsIfDurationTooLong() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.buyBond{value: 1 ether}(defaultMaxDuration + 1, version);
    }

    function test_BuyBond_RevertsIfDurationZero() public {
        uint32 version = _enableBonding(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.buyBond{value: 1 ether}(0, version);
    }

    function test_BuyBond_RevertsIfExceedsAvailableAmount() public {
        uint32 version = _enableBonding(2 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheAmount.selector);
        coffer.buyBond{value: 2 ether}(ONE_MONTH, version); // 2 ETH + interest > 2 ETH available
    }

    function test_BuyBond_RevertsIfValidatorFrontrunChangesVersion() public {
        uint32 version = _enableBonding(10 ether); // version = 2

        // Validator changes rate, incrementing version to 3
        vm.prank(validator);
        coffer.changeInterestRate(3e6);

        vm.prank(holder1);
        vm.expectRevert(Coffer.ValidatorConditionsVersionMismatch.selector);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version); // version 2 is stale
    }

    function test_BuyBond_RevertsIfSendAmountFailed() public {
        // Create coffer owned by RejectEther (so ETH send to validator fails)
        RejectEther rejector = new RejectEther();
        vm.deal(address(rejector), 100 ether);

        address rejectorCofferAddr = createCoffer(
            address(rejector),
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            false
        );

        // Set available amount — need to prank as rejector (owner)
        vm.prank(address(rejector));
        Coffer(payable(rejectorCofferAddr)).changeIssueSize(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Coffer.SendAmountFailed.selector);
        Coffer(payable(rejectorCofferAddr)).buyBond{value: 1 ether}(ONE_MONTH, 2);
    }

    // ========================================
    // holderWithdrawFromExecution — Happy
    // ========================================

    function test_HolderWithdrawFromExecution_WithdrawsAmountWithInterest() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder1.balance;

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        assertEq(holder1.balance, balBefore + amtOwed);
    }

    function test_HolderWithdrawFromExecution_EmitsEvent() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.expectEmit(true, true, false, false);
        emit CofferEvents.HolderWithdrawFromExecutionSuccess(holder1, holderId);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderWithdrawFromExecution_RestoresState() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        (uint128 issueSize,,,,, , uint32 bonds,,,) = coffer.s_validatorConditions();
        assertEq(bonds, 0);
        assertEq(issueSize, 10 ether); // fully restored
    }

    function test_HolderWithdrawFromExecution_MultipleHoldersIndependently() public {
        uint32 version = _enableBonding(10 ether);
        uint256 id1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);
        uint256 id2 = buyBond(cofferAddr, holder2, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        // holder1 withdraws first
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(id1);

        (,,,,, , uint32 bonds1,,,) = coffer.s_validatorConditions();
        assertEq(bonds1, 1);

        // holder2 withdraws second
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(id2);

        (,,,,, , uint32 bonds2,,,) = coffer.s_validatorConditions();
        assertEq(bonds2, 0);
    }

    function test_HolderWithdrawFromExecution_AfterNftTransfer() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);

        // Transfer NFT to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, holderId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder2.balance;

        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(holderId);

        assertEq(holder2.balance, balBefore + amtOwed);
    }

    function test_HolderWithdrawFromExecution_ExitAllowedCoffer() public {
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

        uint256 holderId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        Coffer exitCoffer = Coffer(payable(exitCofferAddr));
        (uint128 amtOwed,,) = exitCoffer.s_holderConditions(holderId);

        vm.deal(exitCofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromExecution(holderId);
    }

    // ========================================
    // holderWithdrawFromExecution — Reverts
    // ========================================

    function test_HolderWithdrawFromExecution_RevertsIfHolderDoesNotExist() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.holderWithdrawFromExecution(999);
    }

    function test_HolderWithdrawFromExecution_RevertsIfAlreadyWithdrawn() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfNotNftOwner() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfNotMatured() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        // Do NOT advance time

        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfInsufficientBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Do NOT fund contract
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        vm.expectRevert(Coffer.ContractBalanceLessThanAmount.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfSendAmountFailed() public {
        // Use a RejectEther contract as the bond buyer
        RejectEther rejector = new RejectEther();
        vm.deal(address(rejector), 100 ether);

        uint32 version = _enableBonding(10 ether);

        // Buy bond from rejector
        vm.prank(address(rejector));
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
        uint256 holderId = 1;

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.prank(address(rejector));
        vm.expectRevert(Coffer.SendAmountFailed.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    // ========================================
    // holderWithdrawFromConsensus — Happy
    // ========================================

    function test_HolderWithdrawFromConsensus_ExitNotAllowed_PartialWithdraw() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        uint64 expectedGwei = uint64(amtOwed / 1e9);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, holderId, amtOwed, false);

        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_ExitNotAllowed_VerifyPayloadAmount() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // The event's isFullExit should be false when exitAllowed=false (partial amount)
        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, holderId, amtOwed, false);

        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_ExitAllowed_FullExit() public {
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

        uint256 holderId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        (uint128 amtOwed,,) = exitCoffer.s_holderConditions(holderId);

        // isFullExit should be true because exitAllowed=true means amountToWithdrawInGwei=0
        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, holderId, amtOwed, true);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_ExitAllowed_VerifyPayload() public {
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

        uint256 holderId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Full exit: amount in payload is 0, so isFullExit = true
        vm.expectEmit(true, true, false, true);
        (uint128 amtOwed,,) = exitCoffer.s_holderConditions(holderId);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, holderId, amtOwed, true);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    // ========================================
    // holderWithdrawFromConsensus — Reverts
    // ========================================

    function test_HolderWithdrawFromConsensus_RevertsIfHolderDoesNotExist() public {
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(999);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfNotNftOwner() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfContractHasEnoughBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        vm.deal(cofferAddr, amtOwed); // fund contract with enough

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderConsensusWithdrawNotPossibleContractHasEnoughBalance.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfNotMatured() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Do NOT advance time
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfInsufficientFee() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.InsufficientFee.selector);
        coffer.holderWithdrawFromConsensus{value: fee - 1}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfWithdrawalContractFails() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);

        // Set excess to EXCESS_INHIBITOR to make the fee getter revert
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        vm.prank(holder1);
        vm.expectRevert(Coffer.WithdrawlContractCallFailed.selector);
        coffer.holderWithdrawFromConsensus{value: 1 ether}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfWriteCallFails() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Build the exact 56-byte payload that Coffer will send
        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        uint64 amountGwei = uint64(amtOwed / 1e9);
        bytes memory data = abi.encodePacked(
            validPublicKeyPart1,
            validPublicKeyPart2,
            amountGwei
        );

        // Mock the write call to revert (fee getter staticcall still works)
        vm.mockCallRevert(
            WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,
            fee,
            data,
            ""
        );

        vm.prank(holder1);
        vm.expectRevert(Coffer.WithdrawlContractCallFailed.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfAlreadyWithdrawn() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        // Withdraw from execution first (which deletes the holder)
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(holderId);

        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }

    // ========================================
    // Edge Cases
    // ========================================

    function test_EdgeCase_BuyBondTransferNftNewOwnerWithdraws() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);

        // Transfer NFT holder1 -> holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, holderId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        // holder1 can no longer withdraw
        vm.prank(holder1);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(holderId);

        // holder2 can withdraw
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(holderId);
        assertEq(holder2.balance, balBefore + amtOwed);
    }

    function test_EdgeCase_ValidatorRedeemsEarly_HolderCannotWithdraw() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.s_holderConditions(holderId);
        vm.deal(cofferAddr, amtOwed);

        // Validator redeems early
        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = holderId;
        coffer.redeemBondsEarly(ids);

        advanceTime(ONE_MONTH + 1);

        // Holder tries to withdraw — should fail because bond was already redeemed
        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.holderWithdrawFromExecution(holderId);
    }

    function test_EdgeCase_ExactFeePaymentSucceeds() public {
        uint32 version = _enableBonding(10 ether);
        uint256 holderId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Exact fee should succeed
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);
    }
}
