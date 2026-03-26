//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest, CofferEvents, CofferBondNftEvents, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "./BaseTest.sol";
import {EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

/// @dev Contract that rejects all ETH transfers
contract RejectEther {
    receive() external payable {
        revert();
    }
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
    function _expectedAmountWithInterest(uint128 amount, uint32 duration) internal view returns (uint256) {
        return amount + Interest.calculateInterest(amount, duration, defaultInterestRate);
    }

    // ========================================
    // buyBond — Happy
    // ========================================

    function test_BuyBond_MintsNftAndStoresHolderConditions() public {
        uint32 version = _enableBonding(10 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // NFT owner is holder1
        assertEq(bondNft.ownerOf(bondId), holder1);

        // HolderConditions stored
        (uint128 amount, uint32 duration, uint32 startTs,) = coffer.sHolderConditions(bondId);
        uint256 expectedAmt = _expectedAmountWithInterest(1 ether, ONE_MONTH);
        assertEq(amount, expectedAmt);
        assertEq(duration, ONE_MONTH);
        assertGt(startTs, 0);
    }

    function test_BuyBond_EmitsBondBought() public {
        uint32 version = _enableBonding(10 ether);

        uint256 amtWithInterest = _expectedAmountWithInterest(1 ether, ONE_MONTH);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast) test value from _expectedAmountWithInterest fits uint128
        emit CofferEvents.BondBought(holder1, 1, uint128(amtWithInterest), ONE_MONTH);

        vm.prank(holder1);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
        vm.snapshotGasLastCall("buyBond");
    }

    function test_BuyBond_DecrementsAvailableAmount() public {
        uint32 version = _enableBonding(10 ether);

        uint256 amtWithInterest = _expectedAmountWithInterest(1 ether, ONE_MONTH);

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, 10 ether - amtWithInterest);
    }

    function test_BuyBond_IncrementsOutstandingBonds() public {
        uint32 version = _enableBonding(10 ether);

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
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

        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 2);
    }

    function test_BuyBond_ExactMinimumAmount() public {
        uint32 version = _enableBonding(10 ether);

        // defaultMinimumAmount is 1 ether — buy exactly that
        buyBond(cofferAddr, holder1, defaultMinimumAmount, ONE_MONTH, version);

        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
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
        uint256 interest = Interest.calculateInterest(1 ether, ONE_MONTH, defaultInterestRate);
        // forge-lint: disable-next-line(unsafe-typecast) 1 ether + small interest fits uint128
        uint128 totalNeeded = uint128(1 ether + interest);

        // Set available to exactly what's needed
        vm.prank(validator);
        coffer.changeIssueSize(totalNeeded); // version -> 3

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 3);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
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

        (,,,,,, uint32 bonds,,,) = exitCoffer.sValidatorConditions();
        assertEq(bonds, 1);
    }

    function test_BuyBond_InterestCalculationVerification() public {
        uint32 version = _enableBonding(10 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 2 ether, SIX_MONTHS, version);

        (uint128 storedAmount,,,) = coffer.sHolderConditions(bondId);
        uint256 expectedInterest = Interest.calculateInterest(2 ether, SIX_MONTHS, defaultInterestRate);
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
        vm.expectRevert(Coffer.ValueTooSmallToAccept.selector);
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
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
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
        vm.expectRevert(Errors.FailedCall.selector);
        Coffer(payable(rejectorCofferAddr)).buyBond{value: 1 ether}(ONE_MONTH, 2);
    }

    // ========================================
    // holderWithdrawFromExecution — Happy
    // ========================================

    function test_HolderWithdrawFromExecution_WithdrawsAmountWithInterest() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder1.balance;

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
        vm.snapshotGasLastCall("holderWithdrawFromExecution");

        assertEq(holder1.balance, balBefore + amtOwed);
    }

    function test_HolderWithdrawFromExecution_EmitsEvent() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.expectEmit(true, true, false, false);
        emit CofferEvents.HolderWithdrawFromExecutionSuccess(holder1, bondId);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_RestoresState() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 issueSize,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
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

        (,,,,,, uint32 bonds1,,,) = coffer.sValidatorConditions();
        assertEq(bonds1, 1);

        // holder2 withdraws second
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(id2);

        (,,,,,, uint32 bonds2,,,) = coffer.sValidatorConditions();
        assertEq(bonds2, 0);
    }

    function test_HolderWithdrawFromExecution_AfterNftTransfer() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        // Transfer NFT to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder2.balance;

        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(bondId);

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

        uint256 bondId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        Coffer exitCoffer = Coffer(payable(exitCofferAddr));
        (uint128 amtOwed,,,) = exitCoffer.sHolderConditions(bondId);

        vm.deal(exitCofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromExecution(bondId);
    }

    // ========================================
    // holderWithdrawFromExecution — Partial Withdrawal Happy
    // ========================================

    function test_HolderWithdrawFromExecution_PartialWithdraw_WithdrawsAvailableBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        // Fund contract with less than bondMaturityValue
        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder1.balance;

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        assertEq(holder1.balance, balBefore + partialAmount);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_ReducesBondMaturityValue() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remaining,,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, amtOwed - partialAmount);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_IncreasesIssueSize() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore + partialAmount);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_BondRemainsActive() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        // outstandingBonds unchanged
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 1);

        // NFT still exists and owned by holder1
        assertEq(bondNft.ownerOf(bondId), holder1);

        // bondMaturityValue > 0
        (uint128 remaining,,,) = coffer.sHolderConditions(bondId);
        assertGt(remaining, 0);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_EmitsPartialEvent() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderPartialWithdrawFromExecutionSuccess(
            holder1, bondId, partialAmount, amtOwed - partialAmount
        );

        vm.expectEmit(false, false, false, true, address(bondNft));
        emit CofferBondNftEvents.MetadataUpdate(bondId);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_PartialThenFullWithdraw() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        // Partial withdrawal
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        uint128 remaining = amtOwed - partialAmount;

        // Deal more ETH so full withdrawal succeeds
        vm.deal(cofferAddr, remaining);

        uint256 balBefore = holder1.balance;

        // Full withdrawal on reduced bondMaturityValue
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        assertEq(holder1.balance, balBefore + remaining);

        // Bond is now fully removed
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);

        (uint128 finalAmount,,,) = coffer.sHolderConditions(bondId);
        assertEq(finalAmount, 0);
    }

    function test_HolderWithdrawFromExecution_MultiplePartialWithdrawals() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        advanceTime(ONE_MONTH + 1);

        // First partial withdrawal: 1/3
        uint128 first = amtOwed / 3;
        vm.deal(cofferAddr, first);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remainingAfter1,,,) = coffer.sHolderConditions(bondId);
        assertEq(remainingAfter1, amtOwed - first);

        // Second partial withdrawal: another 1/3
        uint128 second = amtOwed / 3;
        vm.deal(cofferAddr, second);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remainingAfter2,,,) = coffer.sHolderConditions(bondId);
        assertEq(remainingAfter2, amtOwed - first - second);

        // Cumulative issueSize increase
        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        uint128 issueSizeBase = 10 ether - amtOwed; // after bond purchase
        assertEq(issueSizeAfter, issueSizeBase + first + second);
    }

    function test_HolderWithdrawFromExecution_PartialThenConsensusWithdraw() public {
        // Use exitAllowed coffer so consensus withdrawal triggers full exit
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

        uint256 bondId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        (uint128 amtOwed,,,) = exitCoffer.sHolderConditions(bondId);

        // Partial execution withdrawal
        uint128 partialAmount = amtOwed / 2;
        vm.deal(exitCofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromExecution(bondId);

        uint128 remaining = amtOwed - partialAmount;
        (uint128 storedRemaining,,,) = exitCoffer.sHolderConditions(bondId);
        assertEq(storedRemaining, remaining);

        // Now consensus withdrawal uses reduced bondMaturityValue
        uint256 fee = getWithdrawalFee();

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, bondId, remaining, true);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromExecution_PartialThenRedeemBondsEarly() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        // Partial execution withdrawal
        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        uint128 remaining = amtOwed - partialAmount;

        // Validator redeems with reduced value
        vm.deal(cofferAddr, remaining);

        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;

        vm.prank(validator);
        coffer.redeemBondsEarly(ids);

        // Bond fully removed
        (uint128 finalAmount,,,) = coffer.sHolderConditions(bondId);
        assertEq(finalAmount, 0);

        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_AfterNftTransfer() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        // Transfer NFT to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        uint256 balBefore = holder2.balance;

        // New owner does partial withdrawal
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(bondId);

        assertEq(holder2.balance, balBefore + partialAmount);

        // Bond still active with reduced value
        (uint128 remaining,,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, amtOwed - partialAmount);
        assertEq(bondNft.ownerOf(bondId), holder2);
    }

    // ========================================
    // holderWithdrawFromExecution — Reverts
    // ========================================

    function test_HolderWithdrawFromExecution_RevertsIfHolderDoesNotExist() public {
        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromExecution(999);
    }

    function test_HolderWithdrawFromExecution_RevertsIfAlreadyWithdrawn() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfNotNftOwner() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfNotMatured() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        // Do NOT advance time

        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfZeroBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Do NOT fund contract — balance is 0
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_RevertsIfSendAmountFailed() public {
        // Use a RejectEther contract as the bond buyer
        RejectEther rejector = new RejectEther();
        vm.deal(address(rejector), 100 ether);

        uint32 version = _enableBonding(10 ether);

        // Buy bond from rejector
        vm.prank(address(rejector));
        coffer.buyBond{value: 1 ether}(ONE_MONTH, version);
        uint256 bondId = 1;

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.prank(address(rejector));
        vm.expectRevert(Errors.FailedCall.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    // ========================================
    // holderWithdrawFromConsensus — Happy
    // ========================================

    function test_HolderWithdrawFromConsensus_ExitNotAllowed_PartialWithdraw() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        // forge-lint: disable-next-line(unsafe-typecast) amtOwed / 1e9 fits in uint64
        uint64 expectedGwei = uint64(amtOwed / 1e9);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, bondId, amtOwed, false);

        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
        vm.snapshotGasLastCall("holderWithdrawFromConsensus");
    }

    function test_HolderWithdrawFromConsensus_ExitNotAllowed_VerifyPayloadAmount() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // The event's isFullExit should be false when exitAllowed=false (partial amount)
        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, bondId, amtOwed, false);

        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
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

        uint256 bondId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        (uint128 amtOwed,,,) = exitCoffer.sHolderConditions(bondId);

        // isFullExit should be true because exitAllowed=true means amountToWithdrawInGwei=0
        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, bondId, amtOwed, true);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromConsensus{value: fee}(bondId);
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

        uint256 bondId = buyBond(exitCofferAddr, holder1, 1 ether, ONE_MONTH, 1);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Full exit: amount in payload is 0, so isFullExit = true
        vm.expectEmit(true, true, false, true);
        (uint128 amtOwed,,,) = exitCoffer.sHolderConditions(bondId);
        emit CofferEvents.HolderWithdrawFromConsensusSuccess(holder1, bondId, amtOwed, true);

        vm.prank(holder1);
        exitCoffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    // ========================================
    // holderWithdrawFromConsensus — Reverts
    // ========================================

    function test_HolderWithdrawFromConsensus_RevertsIfHolderDoesNotExist() public {
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(999);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfNotNftOwner() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder2);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfContractHasEnoughBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed); // fund contract with enough

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderConsensusWithdrawNotPossibleContractHasEnoughBalance.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfNotMatured() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Do NOT advance time
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfInsufficientFee() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.InsufficientFee.selector);
        coffer.holderWithdrawFromConsensus{value: fee - 1}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfWithdrawalContractFails() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);

        // Set excess to EXCESS_INHIBITOR to make the fee getter revert
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        vm.prank(holder1);
        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.holderWithdrawFromConsensus{value: 1 ether}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfWriteCallFails() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Build the exact 56-byte payload that Coffer will send
        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
        uint64 amountGwei = uint64((uint256(amtOwed) + 1e9 - 1) / 1e9);
        bytes memory data = abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2, amountGwei);

        // Mock the write call to revert (fee getter staticcall still works)
        vm.mockCallRevert(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, fee, data, "");

        vm.prank(holder1);
        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfAlreadyWithdrawn() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        // Withdraw from execution first (which deletes the holder)
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderWithdrawFromConsensus_RevertsIfConsensusWithdrawalAlreadyInitiated() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // First consensus withdrawal succeeds
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);

        // Second consensus withdrawal on same bond reverts
        fee = getWithdrawalFee();
        vm.prank(holder1);
        vm.expectRevert(Coffer.WithdrawalAlreadyInitiated.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    // ========================================
    // Edge Cases
    // ========================================

    function test_EdgeCase_BuyBondTransferNftNewOwnerWithdraws() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);

        // Transfer NFT holder1 -> holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        // holder1 can no longer withdraw
        vm.prank(holder1);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(bondId);

        // holder2 can withdraw
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(bondId);
        assertEq(holder2.balance, balBefore + amtOwed);
    }

    function test_EdgeCase_ValidatorRedeemsEarly_HolderCannotWithdraw() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);

        // Validator redeems early
        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);

        advanceTime(ONE_MONTH + 1);

        // Holder tries to withdraw — should fail because bond was already redeemed
        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_EdgeCase_ExactFeePaymentSucceeds() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);
        uint256 fee = getWithdrawalFee();

        // Exact fee should succeed
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }
}
