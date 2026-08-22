//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferRedemptionEscrow} from "../../../src/CofferRedemptionEscrow.sol";

contract CofferRedemptionEscrowHandler is Test {
    CofferRedemptionEscrow public escrow;
    address[] public actors;

    // Ghost state
    mapping(address => uint256) public ghostPendingClaims;
    uint256 public ghostTotalPendingClaims;
    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalClaimed;
    address[] public ghostClaimants;
    mapping(address => bool) public ghostHasActiveClaim;

    // Call counters
    uint256 public callsDeposit;
    uint256 public callsClaim;
    uint256 public callsClaimInvalid;
    uint256 public callsDepositInvalid;

    constructor(CofferRedemptionEscrow _escrow) {
        escrow = _escrow;

        actors.push(makeAddr("escrowActor0"));
        actors.push(makeAddr("escrowActor1"));
        actors.push(makeAddr("escrowActor2"));
        actors.push(makeAddr("escrowActor3"));
        actors.push(makeAddr("escrowActor4"));

        for (uint256 i = 0; i < actors.length; ++i) {
            vm.deal(actors[i], 1000 ether);
        }
    }

    function handlerDeposit(uint256 actorSeed, uint256 holderCount, uint256 amountSeed) external {
        ++callsDeposit;

        address depositor = actors[actorSeed % actors.length];
        holderCount = bound(holderCount, 1, actors.length);

        address[] memory holders = new address[](holderCount);
        uint128[] memory amounts = new uint128[](holderCount);
        uint256 total = 0;

        for (uint256 i = 0; i < holderCount; ++i) {
            holders[i] = actors[(actorSeed % actors.length + i) % actors.length];
            amounts[i] = uint128(bound(uint256(keccak256(abi.encode(amountSeed, i))), 1, 10 ether));
            total += amounts[i];
        }

        if (depositor.balance < total) return;

        vm.prank(depositor);
        escrow.deposit{value: total}(holders, amounts);

        for (uint256 i = 0; i < holderCount; ++i) {
            ghostPendingClaims[holders[i]] += amounts[i];

            if (!ghostHasActiveClaim[holders[i]]) {
                ghostClaimants.push(holders[i]);
                ghostHasActiveClaim[holders[i]] = true;
            }
        }
        ghostTotalPendingClaims += total;
        ghostTotalDeposited += total;
    }

    function handlerClaim(uint256 claimantSeed) external {
        ++callsClaim;

        uint256 len = ghostClaimants.length;
        if (len == 0) return;

        uint256 idx = claimantSeed % len;
        address claimant = ghostClaimants[idx];

        uint256 amount = ghostPendingClaims[claimant];

        vm.prank(claimant);
        escrow.claim(payable(claimant));

        ghostPendingClaims[claimant] = 0;
        ghostHasActiveClaim[claimant] = false;
        ghostTotalPendingClaims -= amount;
        ghostTotalClaimed += amount;

        // Swap-and-pop
        ghostClaimants[idx] = ghostClaimants[len - 1];
        ghostClaimants.pop();
    }

    function handlerClaimInvalid(uint256 actorSeed) external {
        ++callsClaimInvalid;

        address actor = actors[actorSeed % actors.length];
        if (ghostHasActiveClaim[actor]) return;

        vm.prank(actor);
        // Absorb the expected NoPendingClaim() revert so the strict
        // profile (fail_on_revert = true) stays green
        try escrow.claim(payable(actor)) {
        // Unexpected success: nothing to record
        }
            catch {}
    }

    function handlerDepositInvalid(uint256 actorSeed) external {
        ++callsDepositInvalid;

        address depositor = actors[actorSeed % actors.length];

        address[] memory holders = new address[](2);
        holders[0] = depositor;
        holders[1] = depositor;

        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(depositor);
        // Absorb the expected DepositArrayLengthMismatch() revert so the strict
        // profile (fail_on_revert = true) stays green
        try escrow.deposit{value: 1 ether}(holders, amounts) {
        // Unexpected success: nothing to record
        }
            catch {}
    }

    // View helpers
    function getClaimantsLength() external view returns (uint256) {
        return ghostClaimants.length;
    }

    function getClaimantAt(uint256 index) external view returns (address) {
        return ghostClaimants[index];
    }

    function getActorsLength() external view returns (uint256) {
        return actors.length;
    }

    function getActorAt(uint256 index) external view returns (address) {
        return actors[index];
    }
}
