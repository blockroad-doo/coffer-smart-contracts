//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract CofferMainOpsTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Sets up a coffer with availableAmount and buys a bond, returning bondId
    function _setupBondForModifierTests() internal returns (uint256 bondId) {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2
        bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
    }

    // ========================================
    // CONSTRUCTOR (exitAllowed = false)
    // ========================================

    function test_Constructor_ExitNotAllowed_SetsOwner() public view {
        assertEq(coffer.owner(), validator);
    }

    function test_Constructor_ExitNotAllowed_SetsImmutables() public view {
        assertEq(coffer.iCofferBondNftAddress(), address(bondNft));
        assertEq(coffer.iCofferBondsRedeemedEarly(), address(bondsRedeemedEarly));
        assertEq(coffer.iPublicKeyPart1(), validPublicKeyPart1);
        assertEq(coffer.iPublicKeyPart2(), validPublicKeyPart2);
    }

    function test_Constructor_ExitNotAllowed_AvailableAmountIsZero() public view {
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, 0);
    }

    function test_Constructor_ExitNotAllowed_LargeBalance_IssueSizeMinusThirtyTwoEther() public {
        uint128 largeStartingBalance = 256 ether;
        address noExitCofferAddr = createCoffer(
            validator,
            bytes32(uint256(11)),
            bytes16(uint128(21)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            false,
            largeStartingBalance
        );
        Coffer noExitCoffer = Coffer(payable(noExitCofferAddr));

        (uint128 issueSize,,,,,,,,,) = noExitCoffer.sValidatorConditions();

        uint256 base = Penalty.addMaximumPenalty(largeStartingBalance, defaultSafeTotalStake, defaultMaxDuration / 384);
        // exitAllowed = false reserves an extra 32 ether headroom on top of maxPenalty.
        assertGt(base, 32 ether);
        assertEq(issueSize, base - 32 ether);
    }

    function test_Constructor_ExitNotAllowed_SetsAllValidatorConditions() public view {
        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = coffer.sValidatorConditions();

        assertEq(issueSize, 0);
        assertEq(interestRate, defaultInterestRate);
        assertEq(minimumDuration, defaultMinDuration);
        assertEq(maximumDuration, defaultMaxDuration);
        assertEq(minimumValueToAccept, defaultMinimumAmount);
        assertEq(version, 1);
        assertEq(outstandingBonds, 0);
        assertEq(safeTotalStake, defaultSafeTotalStake);
        assertTrue(isActive);
        assertFalse(exitAllowed);
    }

    // ========================================
    // CONSTRUCTOR (exitAllowed = true)
    // ========================================

    function test_Constructor_ExitAllowed_CalculatesAvailableAmount() public {
        address exitCofferAddr = createCoffer(
            validator,
            bytes32(uint256(10)),
            bytes16(uint128(20)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (uint128 issueSize,,,,,,,,,) = exitCoffer.sValidatorConditions();

        uint256 expected =
            Penalty.addMaximumPenalty(defaultStartingBalance, defaultSafeTotalStake, defaultMaxDuration / 384);
        assertEq(issueSize, expected);
    }

    function test_Constructor_ExitAllowed_AvailableAmountIsPositive() public {
        address exitCofferAddr = createCoffer(
            validator,
            bytes32(uint256(10)),
            bytes16(uint128(20)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (uint128 issueSize,,,,,,,,,) = exitCoffer.sValidatorConditions();
        assertGt(issueSize, 0);
    }

    function test_Constructor_ExitAllowed_SetsAllValidatorConditions() public {
        address exitCofferAddr = createCoffer(
            validator,
            bytes32(uint256(10)),
            bytes16(uint128(20)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true
        );
        Coffer exitCoffer = Coffer(payable(exitCofferAddr));

        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = exitCoffer.sValidatorConditions();

        uint256 expectedAvailable =
            Penalty.addMaximumPenalty(defaultStartingBalance, defaultSafeTotalStake, defaultMaxDuration / 384);

        assertEq(issueSize, expectedAvailable);
        assertEq(interestRate, defaultInterestRate);
        assertEq(minimumDuration, defaultMinDuration);
        assertEq(maximumDuration, defaultMaxDuration);
        assertEq(minimumValueToAccept, defaultMinimumAmount);
        assertEq(version, 1);
        assertEq(outstandingBonds, 0);
        assertEq(safeTotalStake, defaultSafeTotalStake);
        assertTrue(isActive);
        assertTrue(exitAllowed);
    }

    // ========================================
    // receive()
    // ========================================

    function test_Receive_AcceptsEthFromAnyone() public {
        vm.deal(unauthorizedUser, 10 ether);
        vm.prank(unauthorizedUser);
        (bool success,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 1 ether);
    }

    function test_Receive_AcceptsEthFromValidator() public {
        vm.prank(validator);
        (bool success,) = cofferAddr.call{value: 5 ether}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 5 ether);
    }

    function test_Receive_AcceptsZeroValue() public {
        vm.prank(holder1);
        (bool success,) = cofferAddr.call{value: 0}("");
        assertTrue(success);
        assertEq(cofferAddr.balance, 0);
    }

    function test_Receive_AcceptsMultipleDeposits() public {
        vm.prank(holder1);
        (bool s1,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(holder2);
        (bool s2,) = cofferAddr.call{value: 2 ether}("");
        assertTrue(s2);

        assertEq(cofferAddr.balance, 3 ether);
    }

    function test_Receive_IncreasesIssueSize() public {
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.deal(unauthorizedUser, 10 ether);
        vm.prank(unauthorizedUser);
        (bool success,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(success);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore + 1 ether);
    }

    function test_Receive_ZeroValueNoIssueSizeChange() public {
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(holder1);
        (bool success,) = cofferAddr.call{value: 0}("");
        assertTrue(success);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore);
    }

    function test_Receive_CumulativeIssueSizeIncrease() public {
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(holder1);
        (bool s1,) = cofferAddr.call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(holder2);
        (bool s2,) = cofferAddr.call{value: 2 ether}("");
        assertTrue(s2);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore + 3 ether);
    }

    function test_Receive_IssueSizeIncreaseFromValidator() public {
        (uint128 issueSizeBefore,,,,,,,,,) = coffer.sValidatorConditions();

        vm.prank(validator);
        (bool success,) = cofferAddr.call{value: 5 ether}("");
        assertTrue(success);

        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, issueSizeBefore + 5 ether);
    }

    // ========================================
    // OUTSTANDING BONDS RESTRICTIONS
    // ========================================

    function test_ChangeIssueSize_RevertsWhenIncreasedWithBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector);
        coffer.changeIssueSize(15 ether); // increase from 10 ether triggers revert
    }

    function test_ChangeExitAllowed_RevertsWhenForbiddingExitsWithBondsExist() public {
        vm.prank(validator);
        coffer.changeExitAllowed(); // version -> 2, exitAllowed = true

        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 3

        buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 3);

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotForbidExitsWhileOutstandingBondExists.selector);
        coffer.changeExitAllowed(); // tries true -> false, should revert
    }

    function test_ChangeSafeTotalStake_RevertsWhenIncreasedWithBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist.selector);
        coffer.changeSafeTotalStake(30_000_000);
    }

    function test_ValidatorWithdrawFromExecution_BoundedByIssueSizeWhenBondsExist() public {
        _setupBondForModifierTests();

        // Fund the contract so balance is sufficient
        vm.deal(cofferAddr, 10 ether);

        // Read current issueSize (reduced after bond purchase)
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();

        // Withdraw exactly issueSize: should succeed
        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(issueSize);

        // issueSize should now be 0
        (uint128 issueSizeAfter,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSizeAfter, 0);
    }

    // ========================================
    // RENOUNCE OWNERSHIP
    // ========================================

    function test_RenounceOwnership_RevertsWhenCalledByOwner() public {
        vm.prank(validator);
        vm.expectRevert(Coffer.RenounceOwnershipDisabled.selector);
        coffer.renounceOwnership();
    }

    function test_RenounceOwnership_RevertsWhenCalledByNonOwner() public {
        vm.prank(holder1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder1));
        coffer.renounceOwnership();
    }

    // ========================================
    // IMPLEMENTATION CANNOT BE REINITIALIZED
    // ========================================

    function test_Implementation_CannotBeReinitialized() public {
        address impl = factory.I_COFFER_IMPLEMENTATION();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Coffer(payable(impl))
            .initialize(
                validator,
                defaultInterestRate,
                defaultMinDuration,
                defaultMaxDuration,
                defaultMinimumAmount,
                defaultSafeTotalStake,
                false,
                defaultStartingBalance
            );
    }

    // ========================================
    // PRIVATE holderIsCaller (indirect)
    // ========================================

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromExecution() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromExecution(bondId);
    }

    function test_HolderIsCaller_RevertsIfNotNftOwner_WithdrawFromConsensus() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        advanceTime(ONE_MONTH + 1);

        uint256 fee = getWithdrawalFee();

        vm.prank(holder2); // not the NFT owner
        vm.expectRevert(Coffer.CallerIsNotHolder.selector);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);
    }

    function test_HolderIsCaller_SucceedsAfterNftTransfer() public {
        vm.prank(validator);
        coffer.changeIssueSize(10 ether); // version -> 2

        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);

        // Transfer NFT from holder1 to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        vm.deal(cofferAddr, 10 ether);
        advanceTime(ONE_MONTH + 1);

        // holder2 can now withdraw
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderWithdrawFromExecution(bondId);

        assertGt(holder2.balance, balBefore);
    }
}
