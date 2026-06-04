// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title VerifyConsensusReserveCrossDrain
 * @notice Audit-regression guard for finding F-02 (documented in-scope FCFS reordering of consensus reserves).
 *
 * A consensus-closed bond's execution withdrawal uses `reserved = 0` (Coffer.sol:653), so an in-transit
 * (EIP-7002) bond B can claim a cover-in-place bond A's PRESENT ETH first. This is first-come-first-served
 * reordering, NOT theft: B's own beacon ETH then backs the remainder, so the corrected solvency property
 *
 *     contractBalance + inTransitBeaconETH >= Σ bondMaturityValue(closed bonds)
 *
 * holds throughout, and A is made whole once B's beacon ETH lands. (The retired invariant asserted the
 * stronger, reachably-false `balance >= sumLocked`; see invariant_reserveBackedByBalanceOrInTransit.)
 *
 * Permanent home (test/unit, Verify* convention) so this survives deletion of test/audit-poc/.
 */
contract VerifyConsensusReserveCrossDrain is BaseTest {
    address public cofferAddr;
    Coffer public c;

    function setUp() public override {
        super.setUp();
        // exitAllowed = true so holderWithdrawFromConsensus takes the full-exit EIP-7002 path
        // (valueToWithdrawInGwei = 0) rather than the gwei partial path.
        cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            true, // exitAllowed
            defaultStartingBalance
        );
        c = Coffer(payable(cofferAddr));
    }

    /// @dev Σ bondMaturityValue over closed bonds (the corrected invariant's left-hand reserve term).
    function _sumLockedClosed(uint256 bondId) internal view returns (uint256) {
        (uint128 amount,,, bool closed) = c.sHolderConditions(bondId);
        return closed ? uint256(amount) : 0;
    }

    function test_ConsensusReserveCrossDrain_FCFS_SolvencyPreservedByInTransit() public {
        // ── Setup: enable bonding, two equal bonds A and B ───────────────────
        vm.prank(validator);
        c.changeIssueSize(10 ether); // version 1 -> 2
        uint32 version = 2;

        uint256 bondA = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);
        uint256 bondB = buyBond(cofferAddr, holder2, 1 ether, ONE_MONTH, version);

        (uint128 vA,,,) = c.sHolderConditions(bondA);
        (uint128 vB,,,) = c.sHolderConditions(bondB);
        assertEq(vA, vB, "bonds A and B must have equal maturity value");
        assertGt(vA, 0, "bond value must be > 0");

        advanceTime(ONE_MONTH + 1); // maturity

        // Fund the contract to EXACTLY bond A's maturity value (buyBond forwarded msg.value to the validator).
        vm.deal(cofferAddr, vA);
        assertEq(c.totalConsensusReserved(), 0, "reserved starts at 0");

        // ── Step 1: Holder A cover-in-place (msg.value = 0) ──────────────────
        uint256 queueTailBeforeA = _queueTail();
        vm.prank(holder1);
        c.holderWithdrawFromConsensus{value: 0}(bondA);
        (,,, bool aClosed) = c.sHolderConditions(bondA);
        assertTrue(aClosed, "A closed via cover-in-place");
        assertEq(c.totalConsensusReserved(), vA, "reserved == vA after cover-in-place");
        assertEq(cofferAddr.balance, vA, "A's ETH physically present");
        assertEq(_queueTail(), queueTailBeforeA, "no EIP-7002 request enqueued for A");

        // ── Step 2: Holder B EIP-7002 full-exit path ────────────────────────
        uint256 wfee = getWithdrawalFee(); // read before prank (staticcall would consume the prank)
        uint256 tailBeforeB = _queueTail();
        vm.prank(holder2);
        c.holderWithdrawFromConsensus{value: wfee}(bondB);
        (,,, bool bClosed) = c.sHolderConditions(bondB);
        assertTrue(bClosed, "B closed via EIP-7002");
        assertEq(c.totalConsensusReserved(), uint256(vA) + uint256(vB), "reserved == vA + vB");
        assertEq(_queueTail(), tailBeforeB + 1, "B enqueued an EIP-7002 request (vB in transit)");
        assertEq(cofferAddr.balance, vA, "balance back to vA after B's fee leaves");

        // ── Step 3: B drains via execution (reserved treated as 0 for a closed bond) ──
        _expectDrain(bondB, holder2, vB);

        // ── The FCFS drain occurred: B took A's present ETH ──────────────────
        assertLe(cofferAddr.balance, 1, "contract balance now ~0 (B took A's present ETH)");
        (uint128 aValueAfter,,, bool aStillClosed) = c.sHolderConditions(bondA);
        assertTrue(aStillClosed, "A still closed");
        assertEq(aValueAfter, vA, "A bondMaturityValue still == vA");
        assertLt(cofferAddr.balance, vA, "transiently: balance < A's reserve (A awaits B's beacon ETH)");
        assertEq(c.totalConsensusReserved(), vA, "reserved == vA (A's portion remains)");

        // ── CORRECTED solvency property holds: balance + inTransit(vB) >= reserved(A) ──
        // vB is bond B's in-transit beacon ETH (the full-exit request enqueued in Step 2). This is exactly
        // what invariant_reserveBackedByBalanceOrInTransit asserts; the OLD `balance >= sumLocked` would fail here.
        assertGe(cofferAddr.balance + uint256(vB), _sumLockedClosed(bondA), "balance + inTransit covers A's reserve");

        // ── RECOVERY: B's full-exit beacon ETH arrives (+vB); A withdraws; reserve drains to 0 ──
        vm.deal(cofferAddr, cofferAddr.balance + vB);
        _expectDrain(bondA, holder1, vA);
        assertEq(c.totalConsensusReserved(), 0, "reserve drains to 0 -> temporary FCFS, not permanent theft");
    }

    /// @dev EIP-7002 mock queue tail from canonical predeploy storage (slot 3).
    function _queueTail() internal view returns (uint256 tail) {
        tail = uint256(vm.load(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(3))));
    }

    /// @dev Holder withdraws bond via execution; assert they received exactly `expected`.
    function _expectDrain(uint256 bondId, address holder, uint128 expected) internal {
        uint256 balBefore = holder.balance;
        vm.prank(holder);
        c.holderWithdrawFromExecution(bondId);
        assertEq(holder.balance - balBefore, expected, "holder received exactly the bond maturity value");
    }
}
