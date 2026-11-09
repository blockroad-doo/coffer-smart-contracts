//SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {FeeCurveInvariantTest} from "./FeeCurveInvariant.t.sol";

contract FeeCurveInvariantStrictTest is FeeCurveInvariantTest {
    function setUp() public override {
        super.setUp();
    }
}
