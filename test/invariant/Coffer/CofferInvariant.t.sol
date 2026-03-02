//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest} from "../../unit/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {CofferHandler} from "./CofferHandler.sol";

contract CofferInvariantTest is BaseTest {
    CofferHandler public handler;

    function setUp() public virtual override {
        super.setUp();

        address cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));

        // Enable bond buying by setting issueSize
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        // Fund validator for redeemBondsEarly top-ups + consensus deposits
        vm.deal(validator, 10_000 ether);

        handler = new CofferHandler(coffer, bondNft);
        targetContract(address(handler));
    }

    // ══════════════════════════════════════════════════════════════════════
    // 1. ACCOUNTING
    // ══════════════════════════════════════════════════════════════════════

    function invariant_outstandingBondsMatchesGhost() public view {
        (,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();
        assertEq(
            uint256(outstandingBonds),
            handler.getActiveBondIdsLength(),
            "outstandingBonds must match ghost active bond count"
        );
    }

    function invariant_ghostAmountsMatchOnChain() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            assertEq(
                uint256(handler.ghostBondAmount(bondId)), uint256(amount), "ghostBondAmount must match on-chain amount"
            );
        }
    }

    function invariant_issueSizePlusBondsNonNegative() public view {
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();

        uint256 totalBondAmounts = 0;
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            totalBondAmounts += uint256(amount);
        }

        // Sum must fit in uint128 — no overflow/underflow corruption
        assertTrue(
            uint256(issueSize) + totalBondAmounts <= type(uint128).max,
            "issueSize + sum(bond amounts) must fit in uint128"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // 2. BOND-NFT CONSISTENCY
    // ══════════════════════════════════════════════════════════════════════

    function invariant_everyActiveBondHasValidNft() public {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            try bondNft.ownerOf(bondId) returns (address owner) {
                assertTrue(owner != address(0), "Active bond NFT owner must be non-zero");
            } catch {
                fail("ownerOf must not revert for active bond");
            }
        }
    }

    function invariant_everyActiveBondHasNonZeroAmount() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            assertTrue(amount > 0, "Active bond must have non-zero amount");
        }
    }

    function invariant_ghostHolderMatchesNftOwner() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            assertEq(handler.ghostBondHolder(bondId), bondNft.ownerOf(bondId), "ghostBondHolder must match NFT owner");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // 3. LIFECYCLE COUNTERS
    // ══════════════════════════════════════════════════════════════════════

    function invariant_bondLifecycleAccounting() public view {
        uint256 totalBought = handler.ghostTotalBondsBought();
        uint256 totalWithdrawnExec = handler.ghostTotalBondsWithdrawnExecution();
        uint256 totalRedeemed = handler.ghostTotalBondsRedeemed();
        uint256 activeCount = handler.getActiveBondIdsLength();

        assertEq(
            totalBought,
            totalWithdrawnExec + totalRedeemed + activeCount,
            "totalBought must equal totalWithdrawnExec + totalRedeemed + activeCount"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // 4. VERSION & CONFIG
    // ══════════════════════════════════════════════════════════════════════

    function invariant_versionMonotonicity() public view {
        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        // constructor sets version=1, setUp's changeIssueSize bumps to 2
        assertGe(version, 2, "version must be >= 2 after setUp");
    }

    function invariant_durationRangeValid() public view {
        (,, uint32 minimumDuration, uint32 maximumDuration,,,,,,) = coffer.sValidatorConditions();
        assertGe(maximumDuration, minimumDuration, "maximumDuration must be >= minimumDuration");
        assertGt(minimumDuration, 0, "minimumDuration must be > 0");
    }

    function invariant_interestRateInBounds() public view {
        (, uint32 interestRate,,,,,,,,) = coffer.sValidatorConditions();
        assertGt(interestRate, 0, "interestRate must be > 0");
        assertLe(interestRate, 1e8, "interestRate must be <= 1e8");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 5. CONSENSUS WITHDRAWAL CONSISTENCY
    // ══════════════════════════════════════════════════════════════════════

    function invariant_pendingConsensusImpliesActive() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            if (handler.ghostHasPendingConsensusWithdrawal(bondId)) {
                assertTrue(handler.ghostIsBondActive(bondId), "Pending consensus withdrawal implies bond is active");
            }
        }
    }

    function invariant_pendingConsensusDataPersists() public view {
        uint256 len = handler.getActiveBondIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = handler.getActiveBondIdAt(i);
            if (handler.ghostHasPendingConsensusWithdrawal(bondId)) {
                (uint128 amount,,) = coffer.sHolderConditions(bondId);
                assertGt(amount, 0, "Pending consensus bond must have non-zero on-chain amount");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // 6. DEBUG HELPER
    // ══════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("buyBond:                    ", handler.callsBuyBond());
        console2.log("holderWithdrawFromExecution: ", handler.callsHolderWithdrawFromExecution());
        console2.log("holderWithdrawFromConsensus: ", handler.callsHolderWithdrawFromConsensus());
        console2.log("simulateEthArrival:         ", handler.callsSimulateEthArrival());
        console2.log("redeemBondsEarly:           ", handler.callsRedeemBondsEarly());
        console2.log("validatorWithdrawExecution:  ", handler.callsValidatorWithdrawFromExecution());
        console2.log("validatorAddFundsConsensus:  ", handler.callsValidatorAddFundsToConsensus());
        console2.log("changeCofferActivity:       ", handler.callsChangeCofferActivity());
        console2.log("changeInterestRate:         ", handler.callsChangeInterestRate());
        console2.log("changeIssueSize:            ", handler.callsChangeIssueSize());
        console2.log("advanceTime:                ", handler.callsAdvanceTime());
        console2.log("--- Ghost Totals ---");
        console2.log("totalBought:                ", handler.ghostTotalBondsBought());
        console2.log("totalWithdrawnExecution:     ", handler.ghostTotalBondsWithdrawnExecution());
        console2.log("totalWithdrawnConsensus:     ", handler.ghostTotalBondsWithdrawnConsensus());
        console2.log("totalRedeemed:              ", handler.ghostTotalBondsRedeemed());
        console2.log("activeBonds:                ", handler.getActiveBondIdsLength());
        console2.log("pendingWithdrawals:         ", handler.getPendingWithdrawalsLength());
        console2.log("totalEthArrivedConsensus:   ", handler.ghostTotalEthArrivedFromConsensus());
    }
}
