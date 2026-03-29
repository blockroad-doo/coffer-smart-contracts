//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferBondsRedeemedEarly} from "../../src/CofferBondsRedeemedEarly.sol";

/// @dev Contract that rejects all ETH transfers
contract RejectEtherClaim {
    CofferBondsRedeemedEarly public claimContract;

    constructor(CofferBondsRedeemedEarly _claimContract) {
        claimContract = _claimContract;
    }

    function claimTo(address payable _to) external {
        claimContract.claim(_to);
    }

    receive() external payable {
        revert();
    }
}

/// @dev Contract that reenters claim() on receive
contract ReentrancyAttacker {
    CofferBondsRedeemedEarly public claimContract;
    address payable public target;
    uint256 public attackCount;

    constructor(CofferBondsRedeemedEarly _claimContract) {
        claimContract = _claimContract;
        target = payable(address(this));
    }

    function attack() external {
        claimContract.claim(target);
    }

    receive() external payable {
        attackCount++;
        if (attackCount < 3) {
            claimContract.claim(target);
        }
    }
}

contract CofferBondsRedeemedEarlyTest is Test {
    CofferBondsRedeemedEarly public claimContract;

    address public depositor = makeAddr("depositor");
    address public holder1 = makeAddr("holder1");
    address public holder2 = makeAddr("holder2");
    address public holder3 = makeAddr("holder3");

    event ClaimDeposited(address indexed holder, uint128 indexed amount);
    event ClaimWithdrawn(address indexed claimant, address indexed to, uint256 indexed amount);

    function setUp() public {
        claimContract = new CofferBondsRedeemedEarly();
        vm.deal(depositor, 1000 ether);
    }

    // ========================================
    // deposit
    // ========================================

    function test_Deposit_SingleHolder() public {
        address[] memory holders = new address[](1);
        holders[0] = holder1;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 1 ether}(holders, amounts);

        assertEq(claimContract.sPendingClaims(holder1), 1 ether);
        assertEq(address(claimContract).balance, 1 ether);
    }

    function test_Deposit_MultipleHolders() public {
        address[] memory holders = new address[](3);
        holders[0] = holder1;
        holders[1] = holder2;
        holders[2] = holder3;
        uint128[] memory amounts = new uint128[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 6 ether}(holders, amounts);

        assertEq(claimContract.sPendingClaims(holder1), 1 ether);
        assertEq(claimContract.sPendingClaims(holder2), 2 ether);
        assertEq(claimContract.sPendingClaims(holder3), 3 ether);
    }

    function test_Deposit_RevertsOnMismatchedArrayLengths() public {
        address[] memory holders = new address[](2);
        holders[0] = holder1;
        holders[1] = holder2;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(depositor);
        vm.expectRevert(CofferBondsRedeemedEarly.DepositArrayLengthMismatch.selector);
        claimContract.deposit{value: 1 ether}(holders, amounts);
    }

    function test_Deposit_RevertsOnMsgValueMismatch() public {
        address[] memory holders = new address[](1);
        holders[0] = holder1;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(depositor);
        vm.expectRevert(CofferBondsRedeemedEarly.DepositMsgValueMismatch.selector);
        claimContract.deposit{value: 2 ether}(holders, amounts);
    }

    function test_Deposit_AccumulatesForSameHolder() public {
        address[] memory holders = new address[](1);
        holders[0] = holder1;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 1 ether}(holders, amounts);

        vm.prank(depositor);
        claimContract.deposit{value: 1 ether}(holders, amounts);

        assertEq(claimContract.sPendingClaims(holder1), 2 ether);
    }

    // ========================================
    // claim
    // ========================================

    function test_Claim_Success() public {
        // Deposit first
        address[] memory holders = new address[](1);
        holders[0] = holder1;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 5 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 5 ether}(holders, amounts);

        uint256 balBefore = holder1.balance;

        vm.prank(holder1);
        claimContract.claim(payable(holder1));

        assertEq(holder1.balance, balBefore + 5 ether);
        assertEq(claimContract.sPendingClaims(holder1), 0);
    }

    function test_Claim_ToAlternateAddress() public {
        // Non-payable contract redirects to EOA
        RejectEtherClaim rejector = new RejectEtherClaim(claimContract);

        address[] memory holders = new address[](1);
        holders[0] = address(rejector);
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 3 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 3 ether}(holders, amounts);

        address payable recipient = payable(makeAddr("recipient"));
        uint256 balBefore = recipient.balance;

        rejector.claimTo(recipient);

        assertEq(recipient.balance, balBefore + 3 ether);
        assertEq(claimContract.sPendingClaims(address(rejector)), 0);
    }

    function test_Claim_RevertsIfNoPendingClaim() public {
        vm.prank(holder1);
        vm.expectRevert(CofferBondsRedeemedEarly.NoPendingClaim.selector);
        claimContract.claim(payable(holder1));
    }

    function test_Claim_EmitsEvent() public {
        address[] memory holders = new address[](1);
        holders[0] = holder1;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 2 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 2 ether}(holders, amounts);

        vm.expectEmit(true, true, false, true);
        emit ClaimWithdrawn(holder1, holder1, 2 ether);

        vm.prank(holder1);
        claimContract.claim(payable(holder1));
    }

    function test_Claim_ReentrancySafe() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(claimContract);

        address[] memory holders = new address[](1);
        holders[0] = address(attacker);
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 5 ether;

        vm.prank(depositor);
        claimContract.deposit{value: 5 ether}(holders, amounts);

        // Reentrancy attempt should revert with NoPendingClaim on second call
        // because mapping is zeroed before transfer (CEI pattern)
        vm.expectRevert(CofferBondsRedeemedEarly.NoPendingClaim.selector);
        attacker.attack();
    }
}
