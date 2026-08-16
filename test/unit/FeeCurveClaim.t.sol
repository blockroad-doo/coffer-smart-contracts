//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";

/// @dev Unit tests for the pull-based protocol-fee mechanism
/// (collectFee / claim / renounceOwnership override).
contract _GoodRecipient {
    receive() external payable {}
}

contract _BadRecipient {
    receive() external payable {
        revert();
    }
}

contract _ReentrantRecipient {
    FeeCurve internal immutable FC;
    bool internal armed;

    constructor(FeeCurve _fc) {
        FC = _fc;
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            // Re-enter during payout; CEI must make this nested claim see 0 accrued.
            try FC.claim() {} catch {}
        }
    }
}

contract FeeCurveClaimTest is Test {
    FeeCurve internal fc;
    _GoodRecipient internal good;

    function setUp() public {
        good = new _GoodRecipient();
        fc = new FeeCurve(address(this), address(good)); // owner = this, recipient = good
    }

    function test_CollectFee_AccruesAndAccumulates() public {
        fc.collectFee{value: 1 ether}();
        assertEq(fc.sAccruedFees(), 1 ether);
        assertEq(address(fc).balance, 1 ether);

        fc.collectFee{value: 0.5 ether}();
        assertEq(fc.sAccruedFees(), 1.5 ether);
    }

    function test_CollectFee_ZeroValue_DoesNotRevert() public {
        fc.collectFee{value: 0}();
        assertEq(fc.sAccruedFees(), 0);
    }

    function test_Claim_PaysRecipientAndZeroes() public {
        fc.collectFee{value: 2 ether}();
        uint256 balBefore = address(good).balance;
        fc.claim();
        assertEq(address(good).balance, balBefore + 2 ether);
        assertEq(fc.sAccruedFees(), 0);
    }

    function test_Claim_RevertsWhenNothingAccrued() public {
        vm.expectRevert(abi.encodeWithSignature("NoFeesToClaim()"));
        fc.claim();
    }

    function test_Claim_IsPermissionless() public {
        fc.collectFee{value: 1 ether}();
        uint256 balBefore = address(good).balance;
        vm.prank(address(0xCAFE)); // arbitrary non-owner caller
        fc.claim();
        assertEq(address(good).balance, balBefore + 1 ether);
    }

    function test_Claim_BadRecipient_RevertsButPreservesAccrual_ThenRecoverable() public {
        _BadRecipient bad = new _BadRecipient();
        fc.setFeeRecipient(address(bad));
        fc.collectFee{value: 1 ether}();

        vm.expectRevert();
        fc.claim(); // payout to a reverting recipient fails...
        assertEq(fc.sAccruedFees(), 1 ether, "accrual preserved after a failed claim");

        fc.setFeeRecipient(address(good)); // ...but the admin can fix the recipient
        uint256 balBefore = address(good).balance;
        fc.claim();
        assertEq(address(good).balance, balBefore + 1 ether);
        assertEq(fc.sAccruedFees(), 0);
    }

    function test_RenounceOwnership_Disabled() public {
        vm.expectRevert(abi.encodeWithSignature("RenounceDisabled()"));
        fc.renounceOwnership();
        assertEq(fc.owner(), address(this), "owner retained");
    }

    function test_Claim_ReentrancySafe_NoDoubleClaim() public {
        _ReentrantRecipient r = new _ReentrantRecipient(fc);
        fc.setFeeRecipient(address(r));
        fc.collectFee{value: 3 ether}();
        r.arm();
        fc.claim();
        assertEq(address(r).balance, 3 ether, "paid exactly once");
        assertEq(fc.sAccruedFees(), 0, "no double-claim (CEI)");
    }
}
