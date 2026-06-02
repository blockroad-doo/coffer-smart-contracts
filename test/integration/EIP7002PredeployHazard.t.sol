// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "../unit/BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title EIP7002PredeployHazardTest
 * @notice PoC verifying hypothesis EP-1: absent EIP-7002 predeploy = silent no-op
 * @dev Tests both holderWithdrawFromConsensus and validatorWithdrawFromConsensus
 */
contract EIP7002PredeployHazardTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            true, // exitAllowed = true so we can issue bonds without 32 ETH floor
            defaultStartingBalance
        );
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================================================
    // PHASE 1 - ATTACKER: Demonstrate silent no-op
    // ========================================================================

    function test_PredeployAbsent_HolderWithdrawFromConsensus_NoOp() public {
        // 1. Set up a bond
        vm.prank(validator);
        coffer.changeIssueSize(10 ether);

        uint32 version = 2;
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, version);

        // 2. Wait for bond maturity
        advanceTime(ONE_MONTH + 1);

        // Record pre-state
        (uint128 bondValueBefore,,, bool closedBefore) = coffer.sHolderConditions(bondId);
        uint256 reservedBefore = coffer.totalConsensusReserved();

        assertFalse(closedBefore, "Bond should not be closed yet");
        assertEq(reservedBefore, 0, "totalConsensusReserved should start at 0");

        // 3. Drain contract balance so cover-in-place (line 736) does NOT trigger
        //    cover-in-place fires when: balance >= bondMaturityValue + totalConsensusReserved
        vm.deal(cofferAddr, 0);

        // 4. Remove EIP-7002 predeploy code (simulate absent predeploy)
        vm.etch(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, hex"");

        // Verify predeploy code is gone
        uint256 codeSizeBefore;
        address predeploy = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS;
        assembly {
            codeSizeBefore := extcodesize(predeploy)
        }
        assertEq(codeSizeBefore, 0, "Predeploy code must be absent");

        // 5. Call holderWithdrawFromConsensus with 0 msg.value
        //    staticcall("") returns (true, "") when no code at address
        //    bytes32("") = 0 -> fee = 0 -> require(0 <= 0) passes
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: 0}(bondId);

        // 6. Verify bond marked closed despite no actual withdrawal
        (uint128 bondValueAfter,,, bool closedAfter) = coffer.sHolderConditions(bondId);
        uint256 reservedAfter = coffer.totalConsensusReserved();

        assertTrue(closedAfter, "consensusWithdrawClosed = true (DEFENDER LOST)");
        assertEq(bondValueAfter, bondValueBefore, "Bond value unchanged (no actual withdrawal)");
        assertGt(reservedAfter, reservedBefore, "totalConsensusReserved increased (DEFENDER LOST)");

        // 7. Verify that calling again reverts (bond permanently closed)
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSignature("ConsensusWithdrawAlreadyClosed()"));
        coffer.holderWithdrawFromConsensus{value: 0}(bondId);

        // 8. Verify holder CANNOT recover through holderWithdrawFromExecution
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSignature("ContractBalanceLessThanValue()"));
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_PredeployAbsent_ValidatorWithdrawFromConsensus_NoOp() public {
        // 1. Remove EIP-7002 predeploy code
        vm.etch(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, hex"");

        uint256 codeSizeBefore;
        address predeploy = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS;
        assembly {
            codeSizeBefore := extcodesize(predeploy)
        }
        assertEq(codeSizeBefore, 0, "Predeploy code must be absent");

        // 2. Record pre-state
        uint256 balanceBefore = cofferAddr.balance;

        // 3. Call validatorWithdrawFromConsensus with 0 msg.value
        //    staticcall("") returns (true, "") -> fee = 0 -> call{value:0}(data) to empty address succeeds
        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: 0}(0);

        // 4. Contract balance unchanged (no fee deducted, no funds received)
        uint256 balanceAfter = cofferAddr.balance;
        assertEq(balanceAfter, balanceBefore, "Balance unchanged - no withdrawal occurred (DEFENDER LOST)");
    }

    function test_PredeployPresent_WorksNormally() public {
        // CONTROL: With predeploy present, everything works
        vm.prank(validator);
        coffer.changeIssueSize(10 ether);

        uint32 version = 2;
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, version);

        advanceTime(ONE_MONTH + 1);

        // Predeploy IS present (mock deployed in setUp)
        address predeploy = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS;
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predeploy)
        }
        assertGt(codeSize, 0, "Predeploy must have code");

        // Get current fee
        uint256 fee = getWithdrawalFee();

        // With predeploy present, the call should work
        vm.prank(holder1);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);

        (,,, bool closedAfter) = coffer.sHolderConditions(bondId);
        assertTrue(closedAfter, "Bond should be closed normally with predeploy");
    }
}
