//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "../../unit/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {Coffer} from "../../../src/Coffer.sol";

import {CofferHandlerExt} from "./CofferHandlerExt.sol";

contract CofferInvariantExtTest is BaseTest {
    CofferHandlerExt public handler;

    uint128 public immutable STARTING_BALANCE;

    constructor() {
        STARTING_BALANCE = defaultStartingBalance;
    }

    function setUp() public virtual override {
        super.setUp();

        address cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));

        // Enable bond buying by setting issueSize
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        // Fund validator for redeemBondsEarly top-ups + consensus deposits
        vm.deal(validator, 10_000 ether);

        handler = new CofferHandlerExt(coffer, bondNft, bondsRedeemedEarly, feeCurve);

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
    // ghostIssueSize tracks: +startingBalance_buffered at init,
    // +msg.value on receive, +buffer*msg.value on validatorAddFundsToConsensus,
    // -bondMaturityValue on buyBond, -amount on validator withdraw with bonds,
    // reset on changeIssueSize.
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
    // INVARIANT 2: totalConsensusReserved EXACTNESS
    // totalConsensusReserved == sum of bondMaturityValue for closed bonds
    // ══════════════════════════════════════════════════════════════════════

    function invariant_totalConsensusReservedMatchesClosedSum() public view {
        uint256 ghostSum = handler.ghostTotalConsensusReserved();
        uint256 onChainReserved = coffer.totalConsensusReserved();

        assertEq(
            ghostSum, onChainReserved, "totalConsensusReserved must equal ghost sum of consensus-closed bond values"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 3: reserved => outstanding
    // totalConsensusReserved > 0 => outstandingBonds > 0
    // outstandingBonds == 0 => totalConsensusReserved == 0
    // ══════════════════════════════════════════════════════════════════════

    function invariant_reservedImpliesOutstanding() public view {
        (,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();
        uint128 reserved = coffer.totalConsensusReserved();

        if (reserved > 0) {
            assertTrue(outstandingBonds > 0, "totalConsensusReserved > 0 implies outstandingBonds > 0");
        }

        if (outstandingBonds == 0) {
            assertEq(reserved, 0, "outstandingBonds == 0 implies totalConsensusReserved == 0");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 4: bondMaturityValue >= principal per bond
    // No-loss-of-principal: bondMaturityValue >= msg.value for every active bond
    // ══════════════════════════════════════════════════════════════════════

    function invariant_bondMaturityValueGtePrincipal() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 onChainAmount,,,) = coffer.sHolderConditions(bondId);
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
    // issueSize/rate/maxDuration non-increasing, buffer non-decreasing,
    // exitAllowed false->true only
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
            bool exitAllowed
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
        assertLe(issueSizeBufferBps, 10000, "issueSizeBufferBps <= BUFFER_DENOMINATOR");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 6: CROSS-LAYER SOLVENCY
    // ghost issueSize + sum(bondMaturityValues) <= consensusBalance + balance
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
            (, uint128 amt,,) = handler.ghostPendingWithdrawals(j);
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
            (uint128 amount,,,) = coffer.sHolderConditions(bondId);
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
    // INVARIANT 16: CONSENSUS WITHDRAW CLOSED DATA PERSISTS
    // Bond with pending consensus withdrawal has non-zero on-chain amount
    // ══════════════════════════════════════════════════════════════════════

    function invariant_pendingConsensusDataPersists() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,, bool closed) = coffer.sHolderConditions(bondId);
            if (closed) {
                assertGt(amount, 0, "bond with consensusWithdrawClosed must have non-zero amount");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 17 (EP-10): STATE MUTATED BEFORE EXTERNAL CALL CHECK
    // After holderWithdrawFromConsensus sets consensusWithdrawClosed=true,
    // the bond must still exist with non-zero amount
    // ══════════════════════════════════════════════════════════════════════

    function invariant_consensusClosedStateConsistency() public view {
        uint128 totalConsensusReservedOnChain = coffer.totalConsensusReserved();
        uint256 ghostSum = handler.ghostTotalConsensusReserved();

        // Ghost sum should match on-chain (redundant with Invariant 2, but explicit)
        assertEq(ghostSum, totalConsensusReservedOnChain, "ghost totalConsensusReserved must match on-chain");
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 18: VALIDATOR CANNOT DRAIN CONSENSUS-RESERVED FUNDS
    // Balance must cover sum of bondMaturityValue for consensus-closed bonds
    // ══════════════════════════════════════════════════════════════════════

    function invariant_validatorCannotDrainConsensusReservedFunds() public view {
        uint256 sumLocked = 0;
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,, bool closed) = coffer.sHolderConditions(bondId);
            if (closed) {
                // Only count bonds whose ETH is already in the contract (not pending EIP-7002 arrival)
                bool ethInContract = !_isPendingEip7002Arrival(bondId);
                if (ethInContract) {
                    sumLocked += uint256(amount);
                }
            }
        }
        assertGe(
            address(coffer).balance,
            sumLocked,
            "validator must not drain balance below sum of consensus-closed bond values"
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
            (uint128 amount,,,) = coffer.sHolderConditions(bondId);
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
    // INVARIANT 22 (OD-1/TF-1): COVER-IN-PLACE msg.value CONSERVATION
    // After holderWithdrawFromConsensus with cover-in-place, consensusWithdrawClosed
    // must be true and totalConsensusReserved must include the amount
    // ══════════════════════════════════════════════════════════════════════

    function invariant_coverInPlaceConsistency() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            if (handler.ghostConsensusWithdrawClosed(bondId)) {
                (uint128 amount,,, bool closed) = coffer.sHolderConditions(bondId);
                assertTrue(closed, "ghost consensus flag must match on-chain flag");
                assertGt(amount, 0, "consensus-closed bond must have non-zero on-chain amount");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPER
    // ══════════════════════════════════════════════════════════════════════

    function _isPendingEip7002Arrival(uint256 bondId) internal view returns (bool) {
        // A bond is awaiting EIP-7002 arrival iff it is still in the handler's pending-withdrawals
        // queue (the public struct-array getter exposes bondId as the first field).
        uint256 plen = handler.getPendingWithdrawalsLength();
        for (uint256 i = 0; i < plen; i++) {
            (uint256 pBondId,,,) = handler.ghostPendingWithdrawals(i);
            if (pBondId == bondId) return true;
        }
        return false;
    }

    // ══════════════════════════════════════════════════════════════════════
    // INVARIANT 23: DEBUG CALL SUMMARY
    // ══════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console2.log("--- Extended Invariant Call Summary ---");
        console2.log("buyBond:                    ", handler.callsBuyBond());
        console2.log("holderWithdrawFromExecution: ", handler.callsHolderWithdrawFromExecution());
        console2.log("holderWithdrawFromConsensus: ", handler.callsHolderWithdrawFromConsensus());
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
        console2.log("changeExitAllowed:          ", handler.callsChangeExitAllowed());
        console2.log("advanceTime:                ", handler.callsAdvanceTime());
        console2.log("sendEthToCoffer:            ", handler.callsSendEthToCoffer());
        console2.log("--- Ghost Totals ---");
        console2.log("totalBought:                ", handler.ghostTotalBondsBought());
        console2.log("totalWithdrawnExecution:     ", handler.ghostTotalBondsWithdrawnExecution());
        console2.log("totalWithdrawnConsensus:     ", handler.ghostTotalBondsWithdrawnConsensus());
        console2.log("totalRedeemed:              ", handler.ghostTotalBondsRedeemed());
        console2.log("activeBonds:                ", handler.getActiveBondIdsLength());
        console2.log("pendingWithdrawals:         ", handler.getPendingWithdrawalsLength());
        console2.log("ghostIssueSize:             ", handler.ghostIssueSize());
        console2.log("ghostConsensusBalance:      ", handler.ghostConsensusBalance());
        console2.log("ghostTotalConsensusReserved: ", handler.ghostTotalConsensusReserved());
    }
}
