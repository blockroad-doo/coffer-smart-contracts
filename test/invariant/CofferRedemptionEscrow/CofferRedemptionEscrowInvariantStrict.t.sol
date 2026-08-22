//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {CofferRedemptionEscrowInvariantTest} from "./CofferRedemptionEscrowInvariant.t.sol";
import {CofferRedemptionEscrowHandler} from "./CofferRedemptionEscrowHandler.sol";

contract CofferRedemptionEscrowInvariantStrictTest is CofferRedemptionEscrowInvariantTest {
    function setUp() public override {
        super.setUp();
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = CofferRedemptionEscrowHandler.handlerClaimInvalid.selector;
        excluded[1] = CofferRedemptionEscrowHandler.handlerDepositInvalid.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: excluded}));
    }
}
