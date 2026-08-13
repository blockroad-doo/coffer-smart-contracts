//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

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

    /// @dev Compute expected amountWithInterest for a bond (net of protocol fee)
    function _expectedAmountWithInterest(uint128 amount, uint32 duration) internal view returns (uint256) {
        uint256 interest = Interest.calculateInterest(amount, duration, defaultInterestRate);
        (uint256 feeBps,) = feeCurve.getFee();
        uint256 fee = (interest * feeBps) / 10000;
        return amount + interest - fee;
    }

    /// @dev Compute the fee for a given amount and duration
    function _expectedFee(uint128 amount, uint32 duration) internal view returns (uint256) {
        uint256 interest = Interest.calculateInterest(amount, duration, defaultInterestRate);
        (uint256 feeBps,) = feeCurve.getFee();
        return (interest * feeBps) / 10000;
    }

    // ========================================
    // buyBond: Happy
    // ========================================

    function test_BuyBond_MintsNftAndStoresHolderConditions() public {
        uint32 version = _enableBonding(10 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // NFT owner is holder1
        assertEq(bondNft.ownerOf(bondId), holder1);

        // HolderConditions stored
        (uint128 amount, uint32 duration, uint32 startTs) = coffer.sHolderConditions(bondId);
        uint256 expectedAmt = _expectedAmountWithInterest(1 ether, ONE_MONTH);
        assertEq(amount, expectedAmt);
        assertEq(duration, ONE_MONTH);
        assertGt(startTs, 0);
    }

    function test_BuyBond_EmitsBondBought() public {
        uint32 version = _enableBonding(10 ether);

        uint256 amtWithInterest = _expectedAmountWithInterest(1 ether, ONE_MONTH);
        uint256 fee = _expectedFee(1 ether, ONE_MONTH);
        (uint256 feeBps,) = feeCurve.getFee();

        vm.expectEmit(true, true, false, true);
        // forge-lint: disable-next-line(unsafe-typecast) test value from _expectedFee fits uint128
        emit CofferEvents.BondFeePaid(1, feeRecipient, uint128(fee), feeBps);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast) test value from _expectedAmountWithInterest fits uint128
        emit CofferEvents.BondBought(holder1, 1, uint128(amtWithInterest), ONE_MONTH, 1 ether, defaultInterestRate);

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
        uint256 recipientBalBefore = feeRecipient.balance;
        uint256 accruedBefore = feeCurve.sAccruedFees();
        uint256 fee = _expectedFee(1 ether, ONE_MONTH);

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Validator receives msg.value - fee immediately (unchanged).
        assertEq(validator.balance, valBalBefore + 1 ether - fee);
        // Pull pattern: the fee is collected into the shared FeeCurve, NOT pushed to the recipient here.
        assertEq(feeRecipient.balance, recipientBalBefore, "fee must not be pushed to recipient during buyBond");
        assertEq(feeCurve.sAccruedFees(), accruedBefore + fee, "fee accrued in FeeCurve");

        // The recipient pulls accrued fees via claim().
        uint256 accruedNow = feeCurve.sAccruedFees();
        feeCurve.claim();
        assertEq(feeRecipient.balance, recipientBalBefore + accruedNow, "recipient paid after claim");
        assertEq(feeCurve.sAccruedFees(), 0, "accrued fees zeroed after claim");
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

        // defaultMinimumAmount is 1 ether. Buy exactly that
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

        // We need to buy an amount whose amountWithInterest (net of fee) exactly equals available.
        // Since interest > 0, we can't buy exactly 2 ether. Buy a smaller amount
        // that when adding interest minus fee fits.
        uint256 expectedNet = _expectedAmountWithInterest(1 ether, ONE_MONTH);
        // forge-lint: disable-next-line(unsafe-typecast) 1 ether + small interest fits uint128
        uint128 totalNeeded = uint128(expectedNet);

        // Set available to exactly what's needed
        vm.prank(validator);
        coffer.changeIssueSize(totalNeeded); // version -> 3

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 3);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, 0);
    }

    function test_BuyBond_InterestCalculationVerification() public {
        uint32 version = _enableBonding(10 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 2 ether, SIX_MONTHS, version);

        (uint128 storedAmount,,) = coffer.sHolderConditions(bondId);
        uint256 expectedNet = _expectedAmountWithInterest(2 ether, SIX_MONTHS);
        assertEq(storedAmount, expectedNet);
    }

    // ========================================
    // buyBond: Reverts
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
            defaultIssueSizeBufferBps
        );

        // Set available amount: need to prank as rejector (owner)
        vm.prank(address(rejector));
        Coffer(payable(rejectorCofferAddr)).changeIssueSize(10 ether);

        vm.prank(holder1);
        vm.expectRevert(Errors.FailedCall.selector);
        Coffer(payable(rejectorCofferAddr)).buyBond{value: 1 ether}(ONE_MONTH, 2);
    }

    function test_BuyBond_RevertsIfFeeExceedsPrincipal() public {
        // Warp to day 365 so feeBps = 432 (4.32%), then with 100% rate × 50yr duration
        // interest = 1 ETH × 50 = 50 ETH, fee = 50 ETH × 432 / 10000 = 2.16 ETH > 1 ETH
        vm.warp(block.timestamp + 365 days);

        address extremeCofferAddr = createCoffer(
            validator,
            bytes32(uint256(99)),
            bytes16(uint128(98)),
            uint32(1e8), // 100% rate
            1, // minDuration = 1 second
            uint32(1_576_800_000), // maxDuration = 50 years (MAX_DURATION)
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );
        Coffer extremeCoffer = Coffer(payable(extremeCofferAddr));

        (,,,,, uint32 version,,,,) = extremeCoffer.sValidatorConditions();

        vm.prank(holder1);
        vm.expectRevert(Coffer.FeeExceedsPrincipal.selector);
        extremeCoffer.buyBond{value: 1 ether}(1_576_800_000, version);
    }

    // ========================================
    // holderWithdrawFromExecution: Happy
    // ========================================

    function test_HolderWithdrawFromExecution_WithdrawsAmountWithInterest() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.expectEmit(true, true, false, false);
        emit CofferEvents.HolderWithdrawFromExecutionSuccess(holder1, bondId);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderWithdrawFromExecution_FullWithdraw_DoesNotRestoreIssueSize() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 issueSizeAfter,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
        // C-1: issueSize is not restored on bond settlement.
        assertEq(issueSizeAfter, issueSizeBefore);
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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

    // ========================================
    // holderWithdrawFromExecution: Partial Withdrawal Happy
    // ========================================

    function test_HolderWithdrawFromExecution_PartialWithdraw_WithdrawsAvailableBalance() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, amtOwed - partialAmount);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_DoesNotChangeIssueSize() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        uint128 partialAmount = amtOwed / 2;
        vm.deal(cofferAddr, partialAmount);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        // C-1: partial withdraw does not change issueSize.
        assertEq(issueSizeAfter, issueSizeBefore);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_BondRemainsActive() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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
        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertGt(remaining, 0);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_EmitsPartialEvent() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

        (uint128 finalAmount,,) = coffer.sHolderConditions(bondId);
        assertEq(finalAmount, 0);
    }

    function test_HolderWithdrawFromExecution_MultiplePartialWithdrawals() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        advanceTime(ONE_MONTH + 1);

        // First partial withdrawal: 1/3
        uint128 first = amtOwed / 3;
        vm.deal(cofferAddr, first);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remainingAfter1,,) = coffer.sHolderConditions(bondId);
        assertEq(remainingAfter1, amtOwed - first);

        // Second partial withdrawal: another 1/3
        uint128 second = amtOwed / 3;
        vm.deal(cofferAddr, second);

        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remainingAfter2,,) = coffer.sHolderConditions(bondId);
        assertEq(remainingAfter2, amtOwed - first - second);

        // C-1: partial withdraws do not change issueSize. It stays at the
        // post-buyBond level for the lifetime of this test.
        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        uint128 issueSizeBase = 10 ether - amtOwed; // after bond purchase
        assertEq(issueSizeAfter, issueSizeBase);
    }

    function test_HolderWithdrawFromExecution_PartialThenRedeemBondsEarly() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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
        (uint128 finalAmount,,) = coffer.sHolderConditions(bondId);
        assertEq(finalAmount, 0);

        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_HolderWithdrawFromExecution_PartialWithdraw_AfterNftTransfer() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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
        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, amtOwed - partialAmount);
        assertEq(bondNft.ownerOf(bondId), holder2);
    }

    // ========================================
    // holderWithdrawFromExecution: Reverts
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

        // Do NOT fund contract: balance is 0
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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);
        advanceTime(ONE_MONTH + 1);

        vm.prank(address(rejector));
        vm.expectRevert(Errors.FailedCall.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    // ========================================
    // Edge Cases
    // ========================================

    function test_EdgeCase_BuyBondTransferNftNewOwnerWithdraws() public {
        uint32 version = _enableBonding(10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);

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

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);

        // Validator redeems early
        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);

        advanceTime(ONE_MONTH + 1);

        // Holder tries to withdraw: should fail because bond was already redeemed
        vm.prank(holder1);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }
}
