//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {
    BaseTest,
    CofferEvents,
    CofferRedemptionEscrowEvents,
    WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,
    CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS
} from "./BaseTest.sol";

import {EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {Vm} from "forge-std/Vm.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

/// @dev Contract that rejects all ETH transfers
contract RejectEther {
    receive() external payable {
        revert();
    }
}

contract CofferValidatorOpsTest is BaseTest {
    uint256 private constant BUFFER_DENOMINATOR = 10000;

    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Creates coffer, sets available amount, buys a bond, returns (bondId, amountWithInterestAfterFee)
    function _setupSingleBond(uint128 available, uint128 bondAmount, uint32 duration)
        internal
        returns (uint256 bondId, uint128 amountWithInterest)
    {
        vm.prank(validator);
        coffer.changeIssueSize(available); // version -> 2

        bondId = buyBond(cofferAddr, holder1, bondAmount, duration, 2);

        uint256 interest = Interest.calculateInterest(bondAmount, duration, defaultInterestRate);
        (uint256 feeBps,) = feeCurve.getFee();
        uint256 fee = (interest * feeBps) / 10000;
        // forge-lint: disable-next-line(unsafe-typecast) bondAmount + interest - fee from test constants fits uint128
        amountWithInterest = uint128(bondAmount + interest - fee);
    }

    // ========================================
    // validatorRedeemBonds
    // ========================================

    function test_ValidatorRedeemBonds_SingleBond_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Fund contract
        vm.deal(cofferAddr, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);
        vm.snapshotGasLastCall("validatorRedeemBonds_single");

        // ETH lands in CofferRedemptionEscrow, not directly to holder
        assertEq(address(redemptionEscrow).balance, amtOwed);
        assertEq(redemptionEscrow.sPendingClaims(holder1), amtOwed);
    }

    function test_ValidatorRedeemBonds_MultipleBonds_Success() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 id1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        uint256 id2 = buyBond(cofferAddr, holder2, 1 ether, ONE_MONTH, 2);

        (uint128 amt1,,) = coffer.sHolderConditions(id1);
        (uint128 amt2,,) = coffer.sHolderConditions(id2);

        vm.deal(cofferAddr, amt1 + amt2);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        coffer.validatorRedeemBonds(ids);

        // Both bonds redeemed - outstandingBonds should be 0
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_ValidatorRedeemBonds_WithMsgValueTopUp_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Contract has partial_ balance, validator tops up via msg.value
        uint128 partial_ = amtOwed / 2;
        vm.deal(cofferAddr, partial_);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds{value: amtOwed - partial_}(ids);

        (uint128 amt,,) = coffer.sHolderConditions(bondId);
        assertEq(amt, 0); // deleted
    }

    function test_ValidatorRedeemBonds_BeforeMaturity_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // No time advancement: bond hasn't matured, but validatorRedeemBonds has no time check
        vm.deal(cofferAddr, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids); // should succeed
    }

    function test_ValidatorRedeemBonds_DoesNotRestoreIssueSize() public {
        (uint256 bondId,) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);

        (uint128 issueSizeAfter,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
        // issueSize is not restored on bond settlement.
        assertEq(issueSizeAfter, issueSizeBefore);
    }

    function test_ValidatorRedeemBonds_EmitsEvent() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed);

        vm.expectEmit(true, true, false, false);
        emit CofferEvents.BondRedeemedByValidator(holder1, bondId);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);
    }

    function test_ValidatorRedeemBonds_RevertsIfHolderDoesNotExist() public {
        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.validatorRedeemBonds(ids);
    }

    function test_ValidatorRedeemBonds_RevertsIfAlreadyRedeemed() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed * 2);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);

        vm.prank(validator);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.validatorRedeemBonds(ids);
    }

    // A batch is all-or-nothing. A duplicated id trips the second iteration's existence check
    // because the first iteration deleted the record, and a settled id beside a valid one unwinds the valid
    // one's delete and burn. Nothing moves in either case, msg.value included. The snapshot lives in a struct
    // to stay clear of the stack limit.

    struct BatchSnapshot {
        uint128 amt1;
        uint32 dur1;
        uint32 start1;
        uint128 amt2;
        uint256 cofferBalance;
        uint256 escrowBalance;
        uint256 validatorBalance;
        uint32 outstanding;
    }

    /// @dev Two bonds, the second settled alone so a mixed batch carries a valid id next to a settled one.
    ///      Funded for both so no batch can fail on the balance check instead of the id check.
    function _setupTwoBondsSettleSecond() internal returns (uint256 id1, uint256 id2, BatchSnapshot memory s) {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2
        id1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        id2 = buyBond(cofferAddr, holder2, 1 ether, ONE_MONTH, 2);
        (s.amt1, s.dur1, s.start1) = coffer.sHolderConditions(id1);
        (s.amt2,,) = coffer.sHolderConditions(id2);
        vm.deal(cofferAddr, uint256(s.amt1) + s.amt2);

        uint256[] memory single = new uint256[](1);
        single[0] = id2;
        vm.prank(validator);
        coffer.validatorRedeemBonds(single);

        s.cofferBalance = cofferAddr.balance;
        s.escrowBalance = address(redemptionEscrow).balance;
        s.validatorBalance = validator.balance;
        (,,,,,, s.outstanding,,,) = coffer.sValidatorConditions();
    }

    function _assertBatchUntouched(uint256 id1, BatchSnapshot memory s) internal view {
        (uint128 amtAfter, uint32 durAfter, uint32 startAfter) = coffer.sHolderConditions(id1);
        assertEq(amtAfter, s.amt1, "record value untouched");
        assertEq(durAfter, s.dur1, "record duration untouched");
        assertEq(startAfter, s.start1, "record start untouched");
        assertEq(bondNft.ownerOf(id1), holder1, "NFT not burned");
        assertEq(bondNft.cofferOf(id1), cofferAddr, "cofferOf untouched");
        (,,,,,, uint32 outstandingAfter,,,) = coffer.sValidatorConditions();
        assertEq(outstandingAfter, s.outstanding, "outstandingBonds untouched");
        assertEq(cofferAddr.balance, s.cofferBalance, "coffer balance untouched");
        assertEq(address(redemptionEscrow).balance, s.escrowBalance, "escrow balance untouched");
        assertEq(redemptionEscrow.sPendingClaims(holder1), 0, "no escrow credit for holder1");
        assertEq(redemptionEscrow.sPendingClaims(holder2), s.amt2, "holder2 credit from the earlier settle untouched");
        assertEq(validator.balance, s.validatorBalance, "msg.value returned on revert");
    }

    function test_ValidatorRedeemBonds_DuplicateIdInBatch_RevertsAndLeavesStateUntouched() public {
        (uint256 id1,, BatchSnapshot memory s) = _setupTwoBondsSettleSecond();
        uint256[] memory duplicate = new uint256[](2);
        duplicate[0] = id1;
        duplicate[1] = id1;

        vm.prank(validator);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.validatorRedeemBonds{value: s.amt1}(duplicate);

        _assertBatchUntouched(id1, s);
    }

    function test_ValidatorRedeemBonds_SettledIdInBatch_RevertsAndLeavesStateUntouched() public {
        (uint256 id1, uint256 id2, BatchSnapshot memory s) = _setupTwoBondsSettleSecond();
        uint256[] memory mixed = new uint256[](2);
        mixed[0] = id1;
        mixed[1] = id2;

        vm.prank(validator);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.validatorRedeemBonds(mixed);

        _assertBatchUntouched(id1, s);
    }

    function test_ValidatorRedeemBonds_RevertsIfInsufficientBalance() public {
        (uint256 bondId,) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        // Do NOT fund contract

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.validatorRedeemBonds(ids);
    }

    function test_ValidatorRedeemBonds_RevertsIfNotOwner() public {
        vm.prank(holder1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.validatorRedeemBonds(ids);
    }

    function test_ValidatorRedeemBonds_SucceedsIfHolderRejectsEther() public {
        // Deploy a RejectEther contract and use it as holder
        RejectEther rejector = new RejectEther();
        vm.deal(address(rejector), 100 ether);

        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        // Buy bond from rejector address
        vm.prank(address(rejector));
        coffer.buyBond{value: 1 ether}(ONE_MONTH, 2);
        uint256 bondId = 1; // first bond

        (uint128 amtOwed,,) = coffer.sHolderConditions(bondId);
        vm.deal(cofferAddr, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids); // no longer reverts

        // Funds deposited to CofferRedemptionEscrow
        assertEq(redemptionEscrow.sPendingClaims(address(rejector)), amtOwed);

        // outstandingBonds should be 0
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_ValidatorRedeemBonds_DepositsToCofferRedemptionEscrow() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed);

        uint256 claimBalBefore = address(redemptionEscrow).balance;

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);

        assertEq(address(redemptionEscrow).balance, claimBalBefore + amtOwed);
        assertEq(redemptionEscrow.sPendingClaims(holder1), amtOwed);
    }

    function test_ValidatorRedeemBonds_MixedBatch_NormalAndRejectingHolder() public {
        RejectEther rejector = new RejectEther();
        vm.deal(address(rejector), 100 ether);

        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        // holder1 buys a bond
        uint256 id1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        // rejector buys a bond
        vm.prank(address(rejector));
        coffer.buyBond{value: 1 ether}(ONE_MONTH, 2);
        uint256 id2 = 2;

        (uint128 amt1,,) = coffer.sHolderConditions(id1);
        (uint128 amt2,,) = coffer.sHolderConditions(id2);
        vm.deal(cofferAddr, amt1 + amt2);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        coffer.validatorRedeemBonds(ids); // both succeed

        // Both can claim
        assertEq(redemptionEscrow.sPendingClaims(holder1), amt1);
        assertEq(redemptionEscrow.sPendingClaims(address(rejector)), amt2);

        // outstandingBonds == 0
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_ValidatorRedeemBonds_EmitsDepositEvents() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed);

        vm.expectEmit(true, false, false, true);
        emit CofferRedemptionEscrowEvents.ClaimDeposited(holder1, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.validatorRedeemBonds(ids);
    }

    // ========================================
    // changeCofferActivity
    // ========================================

    function test_ChangeCofferActivity_Deactivate_EmitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferDeactivated();

        vm.prank(validator);
        coffer.changeCofferActivity();
        vm.snapshotGasLastCall("changeCofferActivity");

        (,,,,,,,, bool isActive,) = coffer.sValidatorConditions();
        assertFalse(isActive);
    }

    function test_ChangeCofferActivity_Reactivate_EmitsEvent() public {
        vm.prank(validator);
        coffer.changeCofferActivity(); // deactivate

        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferActivated();

        vm.prank(validator);
        coffer.changeCofferActivity(); // reactivate

        (,,,,,,,, bool isActive,) = coffer.sValidatorConditions();
        assertTrue(isActive);
    }

    function test_ChangeCofferActivity_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeCofferActivity();
    }

    // ========================================
    // changeInterestRate
    // ========================================

    function test_ChangeInterestRate_DecreaseRate_Success() public {
        uint32 newRate = 3e6; // 3%

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.InterestRateChanged(defaultInterestRate, newRate);

        vm.prank(validator);
        coffer.changeInterestRate(newRate);

        (, uint32 rate,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(rate, newRate);
        assertEq(version, 2); // incremented
    }

    function test_ChangeInterestRate_IncreaseRate_NoBonds_Success() public {
        uint32 newRate = 8e6; // 8%

        vm.prank(validator);
        coffer.changeInterestRate(newRate);

        (, uint32 rate,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(rate, newRate);
    }

    function test_ChangeInterestRate_DecreaseRate_WithBonds_Success() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        uint32 newRate = 2e6; // 2%, decrease is allowed with bonds
        vm.prank(validator);
        coffer.changeInterestRate(newRate);

        (, uint32 rate,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(rate, newRate);
    }

    function test_ChangeInterestRate_SameRate_NoBonds_Success() public {
        vm.prank(validator);
        coffer.changeInterestRate(defaultInterestRate);

        (, uint32 rate,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(rate, defaultInterestRate);
    }

    function test_ChangeInterestRate_ExactMaxRate_Success() public {
        vm.prank(validator);
        coffer.changeInterestRate(1e8); // MAX_RATE

        (, uint32 rate,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(rate, 1e8);
    }

    function test_ChangeInterestRate_VersionIncrements() public {
        vm.prank(validator);
        coffer.changeInterestRate(3e6);

        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2);

        vm.prank(validator);
        coffer.changeInterestRate(4e6);

        (,,,,, uint32 version2,,,,) = coffer.sValidatorConditions();
        assertEq(version2, 3);
    }

    function test_ChangeInterestRate_RevertsIfZeroRate() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidRate.selector);
        coffer.changeInterestRate(0);
    }

    function test_ChangeInterestRate_RevertsIfExceedsMaxRate() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidRate.selector);
        coffer.changeInterestRate(1e8 + 1);
    }

    function test_ChangeInterestRate_RevertsIfIncreaseWithBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist.selector);
        coffer.changeInterestRate(8e6); // increase from 5% to 8%
    }

    function test_ChangeInterestRate_RevertsIfSameRateWithBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Same rate counts as >= so should revert
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist.selector);
        coffer.changeInterestRate(defaultInterestRate);
    }

    function test_ChangeInterestRate_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeInterestRate(3e6);
    }

    // ========================================
    // changeMinimumAndMaximumDuration
    // ========================================

    function test_ChangeMinimumAndMaximumDuration_UpdatesBothValues() public {
        uint32 newMin = ONE_WEEK;
        uint32 newMax = FIVE_YEARS;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.DurationRangeChanged(newMin, newMax);

        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(newMin, newMax);

        (,, uint32 minDur, uint32 maxDur,,,,,,) = coffer.sValidatorConditions();
        assertEq(minDur, newMin);
        assertEq(maxDur, newMax);
    }

    function test_ChangeMinimumAndMaximumDuration_MinEqualsMax_Success() public {
        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(ONE_MONTH, ONE_MONTH);

        (,, uint32 minDur, uint32 maxDur,,,,,,) = coffer.sValidatorConditions();
        assertEq(minDur, ONE_MONTH);
        assertEq(maxDur, ONE_MONTH);
    }

    function test_ChangeMinimumAndMaximumDuration_IncrementsVersion() public {
        (,,,,, uint32 vBefore,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, FIVE_YEARS);

        (,,,,, uint32 vAfter,,,,) = coffer.sValidatorConditions();
        assertEq(vAfter, vBefore + 1);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsIfMaxLessThanMin() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.changeMinimumAndMaximumDuration(ONE_YEAR, ONE_MONTH);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsIfMinIsZero() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.changeMinimumAndMaximumDuration(0, ONE_YEAR);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsIfMaxExceedsLimit() public {
        uint32 overLimit = uint32(1_576_800_000) + 1; // MAX_DURATION + 1
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidDuration.selector);
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, overLimit);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, FIVE_YEARS);
    }

    function test_ChangeMinimumAndMaximumDuration_RevertsIfMaxIncreasedWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseMaximumDurationWhileOutstandingBondExist.selector);
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, FIVE_YEARS); // FIVE_YEARS > ONE_YEAR (default max)
    }

    function test_ChangeMinimumAndMaximumDuration_AllowsMaxDecreaseWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, SIX_MONTHS); // SIX_MONTHS < ONE_YEAR (default max)

        (,, uint32 minDur, uint32 maxDur,,,,,,) = coffer.sValidatorConditions();
        assertEq(minDur, ONE_WEEK);
        assertEq(maxDur, SIX_MONTHS);
    }

    // ========================================
    // changeMinimumValueToAccept
    // ========================================

    function test_ChangeMinimumAmountToAccept_UpdatesValue() public {
        uint128 newMin = 0.5 ether;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.MinimumValueChanged(newMin);

        vm.prank(validator);
        coffer.changeMinimumValueToAccept(newMin);

        (,,,, uint128 minAmt,,,,,) = coffer.sValidatorConditions();
        assertEq(minAmt, newMin);
    }

    function test_ChangeMinimumAmountToAccept_DoesNotIncrementVersion() public {
        (,,,,, uint32 vBefore,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        coffer.changeMinimumValueToAccept(0.5 ether);

        (,,,,, uint32 vAfter,,,,) = coffer.sValidatorConditions();
        assertEq(vAfter, vBefore);
    }

    function test_ChangeMinimumAmountToAccept_RevertsIfZero() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ZeroValue.selector);
        coffer.changeMinimumValueToAccept(0);
    }

    function test_ChangeMinimumAmountToAccept_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeMinimumValueToAccept(0.5 ether);
    }

    // ========================================
    // changeIssueSize
    // ========================================

    function test_ChangeIssueSize_UpdatesValue() public {
        uint128 newAmt = 5 ether;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.IssueSizeChanged(newAmt);

        vm.prank(validator);
        coffer.changeIssueSize(newAmt);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, newAmt);
    }

    function test_ChangeIssueSize_ExactMinimumBoundary() public {
        // Set amount equal to minimumAmountToAccept (1 ether)
        vm.prank(validator);
        coffer.changeIssueSize(defaultMinimumAmount);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, defaultMinimumAmount);
    }

    function test_ChangeIssueSize_IncrementsVersion() public {
        vm.prank(validator);
        coffer.changeIssueSize(5 ether);

        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2);
    }

    function test_ChangeIssueSize_RevertsIfBelowMinimum() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValueTooSmallToAccept.selector);
        coffer.changeIssueSize(defaultMinimumAmount - 1);
    }

    function test_ChangeIssueSize_RevertsIfIncreaseWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
        coffer.changeIssueSize(15 ether); // increase triggers revert
    }

    function test_ChangeIssueSize_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeIssueSize(5 ether);
    }

    // ========================================
    // changeIssueSizeBufferBps
    // ========================================

    function test_ChangeIssueSizeBufferBps_UpdatesAndEmitsEvent() public {
        uint16 newBuffer = 300;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.IssueSizeBufferBpsChanged(defaultIssueSizeBufferBps, newBuffer);

        vm.prank(validator);
        coffer.changeIssueSizeBufferBps(newBuffer);

        (,,,,,,, uint16 buffer,,) = coffer.sValidatorConditions();
        assertEq(buffer, newBuffer);
    }

    function test_ChangeIssueSizeBufferBps_VersionIncrements() public {
        vm.prank(validator);
        coffer.changeIssueSizeBufferBps(300);

        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2);
    }

    function test_ChangeIssueSizeBufferBps_RevertsIfDecreaseWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist.selector);
        coffer.changeIssueSizeBufferBps(200); // decrease from 250
    }

    function test_ChangeIssueSizeBufferBps_RevertsIfExceedsDenominator() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidIssueSizeBufferBps.selector);
        coffer.changeIssueSizeBufferBps(10001); // BUFFER_DENOMINATOR + 1
    }

    function test_ChangeIssueSizeBufferBps_RevertsIfEqualsDenominator() public {
        //buffer == BUFFER_DENOMINATOR (100%) is now rejected; valid range is 0..9999.
        vm.prank(validator);
        vm.expectRevert(Coffer.InvalidIssueSizeBufferBps.selector);
        coffer.changeIssueSizeBufferBps(10000); // == BUFFER_DENOMINATOR
    }

    function test_ChangeIssueSizeBufferBps_MaxValid_9999_Succeeds() public {
        //9999 (BUFFER_DENOMINATOR - 1) is the maximum valid buffer and must still work.
        vm.prank(validator);
        coffer.changeIssueSizeBufferBps(9999);

        (,,,,,,, uint16 buffer,,) = coffer.sValidatorConditions();
        assertEq(buffer, 9999, "buffer stored as 9999");
    }

    function test_ChangeIssueSizeBufferBps_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeIssueSizeBufferBps(300);
    }

    // ========================================
    // changeIssueSize / changeIssueSizeBufferBps: buffer-change with bonds
    // ========================================

    function test_ChangeIssueSize_DecreaseWithBonds_Success() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Decrease is allowed with outstanding bonds
        vm.prank(validator);
        coffer.changeIssueSize(5 ether);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, 5 ether);
    }

    function test_ChangeIssueSize_SameValueWithBonds_Reverts() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Read current issueSize (it's less than 10 ether because a bond was bought)
        (uint128 currentIssueSize,,,,,,,,,) = coffer.sValidatorConditions();

        // Same value counts as >= so should revert
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
        coffer.changeIssueSize(currentIssueSize);
    }

    function test_ChangeIssueSizeBufferBps_IncreaseWithBonds_Success() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Increase is allowed with outstanding bonds (more conservative)
        vm.prank(validator);
        coffer.changeIssueSizeBufferBps(300); // increase from 250

        (,,,,,,, uint16 buffer,,) = coffer.sValidatorConditions();
        assertEq(buffer, 300);
    }

    function test_ChangeIssueSizeBufferBps_SameValueWithBonds_Reverts() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Same value counts as not > so should revert
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist.selector);
        coffer.changeIssueSizeBufferBps(defaultIssueSizeBufferBps);
    }

    // ========================================
    // validatorWithdrawFromExecution
    // ========================================

    function test_ValidatorWithdrawFromExecution_WithdrawsAmount() public {
        vm.deal(cofferAddr, 10 ether);
        uint256 balBefore = validator.balance;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorWithdrawFromExecution(5 ether);

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(5 ether);
        vm.snapshotGasLastCall("validatorWithdrawFromExecution");

        assertEq(validator.balance, balBefore + 5 ether);
        assertEq(cofferAddr.balance, 5 ether);
    }

    function test_ValidatorWithdrawFromExecution_FullBalance() public {
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(10 ether);

        assertEq(cofferAddr.balance, 0);
    }

    function test_ValidatorWithdrawFromExecution_RevertsIfExceedsBalance() public {
        vm.deal(cofferAddr, 1 ether);

        vm.prank(validator);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.validatorWithdrawFromExecution(2 ether);
    }

    function test_ValidatorWithdrawFromExecution_SucceedsWithOutstandingBonds() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();
        uint256 valBalBefore = validator.balance;

        // Withdraw exactly issueSize
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(issueSizeBefore);

        assertEq(validator.balance, valBalBefore + issueSizeBefore);

        // issueSize is now 0
        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, 0);

        // Bond is still active
        (uint128 bondAmt,,) = coffer.sHolderConditions(bondId);
        assertEq(bondAmt, amtOwed);
    }

    function test_ValidatorWithdrawFromExecution_DecreasesIssueSizeWhenBondsExist() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        uint128 withdrawAmt = 1 ether;
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(withdrawAmt);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore - withdrawAmt);
    }

    function test_ValidatorWithdrawFromExecution_RevertsIfExceedsIssueSize() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();

        // Try to withdraw more than issueSize
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
        coffer.validatorWithdrawFromExecution(issueSize + 1);
    }

    function test_ValidatorWithdrawFromExecution_MultiRoundDrainStopsAtIssueSize() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 100 ether);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();
        assertGt(issueSizeBefore, 0);

        // First round takes two thirds, so the same amount cannot fit a second time
        uint128 firstDrain = uint128((uint256(issueSizeBefore) * 2) / 3);

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(firstDrain);

        (uint128 issueSizeMid,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeMid, issueSizeBefore - firstDrain);
        assertLt(issueSizeMid, firstDrain, "second round must not fit");

        // Second round with the same amount exceeds what remains
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
        coffer.validatorWithdrawFromExecution(firstDrain);

        // The remainder is withdrawable, then the allowance is spent
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(issueSizeMid);

        (uint128 issueSizeFinal,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeFinal, 0);

        // Refilling is blocked while bonds are outstanding
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
        coffer.changeIssueSize(10 ether);

        // Balance is still available, but the spent allowance gates the withdraw
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    function test_ValidatorWithdrawFromExecution_NoBonds_WithdrawsContractBalance() public {
        // With no outstanding bonds, the validator can withdraw the full contract balance
        // regardless of issueSize.

        // Fund contract and withdraw: no bonds, so no issueSize check
        vm.deal(cofferAddr, 5 ether);

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(5 ether);

        assertEq(cofferAddr.balance, 0);
    }

    function test_ValidatorWithdrawFromExecution_WithBonds_AfterReceiveTopUp() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        // Validator sends ETH via receive(): issueSize increases
        vm.prank(validator);
        (bool success,) = cofferAddr.call{value: 3 ether}("");
        assertTrue(success);

        (uint128 issueSizeAfterReceive,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfterReceive, issueSizeBefore + 3 ether);

        // Validator can withdraw the 3 ETH they just sent (within issueSize)
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(3 ether);

        (uint128 issueSizeAfterWithdraw,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfterWithdraw, issueSizeBefore);

        assertEq(cofferAddr.balance, 0);
    }

    function test_ValidatorWithdrawFromExecution_RevertsIfNotOwner() public {
        vm.deal(cofferAddr, 10 ether);

        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    function test_ValidatorWithdrawFromExecution_RevertsIfSendFails() public {
        // Create coffer owned by a RejectEther contract
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

        vm.deal(rejectorCofferAddr, 10 ether);

        vm.prank(address(rejector));
        vm.expectRevert(Errors.FailedCall.selector);
        Coffer(payable(rejectorCofferAddr)).validatorWithdrawFromExecution(1 ether);
    }

    // ========================================
    // validatorWithdrawFromConsensus
    // ========================================

    function test_ValidatorWithdrawFromConsensus_PartialWithdraw() public {
        uint256 fee = getWithdrawalFee();

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorWithdrawFromConsensus(5_000_000_000); // 5 ETH in Gwei

        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(5_000_000_000);
        vm.snapshotGasLastCall("validatorWithdrawFromConsensus");
    }

    function test_ValidatorWithdrawFromConsensus_FullExit() public {
        uint256 fee = getWithdrawalFee();

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorWithdrawFromConsensus(0);

        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(0);
    }

    function test_ValidatorWithdrawFromConsensus_WorksWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        uint256 fee = getWithdrawalFee();

        // Should succeed even with outstanding bonds (no _noOutstandingBonds modifier)
        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(5_000_000_000);
    }

    function test_ValidatorWithdrawFromConsensus_ExactFee() public {
        uint256 fee = getWithdrawalFee();

        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(1_000_000_000);
    }

    function test_ValidatorWithdrawFromConsensus_RevertsIfInsufficientFee() public {
        uint256 fee = getWithdrawalFee();

        vm.prank(validator);
        vm.expectRevert(Coffer.InsufficientFee.selector);
        coffer.validatorWithdrawFromConsensus{value: fee - 1}(5_000_000_000);
    }

    function test_ValidatorWithdrawFromConsensus_RevertsIfNotOwner() public {
        uint256 fee = getWithdrawalFee();

        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.validatorWithdrawFromConsensus{value: fee}(5_000_000_000);
    }

    function test_ValidatorWithdrawFromConsensus_RevertsIfFeeGetterFails() public {
        // Set excess to EXCESS_INHIBITOR to make the fee getter revert
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        vm.prank(validator);
        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.validatorWithdrawFromConsensus{value: 1 ether}(5_000_000_000);
    }

    function test_ValidatorWithdrawFromConsensus_RevertsIfWriteCallFails() public {
        uint256 fee = getWithdrawalFee();

        // Build the exact 56-byte payload that Coffer will send
        uint64 amount = 5_000_000_000;
        bytes memory data = abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2, amount);

        // Mock the write call to revert (fee getter staticcall still works)
        vm.mockCallRevert(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, fee, data, "");

        vm.prank(validator);
        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.validatorWithdrawFromConsensus{value: fee}(amount);
    }

    // ========================================
    // validatorAddFundsToConsensus
    // ========================================

    function test_ValidatorAddFundsToConsensus_IncreasesAvailableAmount() public {
        // First set an available amount so we can see the increase
        vm.prank(validator);
        coffer.changeIssueSize(5 ether); // version -> 2

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        // Mock DepositContract.deposit to accept any call
        vm.mockCall(
            0x00000000219ab540356cBB839Cbe05303d7705Fa,
            abi.encodeWithSignature("deposit(bytes,bytes,bytes,bytes32)"),
            ""
        );

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.ValidatorFundsAdded(1 ether);

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: 1 ether}(bytes32(0));

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();

        uint256 expectedIncrease = calculateExpectedIssueSize(1 ether, defaultIssueSizeBufferBps);
        assertEq(issueSizeAfter, issueSizeBefore + expectedIncrease);
    }

    function test_ValidatorAddFundsToConsensus_Exact1Ether() public {
        vm.mockCall(
            0x00000000219ab540356cBB839Cbe05303d7705Fa,
            abi.encodeWithSignature("deposit(bytes,bytes,bytes,bytes32)"),
            ""
        );

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: 1 ether}(bytes32(0));
    }

    function test_ValidatorAddFundsToConsensus_MultipleDeposits() public {
        vm.mockCall(
            0x00000000219ab540356cBB839Cbe05303d7705Fa,
            abi.encodeWithSignature("deposit(bytes,bytes,bytes,bytes32)"),
            ""
        );

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: 2 ether}(bytes32(0));

        (uint128 issueSize1,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: 3 ether}(bytes32(0));

        (uint128 issueSize2,,,,,,,,,) = coffer.sValidatorConditions();
        assertGt(issueSize2, issueSize1);
    }

    function test_ValidatorAddFundsToConsensus_RevertsIfValueLessThan1Ether() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDepositValueTooLow.selector);
        coffer.validatorAddFundsToConsensus{value: 0.5 ether}(bytes32(0));
    }

    function test_ValidatorAddFundsToConsensus_RevertsIfNotGweiMultiple() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDepositValueNotMultipleOfGwei.selector);
        coffer.validatorAddFundsToConsensus{value: 1 ether + 1}(bytes32(0));
    }

    function test_ValidatorAddFundsToConsensus_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.validatorAddFundsToConsensus{value: 1 ether}(bytes32(0));
    }

    // ========================================
    // convertToCompounding
    // ========================================

    function test_ConvertToCompounding_Success() public {
        uint256 fee = getConsolidationFee();

        vm.expectEmit(false, false, false, false);
        emit CofferEvents.ValidatorConvertedToCompounding();

        vm.prank(validator);
        coffer.convertToCompounding{value: fee}();
    }

    function test_ConvertToCompounding_ExactFee() public {
        uint256 fee = getConsolidationFee();

        vm.prank(validator);
        coffer.convertToCompounding{value: fee}();
    }

    function test_ConvertToCompounding_ExcessFee() public {
        uint256 fee = getConsolidationFee();

        vm.prank(validator);
        coffer.convertToCompounding{value: fee + 1 ether}();
    }

    function test_ConvertToCompounding_RevertsIfInsufficientFee() public {
        uint256 fee = getConsolidationFee();

        vm.prank(validator);
        vm.expectRevert(Coffer.InsufficientFee.selector);
        coffer.convertToCompounding{value: fee - 1}();
    }

    function test_ConvertToCompounding_RevertsIfNotOwner() public {
        uint256 fee = getConsolidationFee();

        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.convertToCompounding{value: fee}();
    }

    function test_ConvertToCompounding_RevertsIfFeeGetterFails() public {
        // Set excess to EXCESS_INHIBITOR to make the fee getter revert
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        vm.prank(validator);
        vm.expectRevert(Coffer.ConsolidationContractCallFailed.selector);
        coffer.convertToCompounding{value: 1 ether}();
    }

    function test_ConvertToCompounding_RevertsIfWriteCallFails() public {
        uint256 fee = getConsolidationFee();

        // Build the exact 96-byte payload that Coffer will send (source + target pubkeys)
        bytes memory data =
            abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2, validPublicKeyPart1, validPublicKeyPart2);

        // Mock the write call to revert (fee getter staticcall still works)
        vm.mockCallRevert(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, fee, data, "");

        vm.prank(validator);
        vm.expectRevert(Coffer.ConsolidationContractCallFailed.selector);
        coffer.convertToCompounding{value: fee}();
    }

    // ========================================
    // issueSize and issueSizeBufferBps are independently settable
    // ========================================

    function test_BufferIssueSize_HighBufferHighIssueSize_Inconsistent() public {
        uint128 startingBalance = 100 ether;
        address bsa1CofferAddr = createCoffer(
            validator,
            bytes32(uint256(0xB5A1)),
            bytes16(uint128(0xB5A1)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            startingBalance
        );
        Coffer c = Coffer(payable(bsa1CofferAddr));

        vm.prank(validator);
        c.changeIssueSizeBufferBps(1000);

        (,,,,,,, uint16 buffer1,,) = c.sValidatorConditions();
        assertEq(buffer1, 1000);

        vm.prank(validator);
        c.changeIssueSize(95 ether);

        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buffer2,,) = c.sValidatorConditions();
        assertEq(issueSize, 95 ether);
        assertEq(buffer2, 1000);

        uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - buffer2) / BUFFER_DENOMINATOR;
        assertEq(maxAllowed, 90 ether, "buffer cap should allow max 90 ETH");
        assertGt(issueSize, maxAllowed, "BUG: issueSize exceeds buffer-capped limit - inconsistent state");
    }

    function test_BufferIssueSize_BufferIncrease_IssueSizeNotReduced() public {
        uint128 startingBalance = 100 ether;
        address bsa1CofferAddr = createCoffer(
            validator,
            bytes32(uint256(0xB5A1)),
            bytes16(uint128(0xB5A1)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            startingBalance
        );
        Coffer c = Coffer(payable(bsa1CofferAddr));

        (uint128 issueSize0,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf0,,) = c.sValidatorConditions();
        assertEq(issueSize0, 100 ether);
        assertEq(buf0, 0);

        for (uint16 i = 0; i < 3; i++) {
            uint16 newBuf = uint16(500 * (i + 1));
            vm.prank(validator);
            c.changeIssueSizeBufferBps(newBuf);

            (uint128 issSize,,,,,,,,,) = c.sValidatorConditions();
            (,,,,,,, uint16 buf,,) = c.sValidatorConditions();
            assertEq(buf, newBuf);

            uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - buf) / BUFFER_DENOMINATOR;
            assertGt(issSize, maxAllowed, "BUG: issueSize not reduced when buffer increased");
        }
    }

    function test_BufferIssueSize_IssueSizeNotCheckedAgainstBuffer() public {
        address bsa1CofferAddr = createCoffer(
            validator,
            bytes32(uint256(0xB5A1)),
            bytes16(uint128(0xB5A1)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );
        Coffer c = Coffer(payable(bsa1CofferAddr));

        vm.prank(validator);
        c.changeIssueSizeBufferBps(500);

        uint128 tooHigh = 31 ether;
        vm.prank(validator);
        c.changeIssueSize(tooHigh);

        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf,,) = c.sValidatorConditions();
        uint256 maxAllowed = uint256(defaultStartingBalance) * (BUFFER_DENOMINATOR - buf) / BUFFER_DENOMINATOR;
        assertGt(issueSize, maxAllowed, "BUG: changeIssueSize accepts values exceeding buffer-capped maximum");
    }

    /// @dev The creation-time formula under fuzzed inputs. The factory's guard and initialize are
    ///      two copies of one expression, so the stored issueSize must equal the emitted one and the formula, stay
    ///      at or below the starting balance, and admit the minimum exactly when it fits. Replaces a fuzz whose only
    ///      assertion restated its own condition. Each run derives its own pubkey, so the clone address is fresh.
    ///      The helpers keep the stack shallow (the ten-field struct read alone needs ten slots).
    function testFuzz_CreateCoffer_IssueSizeFormula_StoredEqualsEmittedAndMinimumGate(
        uint128 startingBalance,
        uint16 bps,
        uint128 minimum,
        bool wantRevert
    ) public {
        // type(uint128).max - 1 keeps expected + 1 inside uint128 for the revert branch
        // forge-lint: disable-next-line(unsafe-typecast)
        startingBalance = uint128(bound(startingBalance, 1, type(uint128).max - 1));
        // forge-lint: disable-next-line(unsafe-typecast)
        bps = uint16(bound(bps, 0, BUFFER_DENOMINATOR - 1));
        uint256 expected = uint256(startingBalance) * (BUFFER_DENOMINATOR - bps) / BUFFER_DENOMINATOR;
        (bytes32 pk1, bytes16 pk2) = _g09Keys(startingBalance, bps, minimum);

        if (expected == 0) wantRevert = true; // no minimum of at least one wei can be admitted
        if (wantRevert) {
            // forge-lint: disable-next-line(unsafe-typecast)
            minimum = uint128(bound(minimum, expected + 1, type(uint128).max));
            _createG09(pk1, pk2, minimum, bps, startingBalance, true);
            return;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        minimum = uint128(bound(minimum, 1, expected));
        vm.recordLogs();
        address clone = _createG09(pk1, pk2, minimum, bps, startingBalance, false);
        _assertG09(clone, pk1, pk2, expected, minimum, startingBalance);
    }

    function _g09Keys(uint128 startingBalance, uint16 bps, uint128 minimum)
        private
        pure
        returns (bytes32 pk1, bytes16 pk2)
    {
        pk1 = keccak256(abi.encode("creation-formula", startingBalance, bps, minimum));
        pk2 = bytes16(keccak256(abi.encode(pk1)));
    }

    /// @dev Creates the coffer as the validator, expecting the minimum gate's revert when asked to
    function _createG09(bytes32 pk1, bytes16 pk2, uint128 minimum, uint16 bps, uint128 startingBalance, bool wantRevert)
        private
        returns (address)
    {
        vm.prank(validator);
        if (wantRevert) vm.expectRevert(CofferFactory.InvalidMinimumValueToAccept.selector);
        return factory.createCoffer(
            pk1, pk2, defaultInterestRate, defaultMinDuration, defaultMaxDuration, minimum, bps, startingBalance
        );
    }

    function _assertG09(
        address clone,
        bytes32 pk1,
        bytes16 pk2,
        uint256 expected,
        uint128 minimum,
        uint128 startingBalance
    ) private {
        uint128 emitted = _cofferIssuedIssueSizeFromLogs();
        uint128 stored = _issueSizeOf(clone);
        assertEq(clone, factory.predictCofferAddress(validator, pk1, pk2), "clone must land at the predicted address");
        assertEq(uint256(stored), expected, "stored issueSize must equal the formula");
        assertEq(emitted, stored, "CofferIssued.issueSize must equal the stored value");
        assertLe(stored, startingBalance, "issueSize must not exceed the starting balance");
        assertEq(_minimumValueOf(clone), minimum, "minimum stored as passed");
        assertLe(_minimumValueOf(clone), stored, "minimum must not exceed issueSize at creation");
    }

    function _issueSizeOf(address c) private view returns (uint128 issueSize) {
        (issueSize,,,,,,,,,) = Coffer(payable(c)).sValidatorConditions();
    }

    function _minimumValueOf(address c) private view returns (uint128 minimumValueToAccept) {
        (,,,, minimumValueToAccept,,,,,) = Coffer(payable(c)).sValidatorConditions();
    }

    /// @dev Returns the issueSize field of the recorded CofferIssued log (its last non-indexed field)
    function _cofferIssuedIssueSizeFromLogs() private returns (uint128 issueSize) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig =
            keccak256("CofferIssued(address,address,bytes32,bytes16,uint32,uint32,uint32,uint128,uint16,uint128)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == sig) {
                (,,,,,, issueSize) =
                    abi.decode(entries[i].data, (bytes16, uint32, uint32, uint32, uint128, uint16, uint128));
                return issueSize;
            }
        }
        revert("CofferIssued not emitted");
    }
}
