//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FeeCurveTest is Test {
    FeeCurve public curve;
    address public owner = makeAddr("owner");
    address public initialRecipient = makeAddr("initialRecipient");
    address public newRecipient = makeAddr("newRecipient");
    address public nonOwner = makeAddr("nonOwner");

    function setUp() public {
        vm.prank(owner);
        curve = new FeeCurve(owner, initialRecipient);
    }

    // ========================================
    // CONSTRUCTOR
    // ========================================

    function test_Constructor_SetsOwner() public view {
        assertEq(curve.owner(), owner);
    }

    function test_Constructor_SetsFeeRecipient() public view {
        assertEq(curve.feeRecipient(), initialRecipient);
    }

    function test_Constructor_SetsStartTime() public view {
        assertEq(curve.START_TIME(), block.timestamp);
    }

    function test_Constructor_RevertsZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(FeeCurve.ZeroAddress.selector);
        new FeeCurve(owner, address(0));
    }

    // ========================================
    // CURVE BREAKPOINTS: EXACT VALUES
    // ========================================

    function test_Curve_Day0() public view {
        assertEq(curve.feeBpsAtDay(0), 100); // 1%
    }

    function test_Curve_Day90() public view {
        assertEq(curve.feeBpsAtDay(90), 197);
    }

    function test_Curve_Day180() public view {
        assertEq(curve.feeBpsAtDay(180), 283);
    }

    function test_Curve_Day365() public view {
        assertEq(curve.feeBpsAtDay(365), 432);
    }

    function test_Curve_Day730() public view {
        assertEq(curve.feeBpsAtDay(730), 642);
    }

    function test_Curve_Day1095() public view {
        assertEq(curve.feeBpsAtDay(1095), 774);
    }

    function test_Curve_Day1460() public view {
        assertEq(curve.feeBpsAtDay(1460), 857);
    }

    function test_Curve_Day1825() public view {
        assertEq(curve.feeBpsAtDay(1825), 910);
    }

    function test_Curve_Day2555() public view {
        assertEq(curve.feeBpsAtDay(2555), 964);
    }

    function test_Curve_Day3650() public view {
        assertEq(curve.feeBpsAtDay(3650), 990); // ~9.9%
    }

    function test_Curve_PlateauBeyondYear10() public view {
        assertEq(curve.feeBpsAtDay(3650), 990);
        assertEq(curve.feeBpsAtDay(4000), 990);
        assertEq(curve.feeBpsAtDay(5000), 990);
        assertEq(curve.feeBpsAtDay(10000), 990);
    }

    // ========================================
    // CURVE: MONOTONICITY
    // ========================================

    function test_Curve_MonotonicallyIncreasing() public view {
        uint256 prev = curve.feeBpsAtDay(0);
        for (uint256 d = 1; d <= 4000; d += 50) {
            uint256 current = curve.feeBpsAtDay(d);
            assertGe(current, prev, "fee should be monotonically increasing");
            prev = current;
        }
    }

    // ========================================
    // CURVE: INTERPOLATION MIDPOINTS
    // ========================================

    function test_Curve_Midpoint_0_to_90() public view {
        // At day 45, fee should be exactly halfway between 100 and 197
        // (100 + (197-100)*45/90) = 100 + 97*0.5 = 100 + 48 = 148
        assertEq(curve.feeBpsAtDay(45), 148);
    }

    function test_Curve_Midpoint_90_to_180() public view {
        // (197 + (283-197)*45/90) = 197 + 86*0.5 = 197 + 43 = 240
        assertEq(curve.feeBpsAtDay(135), 240);
    }

    function test_Curve_Midpoint_180_to_365() public view {
        uint256 num = (432 - 283) * (272 - 180);
        uint256 den = 365 - 180;
        uint256 expected = 283 + num / den;
        assertEq(curve.feeBpsAtDay(272), expected);
    }

    // ========================================
    // getFee & currentFeeBps TIME RAMP
    // ========================================

    function test_GetFee_AtDay0() public view {
        (uint256 bps, address recipient) = curve.getFee();
        assertEq(bps, 100);
        assertEq(recipient, initialRecipient);
    }

    function test_CurrentFeeBps_AdvancesWithTime() public {
        assertEq(curve.currentFeeBps(), 100); // day 0

        vm.warp(block.timestamp + 90 days);
        assertEq(curve.currentFeeBps(), 197); // day 90

        vm.warp(block.timestamp + 275 days); // 365 days total
        assertEq(curve.currentFeeBps(), 432); // day 365

        vm.warp(block.timestamp + 3285 days); // 3650 days total (10 years)
        assertEq(curve.currentFeeBps(), 990); // plateau
    }

    // ========================================
    // setFeeRecipient: HAPPY PATH
    // ========================================

    function test_SetFeeRecipient_UpdatesRecipient() public {
        vm.prank(owner);
        curve.setFeeRecipient(newRecipient);

        assertEq(curve.feeRecipient(), newRecipient);
    }

    function test_SetFeeRecipient_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit FeeCurve.FeeRecipientChanged(initialRecipient, newRecipient);

        vm.prank(owner);
        curve.setFeeRecipient(newRecipient);
    }

    function test_SetFeeRecipient_ReflectedInGetFee() public {
        vm.prank(owner);
        curve.setFeeRecipient(newRecipient);

        (, address recipient) = curve.getFee();
        assertEq(recipient, newRecipient);
    }

    // ========================================
    // setFeeRecipient: REVERTS
    // ========================================

    function test_SetFeeRecipient_RevertsNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        curve.setFeeRecipient(newRecipient);
    }

    function test_SetFeeRecipient_RevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FeeCurve.ZeroAddress.selector);
        curve.setFeeRecipient(address(0));
    }
}
