// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/**
 * @title VerifyMulticallNonPayable
 * @notice Audit-regression guard for the msg.value-reuse class (registry 2020-08-Opyn / 2021-09-Sushimiso),
 * REFUTED for Coffer as deployed, plus the batching-equivalence counter-checks that back the refutation.
 *
 * Coffer inherits OpenZeppelin `Multicall` (src/Coffer.sol:5,24) and declares no other batching entry point.
 * OZ v5.6.1 `Multicall.multicall` (lib/openzeppelin-contracts/contracts/utils/Multicall.sol:26) is
 * `public virtual` WITHOUT `payable`, so the Solidity dispatcher rejects every value-bearing call before a
 * single subcall runs, and the only reachable batch gives each subcall msg.value == 0. The pre-existing
 * coffer float can therefore never be observed as msg.value. That refutation rests entirely on a dependency
 * detail: an OpenZeppelin bump that makes `multicall` payable revives the whole attack class. These tests
 * are the tripwire for exactly that regression; a new payable batching entry point added under a different
 * name cannot be caught here and must be caught in review.
 *
 * Coverage:
 *  - Leg A1: a value-bearing `multicall` dies at the non-payable dispatcher with empty revert data, while
 *    the IDENTICAL byte stream at value 0 gets through the dispatcher and is rejected inside `buyBond` by
 *    its `minimumValueToAccept` gate. The second call is the positive control: it proves the hand-encoded
 *    calldata is a well-formed `multicall(bytes[])` encoding whose subcalls really dispatch to `buyBond`, so
 *    the value-bearing failure is provably about msg.value rather than about malformed calldata.
 *  - Leg A3: batched `redeemBondsEarly` is never looser than the same calls made sequentially, because the
 *    per-subcall gate `balance >= totalValue + totalConsensusReserved` (src/Coffer.sol:488) is re-evaluated
 *    against post-state on every subcall. Covered BOTH with a zero reserve and with a non-zero reserve
 *    produced by the cover-in-place branch of `holderWithdrawFromConsensus` (src/Coffer.sol:739). The
 *    non-zero case matters: no other deterministic test reaches that gate with a surviving reserve — every
 *    other redeemBondsEarly unit test either never closes a bond or redeems the closed bond itself, which
 *    decrements the reserve to 0 in the loop at src/Coffer.sol:464-466 before the gate is read. (The
 *    invariant handlers under test/invariant/ can reach it with a non-zero reserve, but only
 *    fuzz-dependently, and they are excluded from the default profile.)
 *
 * The PoC also validated the attack's value-reuse economics on a throwaway Coffer subclass that added a
 * payable batcher. That harness is intentionally NOT carried over: it proved a property of code Coffer
 * does not contain. The durable invariant this file pins is that `multicall(bytes[])` stays non-payable;
 * keeping Coffer free of any other payable batching entry point is a review-time invariant no runtime test
 * can enumerate.
 *
 * Permanent home (test/unit, Verify* convention) so this survives deletion of test/audit-poc/.
 */
