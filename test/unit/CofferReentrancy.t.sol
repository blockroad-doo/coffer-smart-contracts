// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title CofferReentrancyTest
 * @notice Reentrancy-safety tests for the bond lifecycle entry points.
 *
 * redeemBondOrDefault and redeemBondInDefault send value to the NFT owner at the end of both
 * branches. This is safe because state is mutated before every send. On the defaulted partial
 * branch the send drains the balance, so a reentrant second claim reverts. On the full branch the
 * bond is deleted before the send, so the reentrant claim hits the existence check.
 */
contract CofferReentrancyTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
    }

    // ════════════════════════════════════════════════════════════════════
    // Partial branch (redeemBondInDefault): malicious NFT owner reenters
    // on receipt of the partial payout; balance is already 0, so the reentrant
    // claim reverts.
    // ════════════════════════════════════════════════════════════════════

    function test_PartialRedeem_ReentrantSecondClaimReverts() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        ReentrantClaimer attacker = new ReentrantClaimer(cofferAddr);
        uint256 bmv = _bondMaturityValue(bondId);

        // Transfer the bond NFT to the attacker contract
        vm.prank(holder1);
        bondNft.transferFrom(holder1, address(attacker), bondId);

        // Default the validator, then underfund the contract so the first claim
        // takes the partial branch
        Coffer(payable(cofferAddr)).declareDefault(bondId);
        vm.deal(cofferAddr, bmv / 2);

        attacker.attackRedeemBondInDefault(bondId);

        // The reentrant second claim must NOT have succeeded
        assertFalse(attacker.reentrantSucceeded(), "reentrant second claim must fail");

        // Attacker received exactly one partial payout (the whole balance)
        assertEq(address(attacker).balance, bmv / 2, "one partial payout only");

        // Bond survives with the remainder; outstandingBonds unchanged
        assertEq(_bondMaturityValue(bondId), bmv - bmv / 2, "bond reduced by payout only");
        (,,,,,, uint32 outstanding,,,) = Coffer(payable(cofferAddr)).sValidatorConditions();
        assertEq(outstanding, 1, "outstandingBonds unchanged by partial claim");
    }

    // ════════════════════════════════════════════════════════════════════
    // Full branch (redeemBondOrDefault): state deleted + burn before the
    // send; the reentrant claim hits the existence check and reverts.
    // ════════════════════════════════════════════════════════════════════

    function test_FullRedeem_ReentrantSecondClaimReverts() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        ReentrantClaimer attacker = new ReentrantClaimer(cofferAddr);
        uint256 bmv = _bondMaturityValue(bondId);

        vm.prank(holder1);
        bondNft.transferFrom(holder1, address(attacker), bondId);

        // Fully fund the contract so the claim takes the full branch
        vm.deal(cofferAddr, bmv);

        attacker.attackRedeemBondOrDefault(bondId);

        assertFalse(attacker.reentrantSucceeded(), "reentrant second claim must fail");
        assertEq(address(attacker).balance, bmv, "exactly one full payout");

        // Bond is fully settled
        assertEq(_bondMaturityValue(bondId), 0, "bond deleted");
        (,,,,,, uint32 outstanding,,,) = Coffer(payable(cofferAddr)).sValidatorConditions();
        assertEq(outstanding, 0, "outstandingBonds decremented once");
    }

    // ════════════════════════════════════════════════════════════════════
    // Companion: the validator as a contract cannot reenter buyBond on
    // receipt of the principal payout, since msg.sender == owner() is blocked.
    // ════════════════════════════════════════════════════════════════════

    function test_ValidatorContractReentersBuyBond_Blocked() public {
        address c = createCoffer(
            address(this),
            bytes32(uint256(3)),
            bytes16(uint128(3)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );
        // NOTE: owner is this test contract, whose receive() reenters buyBond.

        uint256 bondId = buyBond(c, holder1, 5 ether, ONE_MONTH, 1);
        assertEq(bondNft.ownerOf(bondId), holder1, "bond minted to holder");

        // The reentrant buyBond attempt from receive() must have failed
        assertEq(bondNft.balanceOf(address(this)), 0, "validator got no bond NFT");
    }

    receive() external payable {
        // Validator-contract reentry attempt: must revert with
        // HolderCannotBeValidator (msg.sender == owner) and leave no trace.
        (bool ok,) = cofferAddr.call(abi.encodeCall(Coffer.buyBond, (ONE_MONTH, 1)));
        if (ok) {
            // Force a loud test failure if the guard is ever bypassed
            revert("REENTRANT BUYBOND SUCCEEDED");
        }
    }

    function _bondMaturityValue(uint256 bondId) internal view returns (uint128) {
        (uint128 bmv,,) = Coffer(payable(cofferAddr)).sHolderConditions(bondId);
        return bmv;
    }
}

/// @dev Malicious NFT owner that reenters redeemBondOrDefault / redeemBondInDefault
/// when it receives ETH. Records success instead of reverting so the outer call can
/// complete and be asserted on.
contract ReentrantClaimer {
    address public immutable coffer;
    uint256 public targetBondId;
    bool public reentrantSucceeded;
    bool internal useOrDefaultPath;

    constructor(address _coffer) {
        coffer = _coffer;
    }

    function attackRedeemBondOrDefault(uint256 bondId) external {
        targetBondId = bondId;
        useOrDefaultPath = true;
        Coffer(payable(coffer)).redeemBondOrDefault(bondId);
    }

    function attackRedeemBondInDefault(uint256 bondId) external {
        targetBondId = bondId;
        useOrDefaultPath = false;
        Coffer(payable(coffer)).redeemBondInDefault(bondId);
    }

    receive() external payable {
        if (useOrDefaultPath) {
            (bool ok,) = coffer.call(abi.encodeCall(Coffer.redeemBondOrDefault, (targetBondId)));
            if (ok) reentrantSucceeded = true;
        } else {
            (bool ok,) = coffer.call(abi.encodeCall(Coffer.redeemBondInDefault, (targetBondId)));
            if (ok) reentrantSucceeded = true;
        }
    }
}
