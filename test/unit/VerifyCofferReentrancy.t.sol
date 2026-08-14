// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {ICofferBondNft} from "../../src/interfaces/ICofferBondNft.sol";

/**
 * @title VerifyCofferReentrancy
 * @notice Audit-regression guard for the reentrancy leads P-01/P-02 of the
 * 2026-08-13 audit. Closes two formally-open questions:
 *  - P-01: buyBond mints the NFT (Coffer.sol:397) before sHolderConditions[bondId]
 *    is written (393). REFUTED: mintCofferBond uses OZ ERC721._mint (not
 *    _safeMint), which performs no onERC721Received callback, so the mint is
 *    not a reentrancy window. Proven here by a receiver-less contract holder.
 *  - P-02: holderWithdrawFromExecution sends value to the NFT owner at the end
 *    of both branches. REFUTED: state is mutated before every send (CEI), and
 *    on the partial branch the send drains the balance, so any reentrant
 *    second claim reverts. Proven here by a malicious owner contract.
 */
contract VerifyCofferReentrancy is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
    }

    // ════════════════════════════════════════════════════════════════════
    // P-02 partial branch: malicious NFT owner reenters on receipt of the
    // partial payout; balance is already 0, so the reentrant claim reverts.
    // ════════════════════════════════════════════════════════════════════

    function test_PartialWithdraw_ReentrantSecondClaimReverts() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        ReentrantClaimer attacker = new ReentrantClaimer(cofferAddr);
        uint256 bmv = _bondMaturityValue(bondId);

        // Transfer the bond NFT to the attacker contract
        vm.prank(holder1);
        bondNft.transferFrom(holder1, address(attacker), bondId);

        // Underfund the coffer so the first claim takes the partial branch:
        // the bond was bought with 5 ETH principal forwarded to the validator,
        // so the balance is ~0; top up less than bmv.
        vm.deal(cofferAddr, bmv / 2);

        attacker.attackWithdraw(bondId);

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
    // P-02 full branch: state deleted + burn before the send; the reentrant
    // claim hits the existence check and reverts.
    // ════════════════════════════════════════════════════════════════════

    function test_FullWithdraw_ReentrantSecondClaimReverts() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);

        ReentrantClaimer attacker = new ReentrantClaimer(cofferAddr);
        uint256 bmv = _bondMaturityValue(bondId);

        vm.prank(holder1);
        bondNft.transferFrom(holder1, address(attacker), bondId);

        // Fully fund the pool so the claim takes the full branch
        vm.deal(cofferAddr, bmv);

        attacker.attackWithdraw(bondId);

        assertFalse(attacker.reentrantSucceeded(), "reentrant second claim must fail");
        assertEq(address(attacker).balance, bmv, "exactly one full payout");

        // Bond is fully settled
        assertEq(_bondMaturityValue(bondId), 0, "bond deleted");
        (,,,,,, uint32 outstanding,,,) = Coffer(payable(cofferAddr)).sValidatorConditions();
        assertEq(outstanding, 0, "outstandingBonds decremented once");
    }

    // ════════════════════════════════════════════════════════════════════
    // P-01: _mint (not _safeMint) means no onERC721Received callback — a
    // contract holder that implements NO receiver hook can still buy bonds.
    // ════════════════════════════════════════════════════════════════════

    function test_BuyBond_ReceiverlessContractHolderSucceeds() public {
        ReceiverlessBuyer buyer = new ReceiverlessBuyer();
        vm.deal(address(buyer), 10 ether);

        vm.prank(address(buyer));
        uint256 bondId = Coffer(payable(cofferAddr)).buyBond{value: 5 ether}(ONE_MONTH, 1);

        assertEq(bondNft.ownerOf(bondId), address(buyer), "NFT minted to receiver-less contract");
        assertEq(_bondMaturityValue(bondId) > 5 ether, true, "maturity value recorded");
    }

    // ════════════════════════════════════════════════════════════════════
    // P-01 companion: the validator as a contract cannot reenter buyBond on
    // receipt of the principal payout — msg.sender == owner() is blocked.
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

/// @dev Malicious NFT owner that reenters holderWithdrawFromExecution when it
/// receives ETH. Records success instead of reverting so the outer call can
/// complete and be asserted on.
contract ReentrantClaimer {
    address public immutable coffer;
    uint256 public targetBondId;
    bool public reentrantSucceeded;

    constructor(address _coffer) {
        coffer = _coffer;
    }

    function attackWithdraw(uint256 bondId) external {
        targetBondId = bondId;
        Coffer(payable(coffer)).holderWithdrawFromExecution(bondId);
    }

    receive() external payable {
        (bool ok,) = coffer.call(abi.encodeCall(Coffer.holderWithdrawFromExecution, (targetBondId)));
        if (ok) reentrantSucceeded = true;
    }
}

/// @dev Holder contract that intentionally implements no IERC721Receiver /
/// onERC721Received hook.
contract ReceiverlessBuyer {}
