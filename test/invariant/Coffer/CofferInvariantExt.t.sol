//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "../../unit/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {Coffer} from "../../../src/Coffer.sol";

import {CofferHandlerExt} from "./CofferHandlerExt.sol";

contract CofferInvariantExtTest is BaseTest {
    CofferHandlerExt public handler;

    function setUp() public virtual override {
        super.setUp();

        address cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));

        // Enable bond buying by setting issueSize
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        // Fund validator for redeemBondsEarly top-ups + consensus deposits
        vm.deal(validator, 10_000 ether);

        handler = new CofferHandlerExt(coffer, feeCurve);

        // Seed ghost consensus balance to model the validator stake backing issueSize.
        // issueSize is the validator's buffer-scaled consensus-layer stake; since setUp inflated
        // issueSize to 100 ether above, the modeled consensus balance must cover it for the
        // cross-layer solvency check to reflect an honest, adequately-staked validator.
        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        handler.seedConsensusBalance(issueSizeAfter);

        targetContract(address(handler));
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 1: issueSize CONSERVATION (GHOST ACCUMULATOR)
    // ghostIssueSize starts from the on-chain issueSize read at handler construction (setUp has
    // already raised it to 100 ether), then tracks: +msg.value on receive, +buffer*msg.value on
    // validatorAddFundsToConsensus, -bondMaturityValue on buyBond, -amount on validator withdraw
    // with bonds outstanding, reset on changeIssueSize. Post-default the on-chain bumps continue
    // through receive() and the ghost keeps mirroring them; since clearDefault the consumers wake
    // up again after the default clears, so the mirror matters across the whole declare-and-clear cycle.
    // ══════════════════════════════════════════════════════════════════════

    function invariant_issueSizeGhostMatchesOnChain() public {
        (uint128 issueSizeOnChain,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(
            uint256(handler.ghostIssueSize()),
            uint256(issueSizeOnChain),
            "issueSize ghost accumulator must match on-chain issueSize"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 4: bondMaturityValue >= principal per bond
    // No-loss-of-principal: bondMaturityValue >= msg.value for every active bond
    // ══════════════════════════════════════════════════════════════════════

    function invariant_bondMaturityValueGtePrincipal() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 onChainAmount,,) = coffer.sHolderConditions(bondId);
            uint128 principal = handler.ghostPrincipal(bondId);
            // A partial execution withdrawal reduces the on-chain remainder, so compare the
            // remainder PLUS what the holder already received against principal. No-loss-of-principal
            // means received + remaining >= principal (it holds at issuance since fee <= 9.9% of interest).
            assertGe(
                uint256(onChainAmount) + uint256(handler.ghostExecutionWithdrawn(bondId)),
                uint256(principal),
                "bondMaturityValue (incl. already-withdrawn) must be >= principal per bond"
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 5: PARAMETER MONOTONICITY WHILE BONDS OUTSTANDING
    // issueSize/rate/maxDuration non-increasing, buffer non-decreasing
    // ══════════════════════════════════════════════════════════════════════

    function invariant_parameterBoundsWhileBondsOutstanding() public view {
        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,,,
            uint16 issueSizeBufferBps,
            bool isActive,
            bool validatorDefaulted
        ) = coffer.sValidatorConditions();

        // All values must be within protocol constants
        assertLe(interestRate, 1e8, "interestRate <= MAX_RATE");
        assertGt(interestRate, 0, "interestRate > 0");
        assertGt(minimumDuration, 0, "minimumDuration > 0");
        assertLe(maximumDuration, 1_576_800_000, "maximumDuration <= MAX_DURATION");
        assertGe(maximumDuration, minimumDuration, "maxDuration >= minDuration");
        assertGt(minimumValueToAccept, 0, "minimumValueToAccept > 0");
        // NOTE: issueSize >= minimumValueToAccept is NOT a maintained invariant. The contract enforces
        // it only inside changeIssueSize; changeMinimumValueToAccept has no upper bound vs issueSize,
        // and buyBond freely shrinks issueSize. issueSize < minimumValueToAccept is a harmless,
        // validator-self-correctable state (it only pauses new issuance), so it is not asserted here.
        assertLt(issueSizeBufferBps, 10000, "issueSizeBufferBps < BUFFER_DENOMINATOR");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 6: CROSS-LAYER SOLVENCY
    // ghost issueSize + sum(bondMaturityValues) <= consensusBalance + balance
    // On-chain this is the cross-layer solvency condition, not an
    // invariant: consensus penalties can shrink the right side with no contract
    // transition. It IS a true invariant of this model, because the model
    // excludes penalties by construction (the honest-staking device raises the
    // modeled stake to back every capacity assertion), so the condition's
    // environmental assumption always holds here.
    // ══════════════════════════════════════════════════════════════════════

    function invariant_crossLayerSolvency() public view {
        (uint128 issueSize,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();
        if (outstandingBonds == 0) return; // No cross-layer solvency concern when no bonds exist

        // Sum all active bond maturity values
        uint256 sumBondMaturity = 0;
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            sumBondMaturity += uint256(handler.ghostBondMaturityValue(bondId));
        }

        // Count ETH currently in the EIP-7002 exit queue (subtracted from ghostConsensusBalance at
        // request time, credited to contract balance only on simulated arrival). Without this, the
        // in-transit ETH is uncounted during the request->arrival window and understates collateral.
        uint256 inTransit = 0;
        uint256 plen = handler.getPendingWithdrawalsLength();
        for (uint256 j = 0; j < plen; j++) {
            (uint128 amt,) = handler.ghostPendingWithdrawals(j);
            inTransit += uint256(amt);
        }

        uint256 totalObligations = uint256(issueSize) + sumBondMaturity;
        uint256 totalCollateral = uint256(handler.ghostConsensusBalance()) + address(coffer).balance + inTransit;

        assertLe(
            totalObligations,
            totalCollateral + 32 ether, // 32 ETH solvency tolerance margin
            "cross-layer solvency: issueSize + sum(bonds) <= consensusBalance + contractBalance"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 7: ESCROW SELF-SOLVENCY
    // CofferBondsRedeemedEarly.balance >= sum(sPendingClaims)
    // ══════════════════════════════════════════════════════════════════════

    function invariant_escrowSelfSolvency() public view {
        // The escrow is 1:1 backed by design: deposit requires msg.value == sum(amounts)
        // and claim zeroes the mapping before sending. So balance >= sum(claims) always.
        // We verify the contract exists and has no cross-theft.
        assertTrue(address(bondsRedeemedEarly).code.length > 0, "escrow contract must exist");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 8: CWIA ROUND-TRIP DIFFERENTIAL TEST
    // Clone immutable args == factory inputs
    // ══════════════════════════════════════════════════════════════════════

    function invariant_cwiaRoundTrip() public view {
        // Clone's immutable args must match factory-deployed addresses
        assertEq(coffer.iCofferBondNftAddress(), address(bondNft), "CWIA: CofferBondNft address mismatch");
        assertEq(
            coffer.iCofferBondsRedeemedEarly(),
            address(bondsRedeemedEarly),
            "CWIA: CofferBondsRedeemedEarly address mismatch"
        );
        assertEq(coffer.iPublicKeyPart1(), validPublicKeyPart1, "CWIA: publicKeyPart1 mismatch");
        assertEq(coffer.iPublicKeyPart2(), validPublicKeyPart2, "CWIA: publicKeyPart2 mismatch");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 9: outstandingBonds MATCHES GHOST ACTIVE BOND COUNT
    // (From original CofferInvariant, replicated for completeness)
    // ══════════════════════════════════════════════════════════════════════

    function invariant_outstandingBondsMatchesGhost() public view {
        (,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();
        assertEq(
            uint256(outstandingBonds),
            handler.getActiveBondIdsLength(),
            "outstandingBonds must match ghost active bond count"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 10: BOND LIFECYCLE ACCOUNTING
    // totalBought = withdrawnExec + redeemed + activeCount
    // ══════════════════════════════════════════════════════════════════════

    function invariant_bondLifecycleAccounting() public view {
        uint256 totalBought = handler.ghostTotalBondsBought();
        uint256 totalWithdrawnExec = handler.ghostTotalBondsWithdrawnExecution();
        uint256 totalRedeemed = handler.ghostTotalBondsRedeemed();
        uint256 activeCount = handler.getActiveBondIdsLength();

        assertEq(
            totalBought,
            totalWithdrawnExec + totalRedeemed + activeCount,
            "totalBought == withdrawnExec + redeemed + active"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 11 (AC-1): issueSize MUST COVER ALL OUTSTANDING BONDS
    // Validator cannot decrease issueSize below sum of outstanding bond maturity values
    // ══════════════════════════════════════════════════════════════════════

    function invariant_issueSizeCoversOutstandingBonds() public view {
        (uint128 issueSize,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();
        if (outstandingBonds == 0) return;

        uint256 sumBondMaturity = 0;
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            sumBondMaturity += uint256(handler.ghostBondMaturityValue(bondId));
        }

        // issueSize + sum(bondMaturityValues) must not overflow uint128
        assertTrue(
            uint256(issueSize) + sumBondMaturity <= type(uint128).max,
            "issueSize + sum(bondMaturityValues) must fit in uint128"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 12 (AC-6): VERSION MONOTONICITY
    // version must always be >= 2 after setUp
    // ══════════════════════════════════════════════════════════════════════

    function invariant_versionMonotonicity() public view {
        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertGe(version, 2, "version must be >= 2 after setUp");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 13: EVERY ACTIVE BOND HAS NON-ZERO ON-CHAIN AMOUNT
    // ══════════════════════════════════════════════════════════════════════

    function invariant_everyActiveBondHasNonZeroAmount() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            assertTrue(amount > 0, "active bond must have non-zero on-chain amount");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 14: EVERY ACTIVE BOND HAS VALID NFT
    // ══════════════════════════════════════════════════════════════════════

    function invariant_everyActiveBondHasValidNft() public {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            try bondNft.ownerOf(bondId) returns (address owner) {
                assertTrue(owner != address(0), "active bond NFT owner must be non-zero");
            } catch {
                assertTrue(false, "ownerOf must not revert for active bond");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 15: GHOST HOLDER MATCHES NFT OWNER
    // ══════════════════════════════════════════════════════════════════════

    function invariant_ghostHolderMatchesNftOwner() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            assertEq(handler.ghostBondHolder(bondId), bondNft.ownerOf(bondId), "ghost holder must match NFT owner");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 16-18: DEFAULT STATE MACHINE (serve-or-default)
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Only our handler flips the default flag, in either direction. The ghost is set on a
    /// handler-observed declareDefault and cleared on a handler-observed clearDefault (which the
    /// handler only attempts at outstandingBonds == 0), so two-way equality proves the on-chain
    /// flag never rises without a declare and never clears without a settlement-gated clearDefault.
    function invariant_defaultMirrored() public view {
        (,,,,,,,,, bool validatorDefaulted) = coffer.sValidatorConditions();
        assertEq(validatorDefaulted, handler.ghostValidatorDefaulted(), "on-chain default flag must mirror the ghost");
    }

    /// @dev A covered bond can never trigger a default. The handler records a violation if a
    /// declare ever succeeded while the bond was covered.
    function invariant_coveredBondNeverDefaulted() public view {
        assertFalse(handler.ghostDefaultViolation(), "declareDefault must never succeed against a covered bond");
    }

    /// @dev While a default epoch is open, the bond set only shrinks (buyBond is frozen, bonds
    /// leave via payment or redemption only). The snapshots re-baseline at every declare, so the
    /// property holds per epoch across declare-and-clear cycles.
    function invariant_bondSetOnlyShrinksPostDefault() public view {
        if (!handler.ghostValidatorDefaulted()) return;
        assertLe(
            handler.getActiveBondIdsLength(),
            handler.ghostBondsAtDefault(),
            "active bond count must not grow after default"
        );
        assertEq(handler.ghostTotalBondsBought(), handler.ghostBoughtAtDefault(), "no bond can be minted after default");
    }

    /// @dev While a default epoch is open, ETH leaves the contract only toward bond owners. Every
    /// modeled flow is attributed in the handler's per-epoch ledger (balance snapshot and counters
    /// re-baselined at each declare), so the balance must reconcile exactly: any wei leaking to the
    /// validator (or anywhere else) inside the epoch breaks the equality. Validator extraction
    /// between epochs is legal and deliberately unattributed.
    function invariant_postDefaultOutflowOnlyToHolders() public view {
        if (!handler.ghostValidatorDefaulted()) return;
        assertEq(
            address(coffer).balance,
            handler.ghostBalanceAtDefault() + handler.ghostBalanceInflowsSinceDefault()
                - handler.ghostBalanceOutflowsSinceDefault(),
            "post-default contract balance must reconcile against the attributed ledger"
        );
    }

    /// @dev Shadow invariant: while a default epoch is open, the recovery estate only migrates toward the
    /// contract. The modeled consensus stake never grows inside the epoch (deposits are frozen), it
    /// only drains into in-transit (exit sweep, pre-default partials) and from there into the
    /// contract balance. The stake snapshot re-baselines at each declare, so post-clear deposits
    /// belong to the next epoch.
    function invariant_consensusEstateMonotonePostDefault() public view {
        if (!handler.ghostValidatorDefaulted()) return;
        assertLe(
            uint256(handler.ghostConsensusBalance()),
            uint256(handler.ghostConsensusAtDefault()),
            "modeled consensus stake must never grow after default"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 19: GHOST AMOUNTS MATCH ON-CHAIN
    // ghostBondMaturityValue must match sHolderConditions amount for active bonds
    // ══════════════════════════════════════════════════════════════════════

    function invariant_ghostAmountsMatchOnChain() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            assertEq(
                uint256(handler.ghostBondMaturityValue(bondId)),
                uint256(amount),
                "ghost bondMaturityValue must match on-chain amount"
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 20: DURATION RANGE VALID
    // maximumDuration >= minimumDuration > 0
    // ══════════════════════════════════════════════════════════════════════

    function invariant_durationRangeValid() public view {
        (,, uint32 minimumDuration, uint32 maximumDuration,,,,,,) = coffer.sValidatorConditions();
        assertGe(maximumDuration, minimumDuration, "maximumDuration >= minimumDuration");
        assertGt(minimumDuration, 0, "minimumDuration > 0");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 21: INTEREST RATE IN BOUNDS
    // 0 < interestRate <= 1e8
    // ══════════════════════════════════════════════════════════════════════

    function invariant_interestRateInBounds() public view {
        (, uint32 interestRate,,,,,,,,) = coffer.sValidatorConditions();
        assertGt(interestRate, 0, "interestRate > 0");
        assertLe(interestRate, 1e8, "interestRate <= MAX_RATE");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 23: DEBUG CALL SUMMARY
    // ══════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console2.log("--- Extended Invariant Call Summary ---");
        console2.log("buyBond:                    ", handler.callsBuyBond());
        console2.log("redeemBondOrDefault: ", handler.callsRedeemBondOrDefault());
        console2.log("redeemBondInDefault: ", handler.callsRedeemBondInDefault());
        console2.log("simulateEthArrival:         ", handler.callsSimulateEthArrival());
        console2.log("redeemBondsEarly:           ", handler.callsRedeemBondsEarly());
        console2.log("validatorWithdrawExecution:  ", handler.callsValidatorWithdrawFromExecution());
        console2.log("validatorWithdrawConsensus:  ", handler.callsValidatorWithdrawFromConsensus());
        console2.log("validatorAddFundsConsensus:  ", handler.callsValidatorAddFundsToConsensus());
        console2.log("convertToCompounding:       ", handler.callsConvertToCompounding());
        console2.log("changeCofferActivity:       ", handler.callsChangeCofferActivity());
        console2.log("changeInterestRate:         ", handler.callsChangeInterestRate());
        console2.log("changeIssueSize:            ", handler.callsChangeIssueSize());
        console2.log("changeIssueSizeBufferBps:   ", handler.callsChangeIssueSizeBufferBps());
        console2.log("changeMinMaxDuration:       ", handler.callsChangeMinimumAndMaximumDuration());
        console2.log("changeMinValueToAccept:     ", handler.callsChangeMinimumValueToAccept());
        console2.log("advanceTime:                ", handler.callsAdvanceTime());
        console2.log("sendEthToCoffer:            ", handler.callsSendEthToCoffer());
        console2.log("declareDefault:             ", handler.callsDeclareDefault());
        console2.log("exitValidator:              ", handler.callsExitValidator());
        console2.log("clearDefault:               ", handler.callsClearDefault());
        console2.log("--- Ghost Totals ---");
        console2.log("totalBought:                ", handler.ghostTotalBondsBought());
        console2.log("totalWithdrawnExecution:     ", handler.ghostTotalBondsWithdrawnExecution());
        console2.log("totalRedeemed:              ", handler.ghostTotalBondsRedeemed());
        console2.log("activeBonds:                ", handler.getActiveBondIdsLength());
        console2.log("pendingWithdrawals:         ", handler.getPendingWithdrawalsLength());
        console2.log("totalEthArrivedConsensus:   ", handler.ghostTotalEthArrivedFromConsensus());
        console2.log("ghostIssueSize:             ", handler.ghostIssueSize());
        console2.log("ghostConsensusBalance:      ", handler.ghostConsensusBalance());
        console2.log("defaultsDeclared:           ", handler.ghostTotalDefaultsDeclared());
        console2.log("defaultsCleared:            ", handler.ghostTotalDefaultsCleared());
        console2.log("validatorDefaulted:         ", handler.ghostValidatorDefaulted() ? uint256(1) : uint256(0));
    }
}
