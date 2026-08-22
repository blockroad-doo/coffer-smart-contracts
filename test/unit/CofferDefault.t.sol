//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "./BaseTest.sol";
import {EIP7002Mock, EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CofferDefaultTest
 * @notice Serve-or-default state machine: declareDefault predicate matrix, the five ValidatorInDefault
 * freezes, acceleration (maturity waiver, FCFS, partial payouts), exitValidator (gating, 56-byte
 * full-exit payload, fee handling, re-callability while bonds are outstanding), and clearDefault
 * (the settlement-gated exit from a default)
 * @dev Scenario walkthroughs: cure at the door, the top-up/re-extract yo-yo resolved by the atomic
 * holderRedeemBondOrDefault, the pre-default dust partial that drops the first exit and the retry after the
 * pending tail, pre-default mint ordering, and the in-flight exit request that survives the clear.
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

    function _version() internal view returns (uint32 version) {
        (,,,,, version,,,,) = coffer.sValidatorConditions();
    }

    /// @dev Drives the coffer into the settle-to-clear window: defaulted with every bond settled at
    ///      its full maturity value, so outstandingBonds == 0 while the flag still stands
    function _defaultAndSettleAllBonds() internal {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);
        vm.deal(cofferAddr, bmv);
        vm.prank(holder1);
        coffer.holderRedeemBondInDefault(bondId);
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
    // Cure at the door: the only useful front-run is paying
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
        coffer.holderRedeemBondOrDefault(bondId);
        assertEq(holder1.balance, balBefore + bmv, "holder collects in full");
    }

    function test_DeclareDefault_CureByRedeem_ThenDefaultHitsExistenceCheck() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();

        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(validator);
        coffer.validatorRedeemBonds{value: bmv}(ids);

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

    function test_Defaulted_ValidatorRedeemBondsStillWorks() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // Paying holders remains open during default
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(validator);
        coffer.validatorRedeemBonds{value: bmv}(ids);

        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, 0, "bond settled via escrow during default");
        // A9: a redeemed holder is never underpaid, even in default: the escrow holds the full value
        assertEq(redemptionEscrow.sPendingClaims(holder1), bmv, "escrow credited with the full maturity value");
    }

    function test_Defaulted_ReceiveStaysOpen() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(validator);
        (bool ok,) = cofferAddr.call{value: 3 ether}("");
        require(ok, "cure/donation path must stay open");
        assertEq(cofferAddr.balance, 3 ether, "contract balance grew");
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
        coffer.holderRedeemBondInDefault(b2);
        assertEq(holder2.balance, balBefore + bmv2, "immature bond claims full maturity value post-default");
    }

    function test_Defaulted_PartialPayout_ThenZeroBalanceReverts() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.deal(cofferAddr, bmv - 1 ether);
        vm.prank(holder1);
        coffer.holderRedeemBondInDefault(bondId);

        (uint128 remaining,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, 1 ether, "partial payout tracked");

        // Balance is drained: the zero-balance gate fails closed
        vm.prank(holder1);
        vm.expectRevert(Coffer.NothingToRedeem.selector);
        coffer.holderRedeemBondInDefault(bondId);
    }

    function test_Defaulted_ClaimsAreFCFS() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, 1);
        (uint128 bmv1,,) = coffer.sHolderConditions(b1);
        advanceTime(ONE_MONTH + 1);
        coffer.declareDefault(b1);

        // The contract balance covers exactly one bond: first come, first served
        vm.deal(cofferAddr, bmv1);
        vm.prank(holder1);
        coffer.holderRedeemBondInDefault(b1);

        vm.prank(holder2);
        vm.expectRevert(Coffer.NothingToRedeem.selector);
        coffer.holderRedeemBondInDefault(b2);
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

    function test_ExitValidator_SurplusNotRefunded_AccruesToContractBalance() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        uint256 fee = getWithdrawalFee();
        uint256 balanceBefore = cofferAddr.balance;
        coffer.exitValidator{value: fee + 1 ether}();

        assertEq(cofferAddr.balance, balanceBefore + 1 ether, "surplus stays in the contract balance");
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

    function test_ExitValidator_RecallableWhileBondsOutstanding_EachCallEnqueues() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        // A CL-side drop is off-chain silence — the EL predeploy accepts repeat requests, so
        // re-calling after a dropped request just enqueues again. Retries stay open for as long
        // as any bond is outstanding.
        coffer.exitValidator{value: getWithdrawalFee()}();
        coffer.exitValidator{value: getWithdrawalFee()}();

        (, uint256 count,,) = getQueueState();
        assertEq(count, 2, "every retry lands a fresh request");
    }

    function test_ExitValidator_RevertsIfNoOutstandingBonds() public {
        _defaultAndSettleAllBonds();

        // The settle-to-clear window: nothing is left to recover, so the exit weapon disarms and a
        // griefer cannot front-run the owner's clearDefault with a last exit request
        vm.expectRevert(Coffer.NoOutstandingBonds.selector);
        coffer.exitValidator{value: 1 ether}();
    }

    // ========================================
    // clearDefault: the settlement-gated exit from a default
    // ========================================

    function test_ClearDefault_RevertsIfNotDefaulted() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorNotInDefault.selector);
        coffer.clearDefault();
    }

    function test_ClearDefault_RevertsIfBondsOutstanding() public {
        (uint256 bondId,) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        vm.prank(validator);
        vm.expectRevert(Coffer.OutstandingBondsExist.selector);
        coffer.clearDefault();
    }

    function test_ClearDefault_RevertsIfNotOwner() public {
        _defaultAndSettleAllBonds();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        coffer.clearDefault();
    }

    function test_ClearDefault_ClearsFlagBumpsVersionAndEmits() public {
        _defaultAndSettleAllBonds();
        uint32 versionBefore = _version();

        vm.expectEmit(true, false, false, true, cofferAddr);
        emit Coffer.VersionChanged(versionBefore + 1);
        vm.expectEmit(false, false, false, true, cofferAddr);
        emit Coffer.ValidatorDefaultCleared();
        vm.prank(validator);
        coffer.clearDefault();

        assertFalse(_isDefaulted(), "flag cleared");
        assertEq(_version(), versionBefore + 1, "version bumped exactly once");
    }

    function test_ClearDefault_UnfreezesValidatorFunctions() public {
        _defaultAndSettleAllBonds();
        vm.prank(validator);
        coffer.clearDefault();

        // Surplus leaves through the normal zero-bond branch of validatorWithdrawFromExecution
        vm.deal(cofferAddr, 3 ether);
        uint256 balBefore = validator.balance;
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(3 ether);
        assertEq(validator.balance, balBefore + 3 ether, "surplus recovered post-clear");

        // Consensus-side functions no longer revert ValidatorInDefault
        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: 1 ether}(1);

        // Bond sales reopen at the current version
        uint256 bondId = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, _version());
        (uint128 bmv,,) = coffer.sHolderConditions(bondId);
        assertGt(bmv, 0, "new epoch bond minted");
    }

    function test_ClearDefault_StaleVersionBuyBondReverts() public {
        uint32 preDefaultVersion = _version();
        _defaultAndSettleAllBonds();
        vm.prank(validator);
        coffer.clearDefault();

        // A buyBond broadcast before the default cannot land against the cleared coffer
        vm.prank(holder2);
        vm.expectRevert(Coffer.ValidatorConditionsVersionMismatch.selector);
        coffer.buyBond{value: 5 ether}(ONE_MONTH, preDefaultVersion);
    }

    /// @dev The full lifecycle: default, settle every bond at full maturity value, clear, re-attest
    ///      issueSize, sell into the new epoch, and the default machine re-arms
    function test_Scenario_FullCycle_DefaultSettleClearResellRedefault() public {
        _defaultAndSettleAllBonds();

        vm.prank(validator);
        coffer.clearDefault();
        assertFalse(_isDefaulted(), "first epoch closed");

        // Re-attest capacity for the new epoch (changeIssueSize bumps the version again)
        vm.prank(validator);
        coffer.changeIssueSize(20 ether);
        uint256 bondId = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, _version());

        // The new bond matures unpaid: the machine re-arms exactly as on a fresh coffer
        advanceTime(ONE_MONTH + 1);
        assertEq(cofferAddr.balance, 0, "principal forwarded, bond unpayable");
        coffer.declareDefault(bondId);
        assertTrue(_isDefaulted(), "second epoch opened");
    }

    /// @dev Settlement via the escrow path: validatorRedeemBonds drops outstandingBonds to zero while the
    ///      holder's claim is still pending in CofferRedemptionEscrow. Pins the cure gate's
    ///      definition of "paid in full" — escrowed at full maturity value counts — and that a
    ///      pending escrow claim survives the clear untouched.
    function test_ClearDefault_AfterEscrowSettlement_EscrowClaimStillPays() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);
        assertTrue(_isDefaulted(), "default declared");

        // The validator funds the shortfall via msg.value and settles through the escrow path
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;
        vm.prank(validator);
        coffer.validatorRedeemBonds{value: bmv}(ids);

        (,,,,,, uint32 outstanding,,,) = coffer.sValidatorConditions();
        assertEq(outstanding, 0, "settlement reached through the escrow path");
        assertEq(redemptionEscrow.sPendingClaims(holder1), bmv, "full maturity value escrowed");

        // The settle-to-clear window is open despite the pending claim
        vm.prank(validator);
        coffer.clearDefault();
        assertFalse(_isDefaulted(), "default cleared on escrow settlement");

        // The pending escrow claim is unaffected and pays in full
        uint256 balBefore = holder1.balance;
        vm.prank(holder1);
        redemptionEscrow.claim(payable(holder1));
        assertEq(redemptionEscrow.sPendingClaims(holder1), 0, "claim consumed");
        assertEq(holder1.balance, balBefore + bmv, "escrow paid the full maturity value");
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
    // Scenario walkthroughs
    // ========================================

    /// @dev The top-up/re-extract yo-yo is dead. The holder's holderRedeemBondOrDefault
    ///      declares the default in the same transaction as a failed redeem, so the validator can
    ///      no longer dodge declareDefault with a top-up and re-extract it: the moment the balance
    ///      fails to cover the bond, the default lands and every extraction path freezes. A top-up
    ///      can still buy the validator a paid-out bond, but that is paying, not a dodge.
    function test_Scenario_TopUpReExtractYoYo_AtomicDefaultEndsIt() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();

        // The permissionless declareDefault can still be dodged by paying: a top-up covers
        // the bond, so the declaration reverts...
        vm.prank(validator);
        (bool ok,) = cofferAddr.call{value: bmv}("");
        require(ok, "top-up");
        vm.expectRevert(Coffer.ValidatorNotDefaultable.selector);
        coffer.declareDefault(bondId);

        // ...and the validator re-extracts the cure via the receive() issueSize bump
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(bmv);
        assertEq(cofferAddr.balance, 0, "drained again");

        // The holder's redeem lands against the drained balance: the shortfall declares the default
        // atomically — no second top-up/re-extract round is possible
        vm.expectEmit(true, true, false, true, cofferAddr);
        emit Coffer.ValidatorDefaulted(bondId, holder1);
        vm.prank(holder1);
        bool paidInFull = coffer.holderRedeemBondOrDefault(bondId);
        assertFalse(paidInFull, "shortfall, not a payout");
        assertTrue(_isDefaulted(), "default declared in the same transaction");

        // The re-extract leg of the yo-yo is frozen: a fresh top-up can no longer be pulled back out
        vm.deal(cofferAddr, bmv);
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.validatorWithdrawFromExecution(bmv);

        // The only exit is full payment: the holder claims, then the validator clears the default
        vm.prank(holder1);
        coffer.holderRedeemBondInDefault(bondId);
        vm.prank(validator);
        coffer.clearDefault();
        assertFalse(_isDefaulted(), "full payment discharged the default");
    }

    /// @dev Aggregate-insolvent but per-bond-covered is not a deadlock. With the balance
    ///      covering each bond individually, no default is declarable, but FCFS lets the first
    ///      claim drain the contract balance, after which the second bond's default fires.
    function test_Scenario_AggregateInsolvent_NoDeadlock() public {
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

        // FCFS: H1 drains the contract balance in full
        vm.prank(holder1);
        coffer.holderRedeemBondOrDefault(b1);

        // Now B2 is matured and unpayable: the default fires. No deadlock state exists.
        coffer.declareDefault(b2);
        assertTrue(_isDefaulted());
    }

    /// @dev NFTs stay transferable during default and the claim follows ownerOf, moved
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
        coffer.holderRedeemBondInDefault(bondId);

        // The buyer collects in full
        uint256 balBefore = holder3.balance;
        vm.prank(holder3);
        coffer.holderRedeemBondInDefault(bondId);
        assertEq(holder3.balance, balBefore + bmv, "claim follows the NFT owner");
    }

    /// @dev Ownable2Step stays live during default. The owner role carries the payment powers
    ///      and the clear power, so a transferee (e.g. a rescuer) can settle every holder via
    ///      escrow and then clear the default. The extraction freezes bind the new owner while the
    ///      default stands, exactly as they bound the old one.
    function test_Defaulted_OwnershipTransferCarriesPaymentAndClearPowers() public {
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
        coffer.validatorRedeemBonds{value: bmv}(ids);
        assertEq(redemptionEscrow.sPendingClaims(holder1), bmv, "rescuer settled the holder in full");

        // Settlement zeroed outstandingBonds, so the clear power is live for the new owner
        vm.prank(rescuer);
        coffer.clearDefault();
        assertFalse(_isDefaulted(), "rescuer cleared the default after settling in full");
    }

    /// @dev A pre-default dust partial blocks the first exit request and the retry after
    ///      the pending tail lands. Pinned end to end with the mock's pending-partial modeling:
    ///      the dust partial becomes a pending, the exit request is silently dropped, and a retry
    ///      after the tail clears enqueues a working request.
    function test_Scenario_PreDefaultDustPartial_DropsExit_RetryAfterTailLands() public {
        (uint256 bondId,) = _maturedUnpaidBond();

        // The dust partial fired just before the flip: enqueued, then processed into a pending
        uint256 fee = getWithdrawalFee();
        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(1);
        bytes memory returned = triggerSystemCall();
        assertEq(returned.length, 76, "dust partial dequeued into a pending");

        // The pending now exists (modeled by the mock's pending-partial flag)
        EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).setPendingPartialBlocksExits(true);

        coffer.declareDefault(bondId);

        // First exit request: silently dropped by the CL, nothing burned
        coffer.exitValidator{value: getWithdrawalFee()}();
        returned = triggerSystemCall();
        assertEq(returned.length, 0, "exit request dropped while the pending exists");

        // The pending tail drains (~28 h): the retry lands
        EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).setPendingPartialBlocksExits(false);
        coffer.exitValidator{value: getWithdrawalFee()}();
        returned = triggerSystemCall();
        assertWithdrawalRequest(returned, 0, cofferAddr, validPublicKeyPart1, validPublicKeyPart2, 0);
    }

    /// @dev An exit request already enqueued cannot be cancelled. The validator settles every
    ///      bond and clears the default while the request is still in flight — the clear does not
    ///      block on it, the EL queue still carries the request, and the new epoch operates.
    function test_Scenario_InFlightExitRequest_SurvivesClear() public {
        (uint256 bondId, uint128 bmv) = _maturedUnpaidBond();
        coffer.declareDefault(bondId);

        coffer.exitValidator{value: getWithdrawalFee()}();

        // Settle every bond at full maturity value while the request sits in the queue
        vm.deal(cofferAddr, bmv);
        vm.prank(holder1);
        coffer.holderRedeemBondInDefault(bondId);

        // The settle-to-clear window: the in-flight request does not block the clear
        vm.prank(validator);
        coffer.clearDefault();
        assertFalse(_isDefaulted(), "clear succeeded with the request still in flight");

        // The request is still enqueued EL-side (nothing can cancel it)
        (, uint256 count,, uint256 queueTail) = getQueueState();
        assertEq(count, 1, "one request pending in the block queue");
        assertEq(queueTail, 1, "request still enqueued after the clear");

        // The new epoch operates while the request is in flight
        vm.prank(validator);
        coffer.changeIssueSize(20 ether);
        uint256 newBondId = buyBond(cofferAddr, holder2, 5 ether, ONE_MONTH, _version());
        (uint128 newBmv,,) = coffer.sHolderConditions(newBondId);
        assertGt(newBmv, 0, "new epoch sells bonds while the request is in flight");
    }

    /// @dev Maturity arithmetic is widened to uint256, so a maturity past the uint32
    ///      timestamp ceiling (year ~2106) can neither panic nor read as already-matured. The
    ///      unwidened uint32 addition would overflow-revert and brick both withdrawal and default
    ///      for the bond.
    function test_Scenario_WidenedMaturityPastUint32Ceiling() public {
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
        longCoffer.holderRedeemBondOrDefault(bondId);
        vm.expectRevert(Coffer.HoldersTimeHasNotExpiredYet.selector);
        longCoffer.declareDefault(bondId);

        // Post-maturity (year ~2134): the same bond defaults and claims normally
        vm.warp(uint256(duration) + uint256(startTimestamp) + 1);
        longCoffer.declareDefault(bondId);
        vm.deal(longCofferAddr, bmv);
        uint256 balBefore = holder1.balance;
        vm.prank(holder1);
        longCoffer.holderRedeemBondInDefault(bondId);
        assertEq(holder1.balance, balBefore + bmv, "widened maturity math settles the bond");
    }

    /// @dev Mint ordering around the default flip
    function test_Scenario_MintOrderingAroundDefaultFlip() public {
        uint256 b1 = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        // [buy, default]: a same-block mint before the flip joins the frozen FCFS queue, accelerated
        uint256 b2 = buyBond(cofferAddr, holder2, 5 ether, ONE_YEAR, 1);
        (uint128 bmv2,,) = coffer.sHolderConditions(b2);
        coffer.declareDefault(b1);

        vm.deal(cofferAddr, bmv2);
        vm.prank(holder2);
        coffer.holderRedeemBondInDefault(b2);

        // [default, buy]: after the flip, minting is frozen
        vm.prank(holder3);
        vm.expectRevert(Coffer.ValidatorInDefault.selector);
        coffer.buyBond{value: 5 ether}(ONE_MONTH, 1);
    }
}
