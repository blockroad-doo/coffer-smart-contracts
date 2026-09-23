//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {stdError} from "forge-std/Test.sol";
import {Coffer} from "../../src/Coffer.sol";
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
    // CONSTRUCTOR
    // ========================================

    function test_Constructor_SetsOwner() public view {
        assertEq(coffer.owner(), validator);
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(coffer.iCofferBondNftAddress(), address(bondNft));
        assertEq(coffer.iCofferRedemptionEscrowAddress(), address(redemptionEscrow));
        assertEq(coffer.iPublicKeyPart1(), validPublicKeyPart1);
        assertEq(coffer.iPublicKeyPart2(), validPublicKeyPart2);
    }

    function test_Constructor_IssueSizeNotReduced() public view {
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, calculateExpectedIssueSize(defaultStartingBalance, defaultIssueSizeBufferBps));
    }

    function test_Constructor_LargeBalance_IssueSizeNotReduced() public {
        uint128 largeStartingBalance = 256 ether;
        address largeCofferAddr = createCoffer(
            validator,
            bytes32(uint256(11)),
            bytes16(uint128(21)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            largeStartingBalance
        );
        Coffer largeCoffer = Coffer(payable(largeCofferAddr));

        (uint128 issueSize,,,,,,,,,) = largeCoffer.sValidatorConditions();

        uint256 base = calculateExpectedIssueSize(largeStartingBalance, defaultIssueSizeBufferBps);
        // The initial issueSize is the buffer-scaled starting balance.
        assertEq(issueSize, base);
    }

    function test_Constructor_SetsAllValidatorConditions() public view {
        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,
            uint32 version,
            uint32 outstandingBonds,
            uint16 issueSizeBufferBps,
            bool isActive,
            bool validatorDefaulted
        ) = coffer.sValidatorConditions();

        assertEq(issueSize, calculateExpectedIssueSize(defaultStartingBalance, defaultIssueSizeBufferBps));
        assertEq(interestRate, defaultInterestRate);
        assertEq(minimumDuration, defaultMinDuration);
        assertEq(maximumDuration, defaultMaxDuration);
        assertEq(minimumValueToAccept, defaultMinimumAmount);
        assertEq(version, 1);
        assertEq(outstandingBonds, 0);
        assertEq(issueSizeBufferBps, defaultIssueSizeBufferBps);
        assertTrue(isActive);
        assertFalse(validatorDefaulted);
    }

    function test_Constructor_RevertsZeroFeeCurve() public {
        vm.expectRevert(Coffer.ZeroAddressFeeCurve.selector);
        new Coffer(address(0));
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

    /// @dev Gap row G-11: the issueSize credit is checked arithmetic, so at the uint128 ceiling a plain transfer
    ///      reverts and so does a consensus top-up, the documented cure path closing. Only the validator's own
    ///      changeIssueSize at zero bonds sets it up, and a lower value undoes it.
    function test_Receive_IssueSizeAtUint128Max_TopUpPathsRevertUntilIssueSizeLowered() public {
        vm.prank(validator);
        coffer.changeIssueSize(type(uint128).max);

        vm.prank(holder1);
        (bool success,) = cofferAddr.call{value: 1}("");
        assertFalse(success, "1 wei send must revert at the ceiling");
        assertEq(cofferAddr.balance, 0, "nothing lands");
        (uint128 issueSize,,,,,,,,,) = coffer.sValidatorConditions();
        assertEq(issueSize, type(uint128).max, "issueSize unchanged");

        // The credit overflows before the deposit contract is called
        vm.prank(validator);
        vm.expectRevert(stdError.arithmeticError);
        coffer.validatorAddFundsToConsensus{value: 1 ether}(bytes32(0));

        vm.prank(validator);
        coffer.changeIssueSize(1 ether);
        vm.prank(holder1);
        (success,) = cofferAddr.call{value: 1}("");
        assertTrue(success, "send lands once issueSize is lowered");
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

    function test_ChangeIssueSizeBufferBps_RevertsWhenDecreasedWithBondsExist() public {
        _setupBondForModifierTests();

        vm.prank(validator);
        vm.expectRevert(Coffer.ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist.selector);
        coffer.changeIssueSizeBufferBps(200); // decrease from 250
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
                defaultIssueSizeBufferBps,
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
        coffer.holderRedeemBondOrDefault(bondId);
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

        // holder2 can now redeem
        uint256 balBefore = holder2.balance;
        vm.prank(holder2);
        coffer.holderRedeemBondOrDefault(bondId);

        assertGt(holder2.balance, balBefore);
    }
}