contract VerifyMulticallNonPayable is BaseTest {
    address public attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 100 ether);
    }

    // ───────────────────────── helpers ─────────────────────────

    /// @dev `n` identical zero-value `buyBond(duration, version)` payloads for a multicall batch.
    function _buyBondPayloads(uint32 duration, uint32 version, uint256 n) internal pure returns (bytes[] memory data) {
        data = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = abi.encodeWithSelector(Coffer.buyBond.selector, duration, version);
        }
    }

    /// @dev The two ValidatorConditions fields these tests care about, without the 10-tuple noise.
    function _issueSize(address c) internal view returns (uint128 issueSize, uint32 outstandingBonds) {
        (issueSize,,,,,, outstandingBonds,,,) = Coffer(payable(c)).sValidatorConditions();
    }

    /// @dev Single-element bondId array for redeemBondsEarly.
    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// @dev Two-subcall batch: [redeemBondsEarly(first), redeemBondsEarly(second)].
    function _redeemBatch(uint256 first, uint256 second) internal pure returns (bytes[] memory batch) {
        batch = new bytes[](2);
        batch[0] = abi.encodeWithSelector(Coffer.redeemBondsEarly.selector, _ids(first));
        batch[1] = abi.encodeWithSelector(Coffer.redeemBondsEarly.selector, _ids(second));
    }

    /// @dev Fresh default coffer with two honest bonds (holder1: 5 ETH, holder2: 6 ETH) and a
    ///      validator top-up via receive(). `fullTopUp` covers both bonds; otherwise only bmv1.
    ///      `pkNonce` varies the BLS pubkey (and thus the CREATE2 salt) so multiple coffers can
    ///      coexist in one test for the same validator.
    function _setupTwoBonds(uint256 pkNonce, bool fullTopUp)
        internal
        returns (address c, uint256 id1, uint256 id2, uint256 bmv1, uint256 bmv2)
    {
        c = createCoffer(
            validator,
            bytes32(pkNonce),
            // forge-lint: disable-next-line(unsafe-typecast) test nonce literal fits in uint128
            bytes16(uint128(pkNonce)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            defaultExitAllowed,
            defaultStartingBalance
        );
        vm.prank(holder1);
        id1 = Coffer(payable(c)).buyBond{value: 5 ether}(ONE_MONTH, 1);
        vm.prank(holder2);
        id2 = Coffer(payable(c)).buyBond{value: 6 ether}(ONE_MONTH, 1);
        (uint128 a1,,,) = Coffer(payable(c)).sHolderConditions(id1);
        (uint128 a2,,,) = Coffer(payable(c)).sHolderConditions(id2);
        bmv1 = a1;
        bmv2 = a2;
        vm.prank(validator);
        (bool ok,) = c.call{value: fullTopUp ? bmv1 + bmv2 : bmv1}("");
        require(ok, "top-up");
    }

    /// @dev Close `bondId` through the cover-in-place branch of holderWithdrawFromConsensus
    ///      (src/Coffer.sol:739): with msg.value == 0 and balance >= bondMaturityValue + reserve it flips
    ///      consensusWithdrawClosed and adds bondMaturityValue to totalConsensusReserved WITHOUT enqueuing
    ///      an EIP-7002 request, WITHOUT paying a fee and WITHOUT deleting the bond, so the bond stays
    ///      redeemable via redeemBondsEarly. Setup pattern borrowed from
    ///      test/unit/VerifyConsensusReserveCrossDrain.t.sol:73-80. The branch returns before the
    ///      `exitAllowed` read at src/Coffer.sol:749, so it works unchanged on the exitAllowed == false
    ///      coffers _setupTwoBonds creates. The bond must already have matured.
    function _coverInPlace(address c, address holder, uint256 bondId, uint256 expectedBmv) internal {
        Coffer cf = Coffer(payable(c));
        uint256 reservedBefore = cf.totalConsensusReserved();
        uint256 balanceBefore = c.balance;
        (,,, uint256 tailBefore) = getQueueState();

        vm.prank(holder);
        cf.holderWithdrawFromConsensus{value: 0}(bondId);

        (uint128 bmv,,, bool closed) = cf.sHolderConditions(bondId);
        assertTrue(closed, "bond closed via cover-in-place");
        assertEq(uint256(bmv), expectedBmv, "bondMaturityValue survives the close (still redeemable)");
        assertEq(c.balance, balanceBefore, "cover-in-place moves no ETH and pays no EIP-7002 fee");
        assertEq(cf.totalConsensusReserved(), reservedBefore + expectedBmv, "reserve grew by bondMaturityValue");
        (,,, uint256 tailAfter) = getQueueState();
        assertEq(tailAfter, tailBefore, "no EIP-7002 request enqueued (cover-in-place, not the exit path)");
    }

    // ════════════════════════════════════════════════════════════
    // LEG A1 — value cannot enter the batch
    // ════════════════════════════════════════════════════════════

    /// @notice REFUTATION (real Coffer): a value-bearing `multicall` reverts at the Solidity
    ///         dispatcher because OZ 5.6.1 multicall is non-payable — even with float >= W sitting in the
    ///         contract, the described attack cannot deliver value into the batch. The zero-value replay of
    ///         the SAME byte stream is the positive control: it clears the dispatcher and dies inside
    ///         buyBond on minimumValueToAccept, so the value-bearing revert is provably about msg.value and
    ///         not about a malformed encoding or a wrong selector (either of which would also revert here).
    function test_Multicall_ValueBearingBatch_RevertsAtNonPayableDispatcher() public {
        address c = createDefaultCoffer();
        uint256 B0 = 10 ether; // simulated EIP-4895 float: balance credited, issueSize untouched
        uint256 W = 10 ether;
        vm.deal(c, B0);

        bytes[] memory data = _buyBondPayloads(ONE_MONTH, 1, 2);
        bytes memory callData = abi.encodeWithSelector(Multicall.multicall.selector, data);

        (uint128 issueSizeBefore,) = _issueSize(c);
        uint256 ownerBefore = validator.balance;

        // Low-level call required: `coffer.multicall{value: W}(...)` does not even COMPILE
        // for a non-payable function. This is the exact byte stream an attacker would send.
        vm.prank(attacker);
        (bool ok, bytes memory ret) = c.call{value: W}(callData);

        assertFalse(ok, "value-bearing multicall must revert");
        assertEq(ret.length, 0, "bare non-payable dispatcher revert, no reason string");

        // POSITIVE CONTROL: the identical bytes at value 0 pass the dispatcher and reach buyBond, whose
        // first failing guard is `msg.value >= minimumValueToAccept` (src/Coffer.sol:373; 0 < 1 ether).
        // Address.functionDelegateCall bubbles that custom error verbatim via LowLevelCall.bubbleRevert
        // (Errors.FailedCall is used only when returndata is empty), so non-empty ValueTooSmallToAccept
        // data here proves `callData` is a well-formed multicall(bytes[]) whose subcalls hit buyBond.
        vm.prank(attacker);
        (bool okZero, bytes memory retZero) = c.call{value: 0}(callData);

        assertFalse(okZero, "zero-value batch also reverts, but from inside buyBond");
        assertEq(
            retZero,
            abi.encodeWithSelector(Coffer.ValueTooSmallToAccept.selector),
            "zero-value batch reached buyBond: byte stream is valid, only msg.value differed"
        );

        // Nothing moved on either call: no bonds, no ETH flows, no state drift.
        assertEq(bondNft.balanceOf(attacker), 0, "no bond NFTs minted");
        (uint128 issueSizeAfter, uint32 outstandingAfter) = _issueSize(c);
        assertEq(issueSizeAfter, issueSizeBefore, "issueSize unchanged");
        assertEq(outstandingAfter, 0, "outstandingBonds unchanged");
        assertEq(c.balance, B0, "coffer balance unchanged");
        assertEq(validator.balance, ownerBefore, "owner balance unchanged");
        assertEq(attacker.balance, 100 ether, "attacker balance unchanged (value returned)");
    }

    /// @notice REFUTATION (real Coffer): in a zero-value batch every subcall observes
    ///         msg.value == 0 — the coffer float is NOT visible as msg.value. buyBond's
    ///         minimumValueToAccept gate (1 ether) rejects it. Solidity-typed twin of the hand-encoded
    ///         control above; together they show the two call paths agree.
    function test_Multicall_ZeroValueBatch_SubcallsSeeZeroMsgValue() public {
        address c = createDefaultCoffer();
        vm.deal(c, 10 ether); // float present, still unusable

        bytes[] memory data = _buyBondPayloads(ONE_MONTH, 1, 2);
        vm.prank(attacker);
        vm.expectRevert(Coffer.ValueTooSmallToAccept.selector);
        Coffer(payable(c)).multicall(data);
    }

    // ════════════════════════════════════════════════════════════
    // LEG A3 — batched redeemBondsEarly is never looser than sequential
    // ════════════════════════════════════════════════════════════

    /// @notice CONFIRMED (real Coffer): a zero-value batch of two redeemBondsEarly behaves
    ///         IDENTICALLY to two sequential calls — the per-subcall balance gate
    ///         (`balance >= totalValue + totalConsensusReserved`) is re-evaluated post-state
    ///         each time, so batching extracts no extra value. (Note: attaching the shortfall
    ///         as batch msg.value is impossible — multicall is non-payable — so the only
    ///         reachable batch is the zero-value one; the coffer is topped up via receive().)
    ///         Scope: totalConsensusReserved is 0 throughout, so this pins only the totalValue half of
    ///         the gate; the reserve half is covered by the two NonZeroReserve tests below.
    function test_BatchedRedeemBondsEarly_ZeroReserve_MatchesSequential() public {
        // Branch 1 (fresh coffer #1): one zero-value multicall batching both redeems.
        uint256 rBal;
        uint256 rClaim1;
        uint256 rClaim2;
        uint256 rEscrowDelta;
        uint32 rOutstanding;
        {
            (address c, uint256 id1, uint256 id2, uint256 bmv1, uint256 bmv2) = _setupTwoBonds(101, true);
            uint256 preEscrow = address(bondsRedeemedEarly).balance;
            bytes[] memory batch = _redeemBatch(id1, id2);
            vm.prank(validator);
            Coffer(payable(c)).multicall(batch);
            rBal = c.balance;
            rClaim1 = bondsRedeemedEarly.sPendingClaims(holder1);
            rClaim2 = bondsRedeemedEarly.sPendingClaims(holder2);
            rEscrowDelta = address(bondsRedeemedEarly).balance - preEscrow;
            (, rOutstanding) = _issueSize(c);
            // Absolute expectations for the shared end state:
            assertEq(rClaim1, bmv1, "holder1 claim == bmv1");
            assertEq(rClaim2, bmv2, "holder2 claim == bmv2");
            assertEq(rBal, 0, "coffer fully paid out");
            assertEq(rOutstanding, 0, "no bonds left");
        }

        // Branch 2 (fresh coffer #2, identical setup): two sequential calls.
        {
            (address c, uint256 id1, uint256 id2,,) = _setupTwoBonds(202, true);
            uint256 preClaim1 = bondsRedeemedEarly.sPendingClaims(holder1);
            uint256 preClaim2 = bondsRedeemedEarly.sPendingClaims(holder2);
            uint256 preEscrow = address(bondsRedeemedEarly).balance;
            vm.prank(validator);
            Coffer(payable(c)).redeemBondsEarly(_ids(id1));
            vm.prank(validator);
            Coffer(payable(c)).redeemBondsEarly(_ids(id2));

            assertEq(c.balance, rBal, "same coffer balance as batch");
            assertEq(bondsRedeemedEarly.sPendingClaims(holder1) - preClaim1, rClaim1, "same claim holder1");
            assertEq(bondsRedeemedEarly.sPendingClaims(holder2) - preClaim2, rClaim2, "same claim holder2");
            assertEq(address(bondsRedeemedEarly).balance - preEscrow, rEscrowDelta, "same escrow inflow");
            (, uint32 seqOutstanding) = _issueSize(c);
            assertEq(seqOutstanding, rOutstanding, "same outstandingBonds");
        }
    }

    /// @notice CONFIRMED (real Coffer): an underfunded batch reverts ATOMICALLY at the second
    ///         subcall's balance gate — nothing is deposited. Sequentially, the first call
    ///         succeeds and only the second reverts. The batch is therefore strictly
    ///         all-or-nothing, never looser than sequential: no extra value extractable.
    ///         Scope: as above, totalConsensusReserved is 0 here.
    function test_BatchedRedeemBondsEarly_ZeroReserve_Underfunded_RevertsAtomically() public {
        (address c, uint256 id1, uint256 id2, uint256 bmv1,) = _setupTwoBonds(303, false);

        bytes[] memory batch = _redeemBatch(id1, id2);

        vm.prank(validator);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        Coffer(payable(c)).multicall(batch);

        // Atomicity: first subcall's deposit was rolled back too.
        assertEq(bondsRedeemedEarly.sPendingClaims(holder1), 0, "no partial deposit");
        assertEq(bondsRedeemedEarly.sPendingClaims(holder2), 0, "no partial deposit");
        assertEq(address(bondsRedeemedEarly).balance, 0, "escrow untouched");
        assertEq(c.balance, bmv1, "coffer untouched");
        (, uint32 outstanding) = _issueSize(c);
        assertEq(outstanding, 2, "both bonds still open");

        // Contrast: sequentially, the first call DOES succeed (batch is stricter, never looser).
        vm.prank(validator);
        Coffer(payable(c)).redeemBondsEarly(_ids(id1));
        assertEq(bondsRedeemedEarly.sPendingClaims(holder1), bmv1, "sequential first call succeeds");
    }

    /// @notice CONFIRMED (real Coffer): the equivalence still holds when totalConsensusReserved is NON-ZERO
    ///         at the gate. Bond A is closed via cover-in-place (src/Coffer.sol:739), which reserves bmvA
    ///         without moving ETH. The batch then redeems B BEFORE A, so subcall 1's gate is
    ///         balance(bmvA + bmvB) >= totalValue(bmvB) + totalConsensusReserved(bmvA) — exact equality,
    ///         i.e. the boundary, and the only deterministic test in this repo where that gate sees a
    ///         non-zero reserve.
    ///         Redeeming A first would decrement the reserve to 0 in the loop at src/Coffer.sol:464-466
    ///         before the gate is read, leaving the reserve half unexercised — the blind spot in the two
    ///         zero-reserve tests above.
    function test_BatchedRedeemBondsEarly_NonZeroReserve_AtBoundary_MatchesSequential() public {
        // Both coffers are created in the SAME block so the FeeCurve day, and therefore every
        // bondMaturityValue, is identical; only afterwards is time advanced, maturing all four bonds.
        (address cBatch, uint256 batchIdA, uint256 batchIdB, uint256 bmvA, uint256 bmvB) = _setupTwoBonds(404, true);
        (address cSeq, uint256 seqIdA, uint256 seqIdB, uint256 seqBmvA, uint256 seqBmvB) = _setupTwoBonds(505, true);
        advanceTime(ONE_MONTH + 1);

        _coverInPlace(cBatch, holder1, batchIdA, bmvA);
        _coverInPlace(cSeq, holder1, seqIdA, seqBmvA);
        assertEq(cBatch.balance, bmvA + bmvB, "batch coffer sits exactly on the gate boundary");
        assertEq(cSeq.balance, seqBmvA + seqBmvB, "sequential coffer sits exactly on its own gate boundary");

        // Branch 1: one zero-value multicall, B BEFORE A (see the note above on why order matters).
        uint256 preClaim1 = bondsRedeemedEarly.sPendingClaims(holder1);
        uint256 preClaim2 = bondsRedeemedEarly.sPendingClaims(holder2);
        uint256 preEscrow = address(bondsRedeemedEarly).balance;
        {
            bytes[] memory batch = _redeemBatch(batchIdB, batchIdA);
            vm.prank(validator);
            Coffer(payable(cBatch)).multicall(batch);
        }
        assertEq(
            bondsRedeemedEarly.sPendingClaims(holder1) - preClaim1, bmvA, "batch: cover-in-place holder credited bmvA"
        );
        assertEq(bondsRedeemedEarly.sPendingClaims(holder2) - preClaim2, bmvB, "batch: holder2 credited bmvB");
        assertEq(address(bondsRedeemedEarly).balance - preEscrow, bmvA + bmvB, "batch: escrow received bmvA + bmvB");
        assertEq(cBatch.balance, 0, "batch: coffer fully paid out at the boundary");
        assertEq(Coffer(payable(cBatch)).totalConsensusReserved(), 0, "batch: reserve released by A's redemption");
        (, uint32 batchOutstanding) = _issueSize(cBatch);
        assertEq(batchOutstanding, 0, "batch: no bonds left");

        // Branch 2: the same two calls in the same order, made sequentially on the twin coffer.
        preClaim1 = bondsRedeemedEarly.sPendingClaims(holder1);
        preClaim2 = bondsRedeemedEarly.sPendingClaims(holder2);
        preEscrow = address(bondsRedeemedEarly).balance;
        vm.prank(validator);
        Coffer(payable(cSeq)).redeemBondsEarly(_ids(seqIdB));
        vm.prank(validator);
        Coffer(payable(cSeq)).redeemBondsEarly(_ids(seqIdA));

        // Identical outcome: the escrow deltas match and the two coffers agree on final state.
        assertEq(
            bondsRedeemedEarly.sPendingClaims(holder1) - preClaim1, seqBmvA, "sequential credited holder1 identically"
        );
        assertEq(
            bondsRedeemedEarly.sPendingClaims(holder2) - preClaim2, seqBmvB, "sequential credited holder2 identically"
        );
        assertEq(
            address(bondsRedeemedEarly).balance - preEscrow, seqBmvA + seqBmvB, "sequential moved identical escrow"
        );
        assertEq(cSeq.balance, cBatch.balance, "sequential leaves the identical coffer balance");
        assertEq(Coffer(payable(cSeq)).totalConsensusReserved(), 0, "sequential leaves the identical reserve");
        (, uint32 seqOutstanding) = _issueSize(cSeq);
        assertEq(seqOutstanding, batchOutstanding, "sequential leaves the identical outstandingBonds");
    }

    /// @notice CONFIRMED (real Coffer): the reserve half of the redeemBondsEarly gate is load-bearing. One
    ///         wei below the boundary the batch reverts atomically and the same single redeem of B reverts
    ///         on its own, while a twin coffer holding the IDENTICAL balance and IDENTICAL bond values —
    ///         differing only in that no bond was consensus-closed, so totalConsensusReserved == 0 —
    ///         redeems B successfully. Cover-in-place holder A is therefore protected rather than stranded:
    ///         their reserved ETH is not spendable on B's early redemption, and they still withdraw bmvA in
    ///         full afterwards.
    function test_BatchedRedeemBondsEarly_NonZeroReserve_OneWeiShort_RevertsAndProtectsHolder() public {
        // Same-block creation keeps both coffers' bondMaturityValues identical (see the test above).
        (address c, uint256 idA, uint256 idB, uint256 bmvA, uint256 bmvB) = _setupTwoBonds(606, true);
        (address ctl,, uint256 ctlIdB,,) = _setupTwoBonds(707, true);
        advanceTime(ONE_MONTH + 1);

        _coverInPlace(c, holder1, idA, bmvA);

        // One wei below the boundary. vm.deal credits balance without running receive(), i.e. exactly how
        // an EIP-4895 beacon withdrawal lands (same technique as VerifyConsensusReserveCrossDrain.t.sol:69).
        vm.deal(c, bmvA + bmvB - 1);
        vm.deal(ctl, bmvA + bmvB - 1);

        bytes[] memory batch = _redeemBatch(idB, idA);
        vm.prank(validator);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        Coffer(payable(c)).multicall(batch);

        // Not a batching artifact: subcall 1 in isolation fails the same gate, because
        // balance(bmvA + bmvB - 1) >= totalValue(bmvB) + totalConsensusReserved(bmvA) is false by 1 wei.
        vm.prank(validator);
        vm.expectRevert(Coffer.ContractBalanceLessThanValue.selector);
        Coffer(payable(c)).redeemBondsEarly(_ids(idB));

        // Atomic: no escrow deposit, no state drift, reserve intact.
        assertEq(bondsRedeemedEarly.sPendingClaims(holder1), 0, "no partial deposit for A");
        assertEq(bondsRedeemedEarly.sPendingClaims(holder2), 0, "no partial deposit for B");
        assertEq(address(bondsRedeemedEarly).balance, 0, "escrow untouched");
        assertEq(c.balance, bmvA + bmvB - 1, "coffer untouched");
        assertEq(Coffer(payable(c)).totalConsensusReserved(), bmvA, "reserve intact after the revert");
        (, uint32 outstanding) = _issueSize(c);
        assertEq(outstanding, 2, "both bonds still open");

        // CONTROL: same bond value, same balance, but reserve == 0 -> the same redeem SUCCEEDS. The only
        // differing state between the two coffers is the cover-in-place close, so the 1-wei shortfall
        // above is attributable to totalConsensusReserved and to nothing else.
        (uint128 ctlBmvB,,,) = Coffer(payable(ctl)).sHolderConditions(ctlIdB);
        assertEq(uint256(ctlBmvB), bmvB, "control bond B carries the same bondMaturityValue");
        assertEq(Coffer(payable(ctl)).totalConsensusReserved(), 0, "control has no consensus reserve");
        vm.prank(validator);
        Coffer(payable(ctl)).redeemBondsEarly(_ids(ctlIdB));
        assertEq(bondsRedeemedEarly.sPendingClaims(holder2), bmvB, "control: B redeemed at the same balance");

        // Holder A is protected, not stranded: the reserved ETH is still claimable in full.
        uint256 holderABefore = holder1.balance;
        vm.prank(holder1);
        Coffer(payable(c)).holderWithdrawFromExecution(idA);
        assertEq(holder1.balance - holderABefore, bmvA, "cover-in-place holder A paid bmvA in full");
        assertEq(Coffer(payable(c)).totalConsensusReserved(), 0, "A's reserve released on withdrawal");
    }
}
