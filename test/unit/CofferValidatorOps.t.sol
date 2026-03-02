//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {
    BaseTest,
    CofferEvents,
    WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,
    CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS
} from "./BaseTest.sol";
import {EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

/// @dev Contract that rejects all ETH transfers
contract RejectEther {
    receive() external payable {
        revert();
    }
}

contract CofferValidatorOpsTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Creates coffer, sets available amount, buys a bond — returns (bondId, amountWithInterest)
    function _setupSingleBond(uint128 available, uint128 bondAmount, uint32 duration)
        internal
        returns (uint256 bondId, uint128 amountWithInterest)
    {
        vm.prank(validator);
        coffer.changeIssueSize(available); // version -> 2

        bondId = buyBond(cofferAddr, holder1, bondAmount, duration, 2);

        uint256 interest = Interest.calculateInterest(bondAmount, duration, defaultInterestRate);
        // forge-lint: disable-next-line(unsafe-typecast) bondAmount + interest from test constants fits uint128
        amountWithInterest = uint128(bondAmount + interest);
    }

    // ========================================
    // redeemBondsEarly
    // ========================================

    function test_RedeemBondsEarly_SingleBond_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Fund contract
        vm.deal(cofferAddr, amtOwed);

        uint256 holderBalBefore = holder1.balance;

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);
        vm.snapshotGasLastCall("redeemBondsEarly_single");

        assertEq(holder1.balance, holderBalBefore + amtOwed);
    }

    function test_RedeemBondsEarly_MultipleBonds_Success() public {
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
        coffer.redeemBondsEarly(ids);

        // Both bonds redeemed - outstandingBonds should be 0
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
    }

    function test_RedeemBondsEarly_WithMsgValueTopUp_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Contract has partial_ balance, validator tops up via msg.value
        uint128 partial_ = amtOwed / 2;
        vm.deal(cofferAddr, partial_);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly{value: amtOwed - partial_}(ids);

        (uint128 amt,,) = coffer.sHolderConditions(bondId);
        assertEq(amt, 0); // deleted
    }

    function test_RedeemBondsEarly_BeforeMaturity_Success() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // No time advancement — bond hasn't matured, but redeemBondsEarly has no time check
        vm.deal(cofferAddr, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids); // should succeed
    }

    function test_RedeemBondsEarly_RestoresState() public {
        (uint256 bondId,) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);

        (uint128 issueSize,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 0);
        assertEq(issueSize, 10 ether); // fully restored
    }

    function test_RedeemBondsEarly_EmitsEvent() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed);

        vm.expectEmit(true, true, false, true);
        emit CofferEvents.ValidatorsBondRedeem(holder1, bondId, amtOwed);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);
    }

    function test_RedeemBondsEarly_RevertsIfHolderDoesNotExist() public {
        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.redeemBondsEarly(ids);
    }

    function test_RedeemBondsEarly_RevertsIfAlreadyRedeemed() public {
        (uint256 bondId, uint128 amtOwed) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, amtOwed * 2);

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        coffer.redeemBondsEarly(ids);

        vm.prank(validator);
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnAmount.selector);
        coffer.redeemBondsEarly(ids);
    }

    function test_RedeemBondsEarly_RevertsIfInsufficientBalance() public {
        (uint256 bondId,) = _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        // Do NOT fund contract

        vm.prank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.expectRevert(Coffer.ContractBalanceLessThanAmount.selector);
        coffer.redeemBondsEarly(ids);
    }

    function test_RedeemBondsEarly_RevertsIfNotOwner() public {
        vm.prank(holder1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.redeemBondsEarly(ids);
    }

    function test_RedeemBondsEarly_RevertsIfHolderRejectsEther() public {
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
        vm.expectRevert(Errors.FailedCall.selector);
        coffer.redeemBondsEarly(ids);
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

        uint32 newRate = 2e6; // 2% — decrease is allowed with bonds
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

    function test_ChangeMinimumAndMaximumDuration_DoesNotIncrementVersion() public {
        (,,,,, uint32 vBefore,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, FIVE_YEARS);

        (,,,,, uint32 vAfter,,,,) = coffer.sValidatorConditions();
        assertEq(vAfter, vBefore);
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

    function test_ChangeMinimumAndMaximumDuration_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeMinimumAndMaximumDuration(ONE_WEEK, FIVE_YEARS);
    }

    // ========================================
    // changeMinimumAmountToAccept
    // ========================================

    function test_ChangeMinimumAmountToAccept_UpdatesValue() public {
        uint128 newMin = 0.5 ether;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.MinimumAmountChanged(newMin);

        vm.prank(validator);
        coffer.changeMinimumAmountToAccept(newMin);

        (,,,, uint128 minAmt,,,,,) = coffer.sValidatorConditions();
        assertEq(minAmt, newMin);
    }

    function test_ChangeMinimumAmountToAccept_DoesNotIncrementVersion() public {
        (,,,,, uint32 vBefore,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        coffer.changeMinimumAmountToAccept(0.5 ether);

        (,,,,, uint32 vAfter,,,,) = coffer.sValidatorConditions();
        assertEq(vAfter, vBefore);
    }

    function test_ChangeMinimumAmountToAccept_RevertsIfZero() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ZeroAmount.selector);
        coffer.changeMinimumAmountToAccept(0);
    }

    function test_ChangeMinimumAmountToAccept_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeMinimumAmountToAccept(0.5 ether);
    }

    // ========================================
    // changeIssueSize
    // ========================================

    function test_ChangeIssueSize_UpdatesValue() public {
        uint128 newAmt = 5 ether;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.IssueSizeChanged(0, newAmt);

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
        vm.expectRevert(Coffer.AmountTooSmallToAccept.selector);
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
    // changeExitAllowed
    // ========================================

    function test_ChangeExitAllowed_Enable_EmitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferAllowsHolderToExit();

        vm.prank(validator);
        coffer.changeExitAllowed();

        (,,,,,,,,, bool exitAllowed) = coffer.sValidatorConditions();
        assertTrue(exitAllowed);
    }

    function test_ChangeExitAllowed_Disable_EmitsEvent() public {
        vm.prank(validator);
        coffer.changeExitAllowed(); // enable

        vm.expectEmit(false, false, false, false);
        emit CofferEvents.CofferForbidsHolderToExit();

        vm.prank(validator);
        coffer.changeExitAllowed(); // disable
    }

    function test_ChangeExitAllowed_VersionIncrements() public {
        vm.prank(validator);
        coffer.changeExitAllowed();

        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2);
    }

    function test_ChangeExitAllowed_RevertsIfOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotChangeExitAllowedWhileOutstandingBondExists.selector);
        coffer.changeExitAllowed();
    }

    function test_ChangeExitAllowed_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeExitAllowed();
    }

    // ========================================
    // changeSafeTotalStake
    // ========================================

    function test_ChangeSafeTotalStake_UpdatesAndEmitsEvent() public {
        uint32 newStake = 25_000_000;

        vm.expectEmit(false, false, false, true);
        emit CofferEvents.SafeTotalStakeChanged(defaultSafeTotalStake, newStake);

        vm.prank(validator);
        coffer.changeSafeTotalStake(newStake);

        (,,,,,,, uint32 stake,,) = coffer.sValidatorConditions();
        assertEq(stake, newStake);
    }

    function test_ChangeSafeTotalStake_VersionIncrements() public {
        vm.prank(validator);
        coffer.changeSafeTotalStake(25_000_000);

        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2);
    }

    function test_ChangeSafeTotalStake_RevertsIfIncreaseWithOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist.selector);
        coffer.changeSafeTotalStake(25_000_000); // increase from 20_000_000
    }

    function test_ChangeSafeTotalStake_RevertsIfNotOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.changeSafeTotalStake(25_000_000);
    }

    // ========================================
    // changeIssueSize / changeSafeTotalStake — decrease with bonds
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

    function test_ChangeSafeTotalStake_DecreaseWithBonds_Success() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Decrease is allowed with outstanding bonds
        vm.prank(validator);
        coffer.changeSafeTotalStake(15_000_000); // decrease from 20_000_000

        (,,,,,,, uint32 stake,,) = coffer.sValidatorConditions();
        assertEq(stake, 15_000_000);
    }

    function test_ChangeSafeTotalStake_SameValueWithBonds_Reverts() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);

        // Same value counts as >= so should revert
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist.selector);
        coffer.changeSafeTotalStake(defaultSafeTotalStake);
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
        vm.expectRevert(Coffer.ContractBalanceLessThanAmount.selector);
        coffer.validatorWithdrawFromExecution(2 ether);
    }

    function test_ValidatorWithdrawFromExecution_RevertsIfOutstandingBonds() public {
        _setupSingleBond(10 ether, 1 ether, ONE_MONTH);
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
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
            defaultSafeTotalStake,
            false
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
        vm.expectRevert(Coffer.WithdrawlContractCallFailed.selector);
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
        vm.expectRevert(Coffer.WithdrawlContractCallFailed.selector);
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

        uint256 expectedIncrease = Penalty.addMaximumPenalty(1 ether, defaultSafeTotalStake, defaultMaxDuration / 384);
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
}
