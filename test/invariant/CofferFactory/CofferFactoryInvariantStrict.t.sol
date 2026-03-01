//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {CofferFactoryInvariantTest} from "./CofferFactoryInvariant.t.sol";
import {CofferFactoryHandler} from "./CofferFactoryHandler.sol";

contract CofferFactoryInvariantStrictTest is CofferFactoryInvariantTest {
    function setUp() public override {
        super.setUp();
        bytes4[] memory excluded = new bytes4[](1);
        excluded[0] = CofferFactoryHandler.handlerCreateCofferInvalid.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
