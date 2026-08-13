//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "./BaseTest.sol";
import {EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title CofferDefaultTest
 * @notice Serve-or-default state machine: declareDefault predicate matrix, irreversibility, the five
 * ValidatorInDefault freezes, acceleration (maturity waiver, FCFS, partial payouts), and exitValidator
 * (gating, 56-byte full-exit payload, fee handling, permanent re-callability)
 * @dev Scenario walkthroughs A1 (cure at the door), A2 (top-up/re-extract yo-yo), and A8 (pre-default
 * mint ordering) from docs/fixing-frontruning-partial-withdraws.md are pinned at the bottom
 */
contract CofferDefaultTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Buys a 5 ETH bond and matures it. buyBond forwards the principal to the validator, so the
    ///      contract holds nothing and the bond is unpayable — the default predicate is live.
    function _maturedUnpaidBond() internal returns (uint256 bondId, uint128 bmv) {
        bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        (bmv,,) = coffer.sHolderConditions(bondId);
        advanceTime(ONE_MONTH + 1);
        assertEq(cofferAddr.balance, 0, "sanity: principal was forwarded, nothing backs the bond");
    }

    function _isDefaulted() internal view returns (bool defaulted) {
        (,,,,,,,,, defaulted) = coffer.sValidatorConditions();
    }

    // ========================================
    // declareDefault: predicate matrix
    // ========================================

    function test_DeclareDefault_Success_FlipsFlagAndEmitsEvent() public {
        (uint256 bondId,) = _maturedUnpaidBond();

        vm.expectEmit(true, true, false, true, cofferAddr);
        emit Coffer.ValidatorDefaulted(bondId, address(this));
        coffer.declareDefault(bondId);

        assertTrue(_isDefaulted(), "flag must flip");
    }

    function test_DeclareDefault_AnyoneCanCall() public {
        (uint256 bondId,) = _maturedUnpaidBond();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        coffer.declareDefault(bondId);

        assertTrue(_isDefaulted(), "third party can declare");
    }

    function test_DeclareDefault_RevertsIfBondDoesNotExist() public {
        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.declareDefault(999);
    }

    function test_DeclareDefault_RevertsIfNotMatured() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);

        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        coffer.declareDefault(bondId);
    }

    function test_DeclareDefault_RevertsIfBondCovered() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        vm.deal(cofferAddr, bmv);

        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(bondId);
    }

    function test_DeclareDefault_RevertsIfAlreadyDefaulted() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.expectRevert(Coffer.AlreadyDefaulted.selector);
        coffer.declareDefault(bondId);
    }

    function test_DeclareDefault_SecondQualifyingBondAlsoReverts() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        coffer.declareDefault(b1);

        // b2 independently satisfies the predicate, but the flag is global
        vm.expectRevert(Coffer.AlreadyDefaulted.selector);
        coffer.declareDefault(b2);
    }

    // ========================================
    // A1 — cure at the door: the only useful front-run is paying
    // ========================================

    function test_DeclareDefault_CureByTopUp_ThenHolderClaimsInFull() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();

        // V front-runs the default transaction with a receive() top-up covering the bond
        vm.prank(validator);
        (bool ok,) = cofferAddr.call{value: bmv}("");
        require(ok, "top-up");

        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(bondId);

        uint256 balBefore = holder1.balance;
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
        assertEq(holder1.balance, balBefore + bmv, "holder collects in full");
    }

    function test_DeclareDefault_CureByRedeem_ThenDefaultHitsExistenceCheck() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();

        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(validator);
        coffer.redeemBondsEarly{value: bmv}(ids);

        vm.expectRevert(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        coffer.declareDefault(bondId);
    }

    // ========================================
    // R4 — the five freezes, and what stays open
    // ========================================

    function test_Defaulted_BuyBondReverts() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(holder2);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.buyBond{value: 5 ether}(ONE_MONTH, 1);
    }

    function test_Defaulted_ValidatorWithdrawFromExecutionReverts() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);
        vm.deal(cofferAddr, 1 ether); // even with balance present

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    function test_Defaulted_ValidatorWithdrawFromConsensusReverts() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // The security boundary: no new pending partial can ever be created post-default
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorWithdrawFromConsensus{value: 1 ether}(1);
    }

    function test_Defaulted_ValidatorAddFundsToConsensusReverts() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorAddFundsToConsensus{value: 1 ether}(bytes32(0));
    }

    function test_Defaulted_ConvertToCompoundingReverts() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.convertToCompounding{value: 1 ether}();
    }

    function test_Defaulted_RedeemBondsEarlyStillWorks() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // Paying holders remains open during default
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(validator);
        coffer.redeemBondsEarly{value: bmv}(ids);

        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, 0, "bond settled via escrow during default");
        // A9: a redeemed holder is never underpaid, even in default: the escrow holds the full value
        assertEq(bondsRedeemedEarly.sPendingClaims(holder1), bmv, "escrow credited with the full maturity value");
    }

    function test_Defaulted_ReceiveStaysOpen() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(validator);
        (bool ok,) = cofferAddr.call{value: 3 ether}("");
        require(ok, "cure/donation path must stay open");
        assertEq(cofferAddr.balance, 3 ether, "pool grew");
    }

    // ========================================
    // R5 — acceleration
    // ========================================

    function test_Defaulted_ImmatureBondClaimsFullValue() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_YEAR, 1);
        (uint128 bmv2,,) = coffer.sHolderConditions(b2);

        advanceTime(ONE_MONTH + 1); // b1 matured, b2 is ~11 months from maturity
        coffer.declareDefault(b1);

        vm.deal(cofferAddr, bmv2);
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(b2);
        assertEq(holder2.balance, balBefore + bmv2, "immature bond claims full maturity value post-default");
    }

    function test_Defaulted_PartialPayout_ThenZeroBalanceReverts() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.deal(cofferAddr, bmv - 1 ether);
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, 1 ether, "partial payout tracked");

        // Pool is drained: the partial branch's balance gate fails closed
        vm.prank(holder1);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_Defaulted_ClaimsAreFCFS() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, 1);
        (uint128 bmv1,,) = coffer.sHolderConditions(b1);
        advanceTime(ONE_MONTH + 1);
        coffer.declareDefault(b1);

        // Pool covers exactly one bond: first come, first served
        vm.deal(cofferAddr, bmv1);
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(b1);

        vm.prank(holder2);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.holderWithdrawFromExecution(b2);
    }

    // ========================================
    // R6 — exitValidator
    // ========================================

    function test_ExitValidator_RevertsIfNotDefaulted() public {
        vm.expectRevert(Coffer.ValidatorNotInDefault.selector);
        coffer.exitValidator{value: 1 ether}();
    }

    function test_ExitValidator_SendsFullExitRequest_PayloadVerified() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        coffer.exitValidator{value: fee}();

        // Dequeue at the predeploy and byte-assert the 56-byte request: source = the coffer,
        // pubkey halves from CWIA args, amount 0 = full exit
        bytes memory requests = triggerSystemCall();
        assertWithdrawalRequest(requests, 0, cofferAddr, validPublicKeyPart1, validPublicKeyPart2, 0);
    }

    function test_ExitValidator_ExactFeeSucceeds_AndEmits() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        vm.expectEmit(true, false, false, true, cofferAddr);
        emit Coffer.ValidatorExitRequested(address(this));
        coffer.exitValidator{value: fee}();

        (, uint256 count,,) = getQueueState();
        assertEq(count, 1, "request enqueued at exact fee");
    }

    function test_ExitValidator_RevertsIfInsufficientFee() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        vm.expectRevert(Coffer.InsufficientFee.selector);
        coffer.exitValidator{value: fee - 1}();
    }

    function test_ExitValidator_SurplusNotRefunded_AccruesToPool() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        uint256 poolBefore = cofferAddr.balance;
        coffer.exitValidator{value: fee + 1 ether}();

        assertEq(cofferAddr.balance, poolBefore + 1 ether, "surplus stays in the holders' pool");
    }

    function test_ExitValidator_RevertsIfFeeGetterFails() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // Set excess to EXCESS_INHIBITOR to make the fee getter revert (readOk = false leg)
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.exitValidator{value: 1 ether}();
    }

    function test_ExitValidator_RevertsIfWriteCallFails() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        // The exact 56-byte full-exit payload Coffer sends; mock only the write call to revert
        bytes memory data = abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2, uint64(0));
        vm.mockCallRevert(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, fee, data, "");

        vm.expectRevert(Coffer.WithdrawalContractCallFailed.selector);
        coffer.exitValidator{value: fee}();
    }

    function test_ExitValidator_RecallableForever_EachCallEnqueues() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // A CL-side drop is off-chain silence — the EL predeploy accepts repeat requests, so
        // re-calling after a dropped request just enqueues again. Nothing is one-shot.
        coffer.exitValidator{value: getWithdrawalFee()}();
        coffer.exitValidator{value: getWithdrawalFee()}();

        (, uint256 count,,) = getQueueState();
        assertEq(count, 2, "every retry lands a fresh request");
    }

    // ========================================
    // validatorWithdrawFromExecution balance gate (bonds outstanding)
    // ========================================

    function test_ValidatorWithdrawFromExecution_RevertsIfBalanceShort_WithBondsOutstanding() public {
        // A bond exists (outstandingBonds > 0) but the principal was forwarded: balance is 0 while
        // issueSize still has headroom, so the balance gate is what stops the withdrawal
        buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        assertEq(cofferAddr.balance, 0);

        vm.prank(validator);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.validatorWithdrawFromExecution(1 ether);
    }

    // ========================================
    // Scenario walkthroughs (doc §9)
    // ========================================

    /// @dev A2: the top-up/re-extract yo-yo is bounded — each dodge re-arms declareDefault, and one
    ///      slip ends the game permanently
    function test_Scenario_A2_TopUpReExtractYoYo_OneSlipEndsIt() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();

        // Dodge: top-up covers the bond, default is not declarable
        vm.prank(validator);
        (bool ok,) = cofferAddr.call{value: bmv}("");
        require(ok, "top-up");
        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(bondId);

        // Re-extract: the receive() bump restored issueSize headroom, so V can pull the ETH back out
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(bmv);

        // The slip: the moment the balance is out, anyone lands the default
        coffer.declareDefault(bondId);
        assertTrue(_isDefaulted());

        // Permanently: no further extraction, ever
        vm.deal(cofferAddr, bmv);
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorWithdrawFromExecution(bmv);
    }

    /// @dev A6: aggregate-insolvent but per-bond-covered is not a deadlock. With the balance
    ///      covering each bond individually, no default is declarable, but FCFS lets the first
    ///      claim drain the pool, after which the second bond's default fires.
    function test_Scenario_A6_AggregateInsolvent_NoDeadlock() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, 1);
        (uint128 bmv1,,) = coffer.sHolderConditions(b1);
        (uint128 bmv2,,) = coffer.sHolderConditions(b2);
        advanceTime(ONE_MONTH + 1);

        // Fund exactly one bond's worth: each bond is individually covered
        uint128 funded = bmv1 > bmv2 ? bmv1 : bmv2;
        vm.deal(cofferAddr, funded);

        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(b1);
        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(b2);

        // FCFS: H1 drains the pool in full
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(b1);

        // Now B2 is matured and unpayable: the default fires. No deadlock state exists.
        coffer.declareDefault(b2);
        assertTrue(_isDefaulted());
    }

    /// @dev A16: NFTs stay transferable during default and the claim follows ownerOf, moved
    ///      never duplicated
    function test_Defaulted_TransferredBondClaimFollowsNewOwner() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder3, bondId);

        vm.deal(cofferAddr, bmv);

        // The seller has no claim left
        vm.prank(holder1);
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(bondId);

        // The buyer collects in full
        uint256 balBefore = holder3.balance;
        vm.prank(holder3);
        coffer.holderWithdrawFromExecution(bondId);
        assertEq(holder3.balance, balBefore + bmv, "claim follows the NFT owner");
    }

    /// @dev A22: Ownable2Step stays live during default. The owner role carries only payment
    ///      powers, so transferring it (e.g. to a rescuer settling via escrow) is harmless.
    function test_Defaulted_OwnershipTransferCarriesOnlyPaymentPowers() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        address rescuer = makeAddr("rescuer");
        vm.deal(rescuer, 100 ether);

        vm.prank(validator);
        coffer.transferOwnership(rescuer);
        vm.prank(rescuer);
        coffer.acceptOwnership();
        assertEq(coffer.owner(), rescuer, "ownership transferable during default");

        // The freezes bind the new owner exactly the same
        vm.prank(rescuer);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorWithdrawFromExecution(1 ether);

        // The payment power works: the rescuer settles the bond via escrow
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(rescuer);
        coffer.redeemBondsEarly{value: bmv}(ids);
        assertEq(bondsRedeemedEarly.sPendingClaims(holder1), bmv, "rescuer settled the holder in full");
    }

    /// @dev A24: maturity arithmetic is widened to uint256, so a maturity past the uint32
    ///      timestamp ceiling (year ~2106) can neither panic nor read as already-matured. The
    ///      unwidened uint32 addition would overflow-revert and brick both withdrawal and default
    ///      for the bond.
    function test_Scenario_A24_WidenedMaturityPastUint32Ceiling() public {
        // A coffer offering 50-year durations (the protocol maximum)
        address longCofferAddr = createCoffer(
            validator,
            bytes32(uint256(0xA24)),
            bytes16(uint128(0xA24)),
            defaultInterestRate,
            defaultMinDuration,
            uint32(1_576_800_000), // MAX_DURATION, 50 years
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );
        Coffer longCoffer = Coffer(payable(longCofferAddr));

        // Year ~2084: startTimestamp still fits uint32, maturity does not
        vm.warp(3_600_000_000);
        vm.prank(holder1);
        uint256 bondId = longCoffer.buyBond{value: 5 ether}(1_576_800_000, 1);
        (uint128 bmv, uint32 duration, uint32 startTimestamp) = longCoffer.sHolderConditions(bondId);
        assertGt(uint256(duration) + uint256(startTimestamp), type(uint32).max, "maturity exceeds the uint32 ceiling");

        // Pre-maturity: clean reverts, no overflow panic, and not treated as matured
        vm.deal(longCofferAddr, 0);
        vm.prank(holder1);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        longCoffer.holderWithdrawFromExecution(bondId);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        longCoffer.declareDefault(bondId);

        // Post-maturity (year ~2134): the same bond defaults and claims normally
        vm.warp(uint256(duration) + uint256(startTimestamp) + 1);
        longCoffer.declareDefault(bondId);
        vm.deal(longCofferAddr, bmv);
        uint256 balBefore = holder1.balance;
        vm.prank(holder1);
        longCoffer.holderWithdrawFromExecution(bondId);
        assertEq(holder1.balance, balBefore + bmv, "widened maturity math settles the bond");
    }

    /// @dev A8: mint ordering around the default flip
    function test_Scenario_A8_MintOrdering() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        // [buy, default]: a same-block mint before the flip joins the frozen FCFS pool, accelerated
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_YEAR, 1);
        (uint128 bmv2,,) = coffer.sHolderConditions(b2);
        coffer.declareDefault(b1);

        vm.deal(cofferAddr, bmv2);
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(b2);

        // [default, buy]: after the flip, minting is frozen
        vm.prank(holder3);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.buyBond{value: 5 ether}(ONE_MONTH, 1);
    }
}
