//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {CofferBondNftInvariantTest} from "./CofferBondNftInvariant.t.sol";
import {CofferBondNftHandler} from "./CofferBondNftHandler.sol";

contract CofferBondNftInvariantStrictTest is CofferBondNftInvariantTest {
    function setUp() public override {
        super.setUp();
        bytes4[] memory excluded = new bytes4[](1);
        excluded[0] = CofferBondNftHandler.handler_burnInvalid.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
