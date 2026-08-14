//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";
import {FeeCurveHandler} from "./FeeCurveHandler.sol";

contract FeeCurveInvariantTest is Test {
    FeeCurve public feeCurve;
    FeeCurveHandler public handler;

    address public feeOwner;
    address public feeRecipient;

    function setUp() public virtual {
        feeOwner = makeAddr("feeOwner");
        feeRecipient = makeAddr("feeRecipient");
        vm.deal(feeRecipient, 1000 ether);

        feeCurve = new FeeCurve(feeOwner, feeRecipient);
        handler = new FeeCurveHandler(feeCurve, feeOwner);
        targetContract(address(handler));
    }

    // 1. SOLVENCY: the fee pool holds exactly what the ghost says was accrued
    function invariant_BalanceEqualsGhostAccrued() public view {
        assertEq(address(feeCurve).balance, handler.ghostAccrued(), "balance must equal ghost accrued fees");
    }

    // 2. GHOST-TO-CHAIN CONSISTENCY
    function invariant_GhostAccruedMatchesOnChain() public view {
        assertEq(feeCurve.sAccruedFees(), handler.ghostAccrued(), "sAccruedFees must match ghost");
    }

    // 3. FEE CURVE SHAPE: sampled monotonic non-decrease across breakpoints.
    //    Full-range monotonicity is fuzzed separately in FeeCurveMathFuzz.
    function invariant_FeeMonotonicAcrossBreakpoints() public view {
        uint32[10] memory breakpointDay = [uint32(0), 90, 180, 365, 730, 1095, 1460, 1825, 2555, 3650];
        for (uint256 i = 0; i < 9; ++i) {
            assertLe(
                feeCurve.feeBpsAtDay(breakpointDay[i]),
                feeCurve.feeBpsAtDay(breakpointDay[i + 1]),
                "fee must not decrease across breakpoints"
            );
        }
    }

    // 4. FEE CURVE BOUNDS: starts at 1% (100 bps), asymptote 9.9% (990 bps)
    function invariant_FeeBounds() public view {
        uint256[11] memory sampleDays = [uint256(0), 1, 89, 90, 91, 365, 1000, 2554, 2555, 3649, 3650];
        for (uint256 i = 0; i < sampleDays.length; ++i) {
            uint256 fee = feeCurve.feeBpsAtDay(sampleDays[i]);
            assertGe(fee, 100, "fee must be >= 100 bps");
            assertLe(fee, 990, "fee must be <= 990 bps");
        }
    }

    // 5. PLATEAU: after year 10 the curve stays at 990 bps forever
    function invariant_PlateauAfterYearTen() public view {
        for (uint256 k = 0; k <= 2000; k += 500) {
            assertEq(feeCurve.feeBpsAtDay(3650 + k), 990, "fee must plateau at 990 bps after day 3650");
        }
    }

    // 6. RECIPIENT INTEGRITY: never zero, claim pays the stored recipient
    function invariant_FeeRecipientNeverZero() public view {
        assertNotEq(feeCurve.feeRecipient(), address(0), "fee recipient must never be zero");
    }

    // 7. DEBUG HELPER
    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("collectFee:     ", handler.callsCollectFee());
        console2.log("claim:          ", handler.callsClaim());
        console2.log("setFeeRecipient:", handler.callsSetFeeRecipient());
        console2.log("advanceTime:    ", handler.callsAdvanceTime());
        console2.log("ghostAccrued:   ", handler.ghostAccrued());
        console2.log("on-chain:       ", feeCurve.sAccruedFees());
    }
}
