//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title CofferFactoryTest
 * @notice Unit tests for CofferFactory contract
 * @dev Tests follow logical progression: constructor → happy cases → reverts → boundary cases
 */
contract CofferFactoryTest is BaseTest {
    // ========================================
    // CONSTANTS (must match CofferFactory)
    // ========================================

    uint256 private constant MAX_RATE = 1e8;
    uint256 private constant VALIDATOR_STARTING_ETH = 32 ether;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;

    // ========================================
    // DRY HELPERS
    // ========================================

    /// @dev Calls factory.createCoffer with given params, captures CofferIssued event, returns deployed address
    function _createCofferAndGetAddress(
        address caller,
        bytes32 pubKeyPart1,
        bytes16 pubKeyPart2,
        uint32 interestRate,
        uint32 minDuration,
        uint32 maxDuration,
        uint128 minimumAmount,
        uint32 safeTotalStake,
        bool exitAllowed
    ) internal returns (address cofferAddr) {
        vm.startPrank(caller);
        vm.recordLogs();

        factory.createCoffer(
            pubKeyPart1, pubKeyPart2, interestRate, minDuration, maxDuration, minimumAmount, safeTotalStake, exitAllowed
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("CofferIssued(address,address)")) {
                cofferAddr = address(uint160(uint256(entries[i].topics[2])));
                break;
            }
        }

        vm.stopPrank();
    }

    /// @dev Reads sValidatorConditions into a Coffer.ValidatorConditions struct (avoids stack-too-deep)
    function _getValidatorConditions(address cofferAddr) internal view returns (Coffer.ValidatorConditions memory vc) {
        Coffer c = Coffer(payable(cofferAddr));
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
        ) = c.sValidatorConditions();
        vc.issueSize = issueSize;
        vc.interestRate = interestRate;
        vc.minimumDuration = minimumDuration;
        vc.maximumDuration = maximumDuration;
        vc.minimumValueToAccept = minimumValueToAccept;
        vc.version = version;
        vc.outstandingBonds = outstandingBonds;
        vc.safeTotalStake = safeTotalStake;
        vc.isActive = isActive;
        vc.exitAllowed = exitAllowed;
    }

    /// @dev Asserts all fields of sValidatorConditions on a deployed Coffer
    function _assertValidatorConditions(
        address cofferAddr,
        uint128 expectedAvailable,
        uint32 expectedRate,
        uint32 expectedMinDuration,
        uint32 expectedMaxDuration,
        uint128 expectedMinAmount,
        uint32 expectedVersion,
        uint32 expectedOutstandingBonds,
        uint32 expectedSafeTotalStake,
        bool expectedIsActive,
        bool expectedExitAllowed
    ) internal view {
        Coffer.ValidatorConditions memory vc = _getValidatorConditions(cofferAddr);

        assertEq(vc.issueSize, expectedAvailable, "issueSize mismatch");
        assertEq(vc.interestRate, expectedRate, "interestRate mismatch");
        assertEq(vc.minimumDuration, expectedMinDuration, "minimumDuration mismatch");
        assertEq(vc.maximumDuration, expectedMaxDuration, "maximumDuration mismatch");
        assertEq(vc.minimumValueToAccept, expectedMinAmount, "minimumValueToAccept mismatch");
        assertEq(vc.version, expectedVersion, "version mismatch");
        assertEq(vc.outstandingBonds, expectedOutstandingBonds, "outstandingBonds mismatch");
        assertEq(vc.safeTotalStake, expectedSafeTotalStake, "safeTotalStake mismatch");
        assertEq(vc.isActive, expectedIsActive, "isActive mismatch");
        assertEq(vc.exitAllowed, expectedExitAllowed, "exitAllowed mismatch");
    }

    /// @dev Computes the dynamic max for _minimumAmountToAccept given safeTotalStake and maxDuration
    function _maxMinimumAmount(uint256 safeTotalStake, uint256 maxDuration) internal pure returns (uint256) {
        return
            Penalty.addMaximumPenalty(VALIDATOR_STARTING_ETH, safeTotalStake, maxDuration / NUMBER_OF_SECONDS_IN_EPOCH);
    }

    // ========================================
    // CONSTRUCTOR TESTS
    // ========================================

    function test_Constructor_DeploysBondNft() public view {
        assertTrue(factory.I_COFFER_BOND_NFT_ADDRESS() != address(0), "NFT address should not be zero");
        assertEq(bondNft.name(), "Coffer Bond");
        assertEq(bondNft.symbol(), "CB");
    }

    // ========================================
    // HAPPY CASES — createCoffer
    // ========================================

    function test_CreateCoffer_Success_EmitsCofferIssued() public {
        vm.startPrank(validator);
        vm.recordLogs();

        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("CofferIssued(address,address)")) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), validator, "Owner indexed param mismatch");
                assertTrue(uint256(entries[i].topics[2]) != 0, "Coffer address should not be zero");
                found = true;
                break;
            }
        }
        assertTrue(found, "CofferIssued event not emitted");
        vm.stopPrank();
    }

    function test_CreateCoffer_Success_SetsOwner() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        Coffer c = Coffer(payable(cofferAddr));
        assertEq(c.owner(), validator, "Owner should be msg.sender");
    }

    function test_CreateCoffer_Success_SetsImmutables() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        Coffer c = Coffer(payable(cofferAddr));
        assertEq(c.iPublicKeyPart1(), validPublicKeyPart1);
        assertEq(c.iPublicKeyPart2(), validPublicKeyPart2);
        assertEq(c.iCofferBondNftAddress(), factory.I_COFFER_BOND_NFT_ADDRESS());
    }

    function test_CreateCoffer_Success_SetsValidatorConditions() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            false // exitAllowed = false → availableAmount = 0
        );

        _assertValidatorConditions(
            cofferAddr,
            0, // availableAmount
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            1, // version
            0, // outstandingBonds
            defaultSafeTotalStake,
            true, // isActive
            false // exitAllowed
        );
    }

    function test_CreateCoffer_Success_ExitAllowed_CalculatesAvailableAmount() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            true // exitAllowed
        );

        uint256 expectedAvailable = Penalty.addMaximumPenalty(
            VALIDATOR_STARTING_ETH, defaultSafeTotalStake, defaultMaxDuration / NUMBER_OF_SECONDS_IN_EPOCH
        );

        Coffer c = Coffer(payable(cofferAddr));
        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        assertEq(issueSize, expectedAvailable, "Issue size should match penalty calculation");
        assertTrue(expectedAvailable > 0, "Expected issue size should be positive for these params");
    }

    function test_CreateCoffer_Success_ExitNotAllowed_ZeroAvailableAmount() public {
        address cofferAddr = _createCofferAndGetAddress(
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

        Coffer c = Coffer(payable(cofferAddr));
        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        assertEq(issueSize, 0, "Issue size should be 0 when exitAllowed is false");
    }

    function test_CreateCoffer_Success_MultipleCoffers() public {
        address coffer1 = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        address coffer2 = _createCofferAndGetAddress(
            holder1, // different caller
            bytes32(uint256(99)),
            bytes16(uint128(100)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );

        assertTrue(coffer1 != address(0), "First coffer should be non-zero");
        assertTrue(coffer2 != address(0), "Second coffer should be non-zero");
        assertTrue(coffer1 != coffer2, "Coffers should have distinct addresses");
    }

    // ========================================
    // TRIGGER EVERY REVERT — createCoffer
    // ========================================

    function test_CreateCoffer_Revert_MinDurationZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            0, // _minimumDuration = 0
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_MaxDurationLessThanMin() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            ONE_YEAR, // min = 1 year
            ONE_MONTH, // max = 1 month < min
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_MaxDurationExceedsLimit() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            ONE_DAY,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32(MAX_DURATION) + 1, // exceeds 50-year cap
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_InterestRateZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidInterestRate.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            0, // _interestRate = 0
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_InterestRateExceedsMax() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidInterestRate.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            // forge-lint: disable-next-line(unsafe-typecast) MAX_RATE is a small constant that fits uint32
            uint32(MAX_RATE) + 1, // 1e8 + 1
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_MinAmountZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidMinimumValueToAccept.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            0, // _minimumAmountToAccept = 0
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_SafeTotalStakeZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidSafeTotalStake.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            0, // safeTotalStake = 0
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_SafeTotalStakeExceedsMax() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidSafeTotalStake.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            300_000_001, // exceeds 300_000_000 cap
            defaultExitAllowed
        );
    }

    function test_CreateCoffer_Revert_MinAmountExceedsMax() public {
        uint256 maxAllowed = _maxMinimumAmount(defaultSafeTotalStake, defaultMaxDuration);
        // Ensure maxAllowed is positive so the +1 actually exceeds it
        assertTrue(maxAllowed > 0, "maxAllowed should be positive for default params");

        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidMinimumValueToAccept.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            // forge-lint: disable-next-line(unsafe-typecast) maxAllowed derived from safe test params fits uint128
            uint128(maxAllowed) + 1,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
    }

    // ========================================
    // BOUNDARY / EDGE CASES
    // ========================================

    function test_CreateCoffer_Boundary_MinEqualsMaxDuration() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            ONE_MONTH, // min == max
            ONE_MONTH, // min == max
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        assertTrue(cofferAddr != address(0), "Should succeed when min == max duration");
    }

    function test_CreateCoffer_Boundary_ExactMaxDuration() public {
        // Use MAX_DURATION for both max and min (min must be > 0 and <= max)
        // With very long duration, penalty is large, so use a very small minimumAmount
        uint256 maxAllowed = _maxMinimumAmount(defaultSafeTotalStake, MAX_DURATION);
        // If maxAllowed is 0, the only way to create would fail on minAmount validation.
        // Use a small minAmount if possible, otherwise skip boundary check.
        if (maxAllowed > 0) {
            address cofferAddr = _createCofferAndGetAddress(
                validator,
                validPublicKeyPart1,
                validPublicKeyPart2,
                defaultInterestRate,
                1, // smallest valid min duration
                // forge-lint: disable-next-line(unsafe-typecast) MAX_DURATION is a small constant that fits uint32
                uint32(MAX_DURATION),
                1, // smallest valid amount
                defaultSafeTotalStake,
                defaultExitAllowed
            );
            assertTrue(cofferAddr != address(0), "Should succeed at exact MAX_DURATION");
        }
    }

    function test_CreateCoffer_Boundary_ExactMaxRate() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            // forge-lint: disable-next-line(unsafe-typecast) MAX_RATE is a small constant that fits uint32
            uint32(MAX_RATE), // exactly 1e8 = 100%
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        assertTrue(cofferAddr != address(0), "Should succeed at exact max rate");
    }

    function test_CreateCoffer_Boundary_MinRate() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            1, // smallest valid rate
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        assertTrue(cofferAddr != address(0), "Should succeed at min rate = 1");
    }

    function test_CreateCoffer_Boundary_ExactMaxMinimumAmount() public {
        uint256 maxAllowed = _maxMinimumAmount(defaultSafeTotalStake, defaultMaxDuration);
        assertTrue(maxAllowed > 0, "maxAllowed should be positive for default params");

        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            // forge-lint: disable-next-line(unsafe-typecast) maxAllowed derived from safe test params fits uint128
            uint128(maxAllowed), // exactly at the boundary
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        assertTrue(cofferAddr != address(0), "Should succeed at exact max minimum amount");
    }

    function test_CreateCoffer_Boundary_MinAmount() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            1, // smallest valid amount = 1 wei
            defaultSafeTotalStake,
            defaultExitAllowed
        );
        assertTrue(cofferAddr != address(0), "Should succeed at min amount = 1 wei");
    }
}
