//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

contract VerifyValidatorWithdrawTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // V-1: CS-12 — ValidatorWithdrawFromExecution undercollateralizes
    //      non-consensus-closed bond holders
    // ========================================

    /// @dev PoC: Validator drains execution-layer ETH that non-consensus-closed
    /// holders depend on. The gate `balance >= _amount + totalConsensusReserved`
    /// only protects consensus-closed bonds (those in totalConsensusReserved).
    /// After validator extraction, non-consensus-closed holders face partial
    /// or zero withdrawals from the execution layer.
    function test_V1_ValidatorDrainUndercollateralizesNonConsensusClosedHolder() public {
        // 1. Set issueSize so bonds can be bought
        vm.prank(validator);
        coffer.changeIssueSize(100 ether); // version -> 2

        // 2. Holder buys bond: 10 ETH, 1 month, 5% interest
        uint256 bondId = buyBond(cofferAddr, holder1, 10 ether, ONE_MONTH, 2);

        (uint128 bondMaturityValue,,, bool consensusWithdrawClosed) = coffer.sHolderConditions(bondId);
        assertFalse(consensusWithdrawClosed, "bond not consensus-closed");
        assertGt(bondMaturityValue, 10 ether, "bond has value > principal");

        // 3. Advance past maturity
        advanceTime(ONE_MONTH + 1);

        // 4. Read pre-attack state
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();
        uint128 totalConsensusReservedBefore = coffer.totalConsensusReserved();
        assertEq(totalConsensusReservedBefore, 0, "no consensus-closed bonds");

        // 5. Simulate: validator's partial consensus withdrawal arrives at execution
        //    (EIP-4895 sweep: receive() does NOT fire, issueSize unchanged)
        //    Contract gets 50 ETH from consensus withdrawal
        vm.deal(cofferAddr, 50 ether);
        assertEq(cofferAddr.balance, 50 ether);

        // 6. Validator withdraws execution-layer ETH
        //    Gate 1: _amount <= issueSize (passes since issueSize >> 50)
        //    Gate 2: balance >= _amount + totalConsensusReserved
        //            = 50 >= 50 + 0 = passes
        //    => Validator drains 50 ETH, contract has 0 left
        uint128 drainAmount = 50 ether;
        assertLe(drainAmount, issueSizeBefore, "drain amount within issueSize");

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(drainAmount);

        // 7. Contract balance is now 0 — non-consensus-closed holder stranded
        assertEq(cofferAddr.balance, 0, "contract drained to zero");

        // 8. Holder tries to withdraw from execution → REVERTS
        //    balance(0) > reserved(0) → false → ContractBalanceLessThanValue
        vm.prank(holder1);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        coffer.holderWithdrawFromExecution(bondId);

        // 9. Bond is still active with full value — holder is undercollateralized
        (uint128 remaining,,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, bondMaturityValue, "bond still active, holder stranded");

        // 10. outstandingBonds unchanged — validator can't increase issueSize
        //     (monotonicity guard blocks increase while bonds exist)
        (,,,,,, uint32 bonds,,,) = coffer.sValidatorConditions();
        assertEq(bonds, 1, "bond still outstanding");
    }

    /// @dev PoC: Even partial drain leaves holder undercollateralized.
    /// Validator leaves only 1 wei in contract — holder gets partial withdrawal
    /// of 1 wei instead of full bondMaturityValue.
    function test_V1_PartialDrainLeavesHolderUndercollateralized() public {
        // Setup: buy bond with large issueSize
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 10 ether, ONE_MONTH, 2);

        (uint128 bondMaturityValue,,,) = coffer.sHolderConditions(bondId);
        advanceTime(ONE_MONTH + 1);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        // Fund contract with exactly bondMaturityValue + 60 wei
        vm.deal(cofferAddr, uint256(bondMaturityValue) + 60);

        // Validator drains up to issueSize, leaving only enough for
        // totalConsensusReserved (which is 0) + 1 wei
        uint128 drainAmt = uint128(cofferAddr.balance - 1);
        assertLe(drainAmt, issueSizeBefore, "drain within issueSize");

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(drainAmt);

        // Contract has only 1 wei
        assertEq(cofferAddr.balance, 1, "only 1 wei left");

        // Holder withdraws: partial path, gets 1 wei
        uint256 holderBalBefore = holder1.balance;
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);

        uint256 holderReceived = holder1.balance - holderBalBefore;
        assertEq(holderReceived, 1, "holder got only 1 wei");
        assertLt(holderReceived, bondMaturityValue, "holder severely undercollateralized");

        // Remaining bond value
        (uint128 remaining,,,) = coffer.sHolderConditions(bondId);
        assertEq(remaining, bondMaturityValue - 1, "remaining bond value");
    }

    /// @dev Contrast: Consensus-closed bonds ARE protected. This test shows
    /// that after holder calls holderWithdrawFromConsensus, the validator
    /// CANNOT drain the execution balance that covers the bond value.
    function test_V1_ConsensusClosedHolderIsProtected() public {
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        uint256 bondId = buyBond(cofferAddr, holder1, 10 ether, ONE_MONTH, 2);
        (uint128 bondMaturityValue,,,) = coffer.sHolderConditions(bondId);

        advanceTime(ONE_MONTH + 1);

        // Holder consensus-closes: totalConsensusReserved increases
        uint256 fee = getWithdrawalFee();
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);

        uint128 totalConsensusReserved = coffer.totalConsensusReserved();
        assertEq(totalConsensusReserved, bondMaturityValue, "consensus reserved = bond value");

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();

        // Fund contract with bondMaturityValue
        vm.deal(cofferAddr, bondMaturityValue);

        // Validator tries to drain — REVERTS because balance(amt) < amt + reserved
        if (issueSize > 0) {
            vm.prank(validator);
            vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
            coffer.validatorWithdrawFromExecution(issueSize);
        }

        // Holder can still withdraw fully
        uint256 holderBalBefore = holder1.balance;
        vm.prank(holder1);
        coffer.holderWithdrawFromExecution(bondId);
        assertEq(holder1.balance - holderBalBefore, bondMaturityValue, "holder fully paid");
    }

    // ========================================
    // V-2: BLIND-C-3 — Compromised key enables compound consensus exit
    //      + execution drain — "multiple rounds" claim verification
    // ========================================

    /// @dev Test V-2 "multiple rounds" claim: each call to
    /// validatorWithdrawFromExecution decreases issueSize by _amount.
    /// A subsequent call with the same _amount reverts because
    /// new issueSize < _amount. The claim of "draining stale issueSize
    /// in multiple rounds" is FALSE — it's a single-round depletion.
    function test_V2_MultipleRoundsClaim_RejectsSubsequentDrain() public {
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        buyBond(cofferAddr, holder1, 10 ether, ONE_MONTH, 2);
        advanceTime(ONE_MONTH + 1);

        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();
        assertGt(issueSizeBefore, 0);

        // Fund contract generously so balance gate passes for first drain
        uint128 contractBal = 100 ether;
        vm.deal(cofferAddr, contractBal);

        // First drain: withdraw 2/3 of issueSize (must be >
        // remainingIssue so second attempt fails)
        uint128 firstDrain = uint128((uint256(issueSizeBefore) * 2) / 3);
        assertLt(firstDrain, issueSizeBefore);

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(firstDrain);

        // issueSize decreased by firstDrain
        (uint128 issueSizeMid,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeMid, issueSizeBefore - firstDrain);
        assertLt(issueSizeMid, firstDrain, "firstDrain > remaining");

        // Second drain: same amount exceeds new issueSize → REVERTS
        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
        coffer.validatorWithdrawFromExecution(firstDrain);

        // Drain remaining issueSize (fits in balance)
        uint128 remainingIssue = issueSizeMid;
        if (remainingIssue > 0) {
            vm.prank(validator);
            coffer.validatorWithdrawFromExecution(remainingIssue);

            (uint128 issueSizeFinal,,,,,,,,,) = coffer.sValidatorConditions();
            assertEq(issueSizeFinal, 0, "issueSize fully drained");

            // Now try to increase issueSize to drain more:
            // _issueSize > 0 and outstandingBonds > 0 → blocked
            vm.prank(validator);
            vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
            coffer.changeIssueSize(10 ether);

            // Even with balance available, withdraw reverts (issueSize=0)
            vm.deal(cofferAddr, 50 ether);
            vm.prank(validator);
            vm.expectRevert(Coffer.ValidatorDoesntCoverTheValue.selector);
            coffer.validatorWithdrawFromExecution(1 ether);
        }

        // Verdict: "multiple rounds" claim is FALSE for outstandingBonds > 0.
        // Each drain decreases issueSize; the monotonicity guard blocks
        // increasing it back. Single-round drain (V-1) is real.
    }

    /// @dev Fuzz variant: explore different drain amounts and contract balances
    /// to confirm no multi-round path exists while outstandingBonds > 0.
    function testFuzz_V2_NoMultiRoundDrain(uint128 drainAmount, uint128 contractBalance) public {
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        buyBond(cofferAddr, holder1, 10 ether, ONE_MONTH, 2);
        advanceTime(ONE_MONTH + 1);

        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();

        // Bound: drainAmount in [1, issueSize], contractBalance in [1, 100 ether]
        drainAmount = uint128(bound(drainAmount, 1, uint256(issueSize)));
        contractBalance = uint128(bound(contractBalance, drainAmount + 1, 100 ether));

        vm.deal(cofferAddr, contractBalance);

        // First drain: succeeds for amount <= issueSize
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(drainAmount);

        // After drain, issueSize decreased
        (uint128 postIssueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(postIssueSize, issueSize - drainAmount, "issueSize decreased correctly");

        // Second drain with same amount: fails if new issueSize < drainAmount
        if (drainAmount > postIssueSize) {
            vm.prank(validator);
            vm.expectRevert();
            coffer.validatorWithdrawFromExecution(drainAmount);
        }
    }
}
