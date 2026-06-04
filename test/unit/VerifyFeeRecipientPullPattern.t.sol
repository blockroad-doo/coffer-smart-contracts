// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

/// @dev A fee recipient that reverts on any ETH transfer.
contract RevertingFeeRecipient {
    receive() external payable {
        revert();
    }
}

/// @dev A normal recipient that accepts ETH.
contract GoodFeeRecipient {
    receive() external payable {}
}

/**
 * @title VerifyFeeRecipientPullPattern
 * @notice Audit-regression guard for finding F-01 (shared-FeeCurve SPOF), now FIXED via pull-based fees.
 *
 * F-01a: a reverting/non-payable feeRecipient must NOT brick buyBond. buyBond deposits the fee via
 *        FeeCurve.collectFee{value: fee}() (revert-free accrual), so issuance is decoupled from the recipient.
 * F-01b: FeeCurve.renounceOwnership() is disabled (reverts), so the recipient is always fixable and accrued
 *        fees are never permanently stranded.
 *
 * Permanent home (test/unit, Verify* convention) so this survives deletion of test/audit-poc/.
 */
contract VerifyFeeRecipientPullPattern is BaseTest {
    address internal protocolAdmin; // FeeCurve owner = CofferFactory deployer = the test contract in BaseTest

    function setUp() public override {
        super.setUp();
        protocolAdmin = address(this);
    }

    function _makeCofferWithIssueSize(bytes32 pk1, bytes16 pk2, uint128 issueSize)
        internal
        returns (address cofferAddr, uint32 version)
    {
        cofferAddr = createCoffer(
            validator,
            pk1,
            pk2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            defaultExitAllowed,
            defaultStartingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));
        vm.prank(validator);
        c.changeIssueSize(issueSize); // version 1 -> 2
        version = 2;
    }

    // F-01a - a reverting feeRecipient does NOT brick buyBond (fees pool in FeeCurve)
    function test_BuyBond_NotBrickedByRevertingFeeRecipient() public {
        assertEq(feeCurve.owner(), protocolAdmin, "FeeCurve owner is the factory deployer");
        (uint256 feeBps,) = feeCurve.getFee();
        assertEq(feeBps, 100, "day-0 fee is 100 bps so fee > 0 for any real bond");

        (address cofferA, uint32 vA) = _makeCofferWithIssueSize(bytes32(uint256(1)), bytes16(uint128(2)), 100 ether);
        (address cofferB, uint32 vB) = _makeCofferWithIssueSize(bytes32(uint256(3)), bytes16(uint128(4)), 100 ether);

        // Admin points the SHARED FeeCurve at a reverting recipient.
        RevertingFeeRecipient bad = new RevertingFeeRecipient();
        vm.prank(protocolAdmin);
        feeCurve.setFeeRecipient(address(bad));

        uint256 accruedBefore = feeCurve.sAccruedFees();

        // buyBond SUCCEEDS on both independent clones despite the reverting recipient.
        vm.prank(holder1);
        Coffer(payable(cofferA)).buyBond{value: 10 ether}(ONE_YEAR, vA);
        vm.prank(holder2);
        Coffer(payable(cofferB)).buyBond{value: 10 ether}(ONE_YEAR, vB);

        assertGt(feeCurve.sAccruedFees(), accruedBefore, "fees accrued in FeeCurve (not lost, not bricked)");

        // claim() to the bad recipient reverts -> blocks only the payout, NOT issuance.
        vm.expectRevert();
        feeCurve.claim();
        vm.prank(holder3);
        Coffer(payable(cofferA)).buyBond{value: 10 ether}(ONE_YEAR, vA);

        // Admin fixes the recipient; claim() pays the full accrued pool.
        GoodFeeRecipient good = new GoodFeeRecipient();
        vm.prank(protocolAdmin);
        feeCurve.setFeeRecipient(address(good));
        uint256 pool = feeCurve.sAccruedFees();
        assertGt(pool, 0, "fees preserved through the incident");
        feeCurve.claim();
        assertEq(address(good).balance, pool, "recipient paid full accrued pool after fix");
        assertEq(feeCurve.sAccruedFees(), 0, "accrued pool zeroed after claim");
    }

    // F-01b - FeeCurve.renounceOwnership is disabled; recipient always fixable
    function test_FeeCurveRenounceDisabled_RecipientAlwaysFixable() public {
        vm.prank(protocolAdmin);
        vm.expectRevert(abi.encodeWithSignature("RenounceDisabled()"));
        feeCurve.renounceOwnership();
        assertEq(feeCurve.owner(), protocolAdmin, "owner retained -> recipient always fixable");

        RevertingFeeRecipient bad = new RevertingFeeRecipient();
        vm.prank(protocolAdmin);
        feeCurve.setFeeRecipient(address(bad));

        (address cofferA, uint32 vA) = _makeCofferWithIssueSize(bytes32(uint256(11)), bytes16(uint128(12)), 100 ether);
        vm.prank(holder1);
        Coffer(payable(cofferA)).buyBond{value: 10 ether}(ONE_YEAR, vA); // succeeds; fee pooled

        GoodFeeRecipient good = new GoodFeeRecipient();
        vm.prank(protocolAdmin);
        feeCurve.setFeeRecipient(address(good));
        uint256 pool = feeCurve.sAccruedFees();
        assertGt(pool, 0);
        feeCurve.claim();
        assertEq(address(good).balance, pool, "fees recovered after fixing the recipient");
    }
}
