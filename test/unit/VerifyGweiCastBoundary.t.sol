// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "../mock/EIP7002Mock.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Interest} from "../../src/libraries/Interest.sol";

/**
 * @title VerifyGweiCastBoundary
 * @notice Audit-regression guard for finding F-04. The EIP-7002 withdrawal amount is a uint64 gwei value;
 * holderWithdrawFromConsensus casts `ceil(bondMaturityValue / 1e9)` to uint64. A consensus-independent
 * type-limit require in Coffer.sol (`bondMaturityValue <= uint256(type(uint64).max) * GWEI_RATE`) makes the
 * cast provably non-truncating. These tests exercise it at the EXACT uint64 boundary and just above it
 * (using vm.store, since the bound is unreachable via real ETH), and confirm the interest math holds at the
 * uint128 input maximum. Permanent home (test/unit, Verify* convention).
 */
contract VerifyGweiCastBoundary is BaseTest {
    uint256 internal constant GWEI_RATE = 1e9;

    /// @dev exitAllowed=false Coffer (so the gwei-cast branch runs), a matured bond whose bondMaturityValue is
    /// overwritten to `bmv` (preserving duration/startTimestamp/closed), with contract balance 0 so cover-in-place
    /// does not fire and the EIP-7002 path executes.
    function _maturedBondWithValue(uint256 bmv) internal returns (address cofferAddr, uint256 bondId) {
        cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            false, // exitAllowed = false -> gwei conversion path
            defaultStartingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));
        vm.prank(validator);
        c.changeIssueSize(10 ether);
        bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Overwrite ONLY bondMaturityValue (low 128 bits of the packed struct at sHolderConditions slot 4),
        // preserving duration / startTimestamp / consensusWithdrawClosed.
        bytes32 structSlot = keccak256(abi.encode(bondId, uint256(4)));
        uint256 packed = uint256(vm.load(cofferAddr, structSlot));
        uint256 upperBits = packed & (~uint256(0) << 128);
        vm.store(cofferAddr, structSlot, bytes32(upperBits | bmv));

        advanceTime(ONE_MONTH + 1);
        vm.deal(cofferAddr, 0);
    }

    function _queueTail() internal view returns (uint256) {
        return uint256(vm.load(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(3))));
    }

    /// @dev Decode the amount the EIP-7002 mock recorded for queue entry `index` (big-endian uint64 gwei).
    function _recordedGwei(uint256 index) internal view returns (uint64) {
        uint256 entrySlot2 = 4 + index * 3 + 2;
        uint256 slotVal = uint256(vm.load(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(entrySlot2)));
        return uint64((slotVal >> 64) & type(uint64).max);
    }

    /// @notice At the exact uint64 limit the cast is correct (no truncation) and the request succeeds.
    function test_GweiCast_AtUint64Limit_Succeeds_NoTruncation() public {
        uint256 maxBmv = uint256(type(uint64).max) * GWEI_RATE; // largest value the guard permits
        (address cofferAddr, uint256 bondId) = _maturedBondWithValue(maxBmv);
        Coffer c = Coffer(payable(cofferAddr));

        uint256 fee = getWithdrawalFee();
        uint256 tailBefore = _queueTail();
        vm.prank(holder1);
        c.holderWithdrawFromConsensus{value: fee}(bondId);

        assertEq(_queueTail(), tailBefore + 1, "EIP-7002 request enqueued");
        assertEq(
            uint256(_recordedGwei(tailBefore)),
            uint256(type(uint64).max),
            "requested gwei == ceil(bmv/1e9) == uint64 max (no truncation)"
        );
    }

    /// @notice One wei above the limit reverts cleanly (never a silent wrap to 0 / full exit).
    function test_GweiCast_AboveUint64Limit_RevertsCleanly() public {
        uint256 overBmv = uint256(type(uint64).max) * GWEI_RATE + 1;
        (address cofferAddr, uint256 bondId) = _maturedBondWithValue(overBmv);
        Coffer c = Coffer(payable(cofferAddr));

        uint256 fee = getWithdrawalFee();
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSignature("WithdrawalAmountExceedsUint64Gwei()"));
        c.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    /// @notice Interest math does not overflow at the uint128 input maximum (bond amounts are uint128;
    /// 100%/yr over the 50-year max duration = 50x principal, computed in uint256 without reverting).
    function test_Interest_NoOverflow_AtUint128Max() public pure {
        uint256 maxInterest = Interest.calculateInterest(type(uint128).max, 1_576_800_000, 1e8);
        assertGt(maxInterest, 0, "interest computed at max inputs without overflow");
    }
}
