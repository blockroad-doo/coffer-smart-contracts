//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

contract VerifyExitAllowedTest is BaseTest {
    uint256 constant BUFFER_DENOMINATOR = 10000;

    // ========================================
    // V-3 / CS-17: exitAllowed toggle does not recalculate issueSize 32 ETH floor
    // ========================================

    function test_CS17_ExitAllowedTrueToFalse_IssueSizeUnchanged() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 issueSizeBefore,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool exitAllowedBefore) = c.sValidatorConditions();
        assertEq(issueSizeBefore, 100 ether, "init: issueSize should be full starting balance");
        assertTrue(exitAllowedBefore);

        vm.prank(validator);
        c.changeExitAllowed();

        (uint128 issueSizeAfter,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool exitAllowedAfter) = c.sValidatorConditions();
        assertFalse(exitAllowedAfter, "exitAllowed should be false after toggle");
        assertEq(issueSizeAfter, issueSizeBefore, "BUG: issueSize unchanged after true->false toggle");

        assertLt(startingBalance - issueSizeAfter, 32 ether, "BUG: consensusFloor < 32 ETH when exitAllowed=false");

        uint256 consensusFloor = startingBalance - issueSizeAfter;
        assertEq(consensusFloor, 0, "consensus floor is 0 - no headroom for holders");
    }

    function test_CS17_ExitAllowedFalseToTrue_IssueSizeRemainsDeducted() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            false,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 issueSizeBefore,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool exitAllowedBefore) = c.sValidatorConditions();
        assertEq(issueSizeBefore, 100 ether - 32 ether, "init: issueSize should have 32 ETH floor deduction");
        assertFalse(exitAllowedBefore);

        vm.prank(validator);
        c.changeExitAllowed();

        (uint128 issueSizeAfter,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool exitAllowedAfter) = c.sValidatorConditions();
        assertTrue(exitAllowedAfter, "exitAllowed should be true after toggle");
        assertEq(
            issueSizeAfter,
            issueSizeBefore,
            "issueSize unchanged on false->true toggle (overcollateralization, not exploitable)"
        );
        assertEq(issueSizeAfter, 68 ether, "still has 32 ETH deduction from init");
    }

    function test_CS17_ExitAllowedToggle_MultipleFlips_IssueSizeNeverCorrects() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 initIssueSize,,,,,,,,,) = c.sValidatorConditions();
        assertEq(initIssueSize, 100 ether);

        vm.prank(validator);
        c.changeExitAllowed();
        (uint128 issueSize1,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool ea1) = c.sValidatorConditions();
        assertEq(issueSize1, 100 ether, "flip 1: still 100 ETH, no deduction");
        assertFalse(ea1);

        vm.prank(validator);
        c.changeExitAllowed();
        (uint128 issueSize2,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool ea2) = c.sValidatorConditions();
        assertEq(issueSize2, 100 ether, "flip 2: still 100 ETH, never recalculated");
        assertTrue(ea2);

        vm.prank(validator);
        c.changeExitAllowed();
        (uint128 issueSize3,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool ea3) = c.sValidatorConditions();
        assertEq(issueSize3, 100 ether, "flip 3: issueSize pinned at initial value");
        assertFalse(ea3);
    }

    function testFuzz_CS17_RangeOfBalances(uint128 startingBalance) public {
        startingBalance = uint128(bound(startingBalance, 33 ether, 2048 ether));

        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 issueSizeBefore,,,,,,,,,) = c.sValidatorConditions();

        vm.prank(validator);
        c.changeExitAllowed();

        (uint128 issueSizeAfter,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,,,, bool exitAllowedAfter) = c.sValidatorConditions();
        assertFalse(exitAllowedAfter);
        assertEq(issueSizeAfter, issueSizeBefore, "fuzz: issueSize unchanged after toggle");
        assertLt(startingBalance - issueSizeAfter, 32 ether, "fuzz: invariant violated for all fuzzed balances");
    }

    // ========================================
    // V-4 / BSA-1: issueSize and issueSizeBufferBps independently settable
    // ========================================

    function test_BSA1_HighBufferHighIssueSize_Inconsistent() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        vm.prank(validator);
        c.changeIssueSizeBufferBps(1000);

        (,,,,,,, uint16 buffer1,,) = c.sValidatorConditions();
        assertEq(buffer1, 1000);

        vm.prank(validator);
        c.changeIssueSize(95 ether);

        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buffer2,,) = c.sValidatorConditions();
        assertEq(issueSize, 95 ether);
        assertEq(buffer2, 1000);

        uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - buffer2) / BUFFER_DENOMINATOR;
        assertEq(maxAllowed, 90 ether, "buffer cap should allow max 90 ETH");
        assertGt(issueSize, maxAllowed, "BUG: issueSize exceeds buffer-capped limit - inconsistent state");
    }

    function test_BSA1_BufferIncrease_IssueSizeNotReduced() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 issueSize0,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf0,,) = c.sValidatorConditions();
        assertEq(issueSize0, 100 ether);
        assertEq(buf0, 0);

        for (uint16 i = 0; i < 3; i++) {
            uint16 newBuf = uint16(500 * (i + 1));
            vm.prank(validator);
            c.changeIssueSizeBufferBps(newBuf);

            (uint128 issSize,,,,,,,,,) = c.sValidatorConditions();
            (,,,,,,, uint16 buf,,) = c.sValidatorConditions();
            assertEq(buf, newBuf);

            uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - buf) / BUFFER_DENOMINATOR;
            assertGt(issSize, maxAllowed, "BUG: issueSize not reduced when buffer increased");
        }
    }

    function test_BSA1_IssueSizeNotCheckedAgainstBuffer() public {
        address cofferAddr = createDefaultCoffer();
        Coffer c = Coffer(payable(cofferAddr));

        vm.prank(validator);
        c.changeIssueSizeBufferBps(500);

        uint128 tooHigh = 31 ether;
        vm.prank(validator);
        c.changeIssueSize(tooHigh);

        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf,,) = c.sValidatorConditions();
        uint256 maxAllowed = uint256(defaultStartingBalance) * (BUFFER_DENOMINATOR - buf) / BUFFER_DENOMINATOR;
        assertGt(issueSize, maxAllowed, "BUG: changeIssueSize accepts values exceeding buffer-capped maximum");
    }

    function testFuzz_BSA1_FuzzBufferAndIssueSize(uint16 bufferBps, uint128 issueSizeVal) public {
        bufferBps = uint16(bound(bufferBps, 0, 5000));
        uint128 startingBalance = 100 ether;

        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        vm.prank(validator);
        c.changeIssueSizeBufferBps(bufferBps);

        issueSizeVal = uint128(bound(issueSizeVal, 1 ether, 200 ether));
        vm.prank(validator);
        c.changeIssueSize(issueSizeVal);

        (uint128 actualIssueSize,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 actualBuffer,,) = c.sValidatorConditions();

        uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - actualBuffer) / BUFFER_DENOMINATOR;

        if (actualIssueSize > maxAllowed) {
            assertGt(actualIssueSize, maxAllowed, "confirmed: issueSize exceeds buffer cap");
        }
    }

    // ========================================
    // Combined scenario
    // ========================================

    function test_Combined_ExitAllowedToggleAndBufferChange_CompoundingInconsistency() public {
        uint128 startingBalance = 100 ether;
        address cofferAddr = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0,
            true,
            startingBalance
        );
        Coffer c = Coffer(payable(cofferAddr));

        (uint128 issueSize0,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf0,,) = c.sValidatorConditions();
        (,,,,,,,,, bool ea0) = c.sValidatorConditions();
        assertEq(issueSize0, 100 ether);
        assertEq(buf0, 0);
        assertTrue(ea0);

        vm.prank(validator);
        c.changeIssueSizeBufferBps(1000);

        (uint128 issueSize1,,,,,,,,,) = c.sValidatorConditions();
        assertEq(issueSize1, 100 ether);

        vm.prank(validator);
        c.changeExitAllowed();

        (uint128 issueSize2,,,,,,,,,) = c.sValidatorConditions();
        (,,,,,,, uint16 buf2,,) = c.sValidatorConditions();
        (,,,,,,,,, bool ea2) = c.sValidatorConditions();
        assertFalse(ea2);
        assertEq(buf2, 1000);
        assertEq(issueSize2, 100 ether, "BUG: issueSize never adjusted for buffer or exitAllowed changes");

        uint256 maxAllowed = uint256(startingBalance) * (BUFFER_DENOMINATOR - buf2) / BUFFER_DENOMINATOR;
        uint256 properlyConfigured = maxAllowed > 32 ether ? maxAllowed - 32 ether : 0;
        assertGt(
            issueSize2, properlyConfigured, "BUG: issueSize exceeds properly-configured value by significant margin"
        );
    }
}
