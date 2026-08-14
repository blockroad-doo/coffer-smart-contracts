//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";

contract FeeCurveHandler is Test {
    FeeCurve public feeCurve;
    address public owner;
    address[] public actors;

    // Ghost state
    uint256 public ghostAccrued;

    // Call counters
    uint256 public callsCollectFee;
    uint256 public callsClaim;
    uint256 public callsSetFeeRecipient;
    uint256 public callsAdvanceTime;

    constructor(FeeCurve _feeCurve, address _owner) {
        feeCurve = _feeCurve;
        owner = _owner;

        actors.push(makeAddr("feeActor0"));
        actors.push(makeAddr("feeActor1"));
        actors.push(makeAddr("feeActor2"));
        actors.push(makeAddr("feeActor3"));

        for (uint256 i = 0; i < actors.length; ++i) {
            vm.deal(actors[i], 1000 ether);
        }
        vm.deal(owner, 1000 ether);
    }

    function handlerCollectFee(uint256 actorSeed, uint256 amountSeed) external {
        ++callsCollectFee;

        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 100 ether);

        if (actor.balance < amount) return;

        vm.prank(actor);
        feeCurve.collectFee{value: amount}();

        ghostAccrued += amount;
    }

    function handlerClaim() external {
        ++callsClaim;

        if (feeCurve.sAccruedFees() == 0) return;

        feeCurve.claim();

        ghostAccrued = 0;
    }

    function handlerSetFeeRecipient(uint256 actorSeed) external {
        ++callsSetFeeRecipient;

        address newRecipient = actors[actorSeed % actors.length];
        if (newRecipient == feeCurve.feeRecipient()) return;

        vm.prank(owner);
        feeCurve.setFeeRecipient(newRecipient);
    }

    function handlerAdvanceTime(uint256 seconds_) external {
        ++callsAdvanceTime;

        vm.warp(block.timestamp + bound(seconds_, 1, 400 days));
    }
}
