//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";

contract GasComparisonTest is BaseTest {
    address public cofferAddr;
    address public cofferAddrExit;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));

        // Create a second coffer with exitAllowed = true
        cofferAddrExit = createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );

        // Setup: set issueSize so we can buy bonds
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);
    }

    function test_GAS_createCoffer() public {
        uint256 gasBefore = gasleft();
        createCoffer(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            false
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("createCoffer", gasUsed);
    }

    function test_GAS_buyBond() public {
        vm.prank(holder1);
        uint256 gasBefore = gasleft();
        Coffer(payable(cofferAddr)).buyBond{value: 1 ether}(ONE_MONTH, 2);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("buyBond", gasUsed);
    }

    function test_GAS_changeIssueSize() public {
        vm.prank(validator);
        uint256 gasBefore = gasleft();
        coffer.changeIssueSize(50 ether);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("changeIssueSize", gasUsed);
    }

    function test_GAS_changeInterestRate() public {
        vm.prank(validator);
        uint256 gasBefore = gasleft();
        coffer.changeInterestRate(defaultInterestRate - 1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("changeInterestRate", gasUsed);
    }

    function test_GAS_changeSafeTotalStake() public {
        vm.prank(validator);
        uint256 gasBefore = gasleft();
        coffer.changeSafeTotalStake(defaultSafeTotalStake - 1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("changeSafeTotalStake", gasUsed);
    }

    function test_GAS_changeCofferActivity() public {
        vm.prank(validator);
        uint256 gasBefore = gasleft();
        coffer.changeCofferActivity();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("changeCofferActivity", gasUsed);
    }

    function test_GAS_receive() public {
        uint256 gasBefore = gasleft();
        (bool ok,) = cofferAddr.call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        require(ok);
        emit log_named_uint("receive", gasUsed);
    }

    function test_GAS_holderWithdrawFromExecution() public {
        // Buy bond and mature it
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        vm.warp(block.timestamp + ONE_MONTH + 1);
        // Fund coffer for full withdrawal
        vm.deal(cofferAddr, 10 ether);

        vm.prank(holder1);
        uint256 gasBefore = gasleft();
        Coffer(payable(cofferAddr)).holderWithdrawFromExecution(bondId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("holderWithdrawFromExecution", gasUsed);
    }

    function test_GAS_redeemBondsEarly() public {
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        vm.deal(cofferAddr, 10 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = bondId;

        vm.prank(validator);
        uint256 gasBefore = gasleft();
        Coffer(payable(cofferAddr)).redeemBondsEarly(ids);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("redeemBondsEarly", gasUsed);
    }

    function test_GAS_validatorWithdrawFromExecution() public {
        vm.deal(cofferAddr, 10 ether);

        vm.prank(validator);
        uint256 gasBefore = gasleft();
        coffer.validatorWithdrawFromExecution(1 ether);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("validatorWithdrawFromExecution", gasUsed);
    }

    function test_GAS_iPublicKeyPart1() public view {
        uint256 gasBefore = gasleft();
        coffer.iPublicKeyPart1();
        uint256 gasUsed = gasBefore - gasleft();
        // Can't emit in view, but forge will show gas in trace
    }

    function test_GAS_iCofferBondNftAddress() public view {
        uint256 gasBefore = gasleft();
        coffer.iCofferBondNftAddress();
        uint256 gasUsed = gasBefore - gasleft();
    }
}
