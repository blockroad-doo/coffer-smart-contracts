// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "../unit/BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

/**
 * @title EIP7002PredeployHazardTest
 * @notice EP-1: on a chain without the EIP-7002 predeploy, staticcall("") answers (true, "") and the write
 * call is a successful no-op. The old design burned the holder's one-shot consensus flag on that silent
 * no-op; under serve-or-default nothing is one-shot — exitValidator fails loud on the fee-length check and
 * stays re-callable forever, so the hazard's damage model collapses to gas.
 * @dev Pins the A14 delta for exitValidator and the unchanged validatorWithdrawFromConsensus behavior
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
            defaultStartingBalance
        );
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================================================
    // A14 delta: codeless predeploy fails loud, burns nothing
    // ========================================================================

    function test_PredeployAbsent_ExitValidator_FailsLoud() public {
        // 1. Manufacture a default: buyBond forwards the principal to the validator, so the contract
        //    holds nothing when the bond matures
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);
        coffer.declareDefault(bondId);

        // 2. Remove EIP-7002 predeploy code (simulate absent predeploy)
        vm.etch(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, hex"");

        uint256 codeSizeBefore;
        address predeploy = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS;
        assembly {
            codeSizeBefore := extcodesize(predeploy)
        }
        assertEq(codeSizeBefore, 0, "Predeploy code must be absent");

        // 3. A codeless predeploy answers staticcall("") with (true, ""). The old design decoded that to
        //    fee 0 and burned the holder's one-shot flag on a silent no-op; exitValidator's
        //    feeData.length == 32 check fails loud instead.
        vm.expectRevert(abi.encodeWithSignature("WithdrawalContractCallFailed()"));
        coffer.exitValidator{value: 0}();

        // 4. Nothing was burned: the default stands and the call stays repeatable forever
        (,,,,,,,,, bool defaulted) = coffer.sValidatorConditions();
        assertTrue(defaulted, "default flag untouched by the failed exit request");

        vm.expectRevert(abi.encodeWithSignature("WithdrawalContractCallFailed()"));
        coffer.exitValidator{value: 0}();
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

    function test_PredeployPresent_ExitValidator_WorksNormally() public {
        // CONTROL: with the predeploy present, a defaulted coffer's exit request enqueues normally
        uint256 bondId = buyBond(cofferAddr, holder1, 5 ether, ONE_MONTH, 1);
        advanceTime(ONE_MONTH + 1);
        coffer.declareDefault(bondId);

        // Predeploy IS present (mock deployed in setUp)
        address predeploy = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS;
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predeploy)
        }
        assertGt(codeSize, 0, "Predeploy must have code");

        uint256 fee = getWithdrawalFee();

        vm.expectEmit(true, false, false, true, cofferAddr);
        emit Coffer.ValidatorExitRequested(address(this));
        coffer.exitValidator{value: fee}();

        (, uint256 count,,) = getQueueState();
        assertEq(count, 1, "exit request enqueued at the predeploy");
    }
}
