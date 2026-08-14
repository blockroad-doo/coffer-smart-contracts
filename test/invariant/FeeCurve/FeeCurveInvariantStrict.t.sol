//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {FeeCurveInvariantTest} from "./FeeCurveInvariant.t.sol";

contract FeeCurveInvariantStrictTest is FeeCurveInvariantTest {
    function setUp() public override {
        super.setUp();
    }
}
