//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {CofferBondsRedeemedEarlyInvariantTest} from "./CofferBondsRedeemedEarlyInvariant.t.sol";
import {CofferBondsRedeemedEarlyHandler} from "./CofferBondsRedeemedEarlyHandler.sol";

contract CofferBondsRedeemedEarlyInvariantStrictTest is CofferBondsRedeemedEarlyInvariantTest {
    function setUp() public override {
        super.setUp();
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = CofferBondsRedeemedEarlyHandler.handlerClaimInvalid.selector;
        excluded[1] = CofferBondsRedeemedEarlyHandler.handlerDepositInvalid.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
