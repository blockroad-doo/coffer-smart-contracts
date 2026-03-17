//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CofferBondsRedeemedEarly} from "../../../src/CofferBondsRedeemedEarly.sol";
import {CofferBondsRedeemedEarlyHandler} from "./CofferBondsRedeemedEarlyHandler.sol";

contract CofferBondsRedeemedEarlyInvariantTest is Test {
    CofferBondsRedeemedEarly public escrow;
    CofferBondsRedeemedEarlyHandler public handler;

    function setUp() public virtual {
        escrow = new CofferBondsRedeemedEarly();
        handler = new CofferBondsRedeemedEarlyHandler(escrow);
        targetContract(address(handler));
    }

    // 1. SOLVENCY
    function invariant_SolvencyContractBalanceEqualsGhostPending() public view {
        assertEq(
            address(escrow).balance,
            handler.ghostTotalPendingClaims(),
            "Contract balance must equal ghost total pending claims"
        );
    }

    // 2. ACCOUNTING
    function invariant_DepositMinusClaimsEqualsPending() public view {
        assertEq(
            handler.ghostTotalDeposited() - handler.ghostTotalClaimed(),
            handler.ghostTotalPendingClaims(),
            "Deposited minus claimed must equal pending"
        );
    }

    // 3. GHOST-TO-CHAIN CONSISTENCY
    function invariant_GhostClaimsMatchOnChain() public view {
        uint256 actorCount = handler.getActorsLength();
        for (uint256 i = 0; i < actorCount; ++i) {
            address actor = handler.getActorAt(i);
            assertEq(
                escrow.sPendingClaims(actor),
                handler.ghostPendingClaims(actor),
                "On-chain pending claims must match ghost state"
            );
        }
    }

    // 4. CLAIMANTS ARRAY CONSISTENCY
    function invariant_ClaimantsArrayConsistency() public view {
        uint256 len = handler.getClaimantsLength();
        for (uint256 i = 0; i < len; ++i) {
            address claimant = handler.getClaimantAt(i);
            assertTrue(handler.ghostHasActiveClaim(claimant), "Claimant must have active claim flag");
            assertGt(handler.ghostPendingClaims(claimant), 0, "Claimant must have non-zero pending claims");
        }
    }

    // 5. MONOTONICITY
    function invariant_TotalClaimedNeverExceedsTotalDeposited() public view {
        assertLe(
            handler.ghostTotalClaimed(),
            handler.ghostTotalDeposited(),
            "Total claimed must never exceed total deposited"
        );
    }

    // 6. ZERO-PENDING EXCLUSION
    function invariant_ZeroPendingMeansNotInClaimants() public view {
        uint256 actorCount = handler.getActorsLength();
        for (uint256 i = 0; i < actorCount; ++i) {
            address actor = handler.getActorAt(i);
            if (handler.ghostPendingClaims(actor) == 0) {
                assertFalse(handler.ghostHasActiveClaim(actor), "Zero-pending actor must not be in claimants");
            }
        }
    }

    // 7. BALANCE COVERS ALL CLAIMS
    function invariant_ContractBalanceCoversAllClaims() public view {
        assertGe(
            address(escrow).balance, handler.ghostTotalPendingClaims(), "Contract balance must cover all pending claims"
        );
    }

    // 8. DEBUG HELPER
    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("deposit:        ", handler.callsDeposit());
        console2.log("claim:          ", handler.callsClaim());
        console2.log("claimInvalid:   ", handler.callsClaimInvalid());
        console2.log("depositInvalid: ", handler.callsDepositInvalid());
        console2.log("--- Ghost Totals ---");
        console2.log("totalDeposited: ", handler.ghostTotalDeposited());
        console2.log("totalClaimed:   ", handler.ghostTotalClaimed());
        console2.log("totalPending:   ", handler.ghostTotalPendingClaims());
        console2.log("claimants:      ", handler.getClaimantsLength());
    }
}
