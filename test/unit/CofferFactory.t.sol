//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
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
    uint128 private constant DEFAULT_STARTING_BALANCE = 32 ether;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years

    // ========================================
    // DRY HELPERS
    // ========================================

    /// @dev Calls factory.createCoffer with given params, returns deployed address via predictCofferAddress
    function _createCofferAndGetAddress(
        address caller,
        bytes32 pubKeyPart1,
        bytes16 pubKeyPart2,
        uint32 interestRate,
        uint32 minDuration,
        uint32 maxDuration,
        uint128 minimumAmount,
        uint16 issueSizeBufferBps
    ) internal returns (address cofferAddr) {
        return _createCofferAndGetAddress(
            caller,
            pubKeyPart1,
            pubKeyPart2,
            interestRate,
            minDuration,
            maxDuration,
            minimumAmount,
            issueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
        );
    }

    /// @dev Overload with explicit startingBalance
    function _createCofferAndGetAddress(
        address caller,
        bytes32 pubKeyPart1,
        bytes16 pubKeyPart2,
        uint32 interestRate,
        uint32 minDuration,
        uint32 maxDuration,
        uint128 minimumAmount,
        uint16 issueSizeBufferBps,
        uint128 startingBalance
    ) internal returns (address cofferAddr) {
        cofferAddr = factory.predictCofferAddress(caller, pubKeyPart1, pubKeyPart2);
        vm.prank(caller);
        factory.createCoffer(
            pubKeyPart1,
            pubKeyPart2,
            interestRate,
            minDuration,
            maxDuration,
            minimumAmount,
            issueSizeBufferBps,
            startingBalance
        );
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
            uint16 issueSizeBufferBps,
            bool isActive,
            bool validatorDefaulted
        ) = c.sValidatorConditions();
        vc.issueSize = issueSize;
        vc.interestRate = interestRate;
        vc.minimumDuration = minimumDuration;
        vc.maximumDuration = maximumDuration;
        vc.minimumValueToAccept = minimumValueToAccept;
        vc.version = version;
        vc.outstandingBonds = outstandingBonds;
        vc.issueSizeBufferBps = issueSizeBufferBps;
        vc.isActive = isActive;
        vc.validatorDefaulted = validatorDefaulted;
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
        uint32 expectedIssueSizeBufferBps,
        bool expectedIsActive,
        bool expectedValidatorDefaulted
    ) internal view {
        Coffer.ValidatorConditions memory vc = _getValidatorConditions(cofferAddr);

        assertEq(vc.issueSize, expectedAvailable, "issueSize mismatch");
        assertEq(vc.interestRate, expectedRate, "interestRate mismatch");
        assertEq(vc.minimumDuration, expectedMinDuration, "minimumDuration mismatch");
        assertEq(vc.maximumDuration, expectedMaxDuration, "maximumDuration mismatch");
        assertEq(vc.minimumValueToAccept, expectedMinAmount, "minimumValueToAccept mismatch");
        assertEq(vc.version, expectedVersion, "version mismatch");
        assertEq(vc.outstandingBonds, expectedOutstandingBonds, "outstandingBonds mismatch");
        assertEq(vc.issueSizeBufferBps, expectedIssueSizeBufferBps, "issueSizeBufferBps mismatch");
        assertEq(vc.isActive, expectedIsActive, "isActive mismatch");
        assertEq(vc.validatorDefaulted, expectedValidatorDefaulted, "validatorDefaulted mismatch");
    }

    /// @dev Computes the dynamic max for _minimumAmountToAccept given startingBalance and issueSizeBufferBps
    function _maxMinimumAmount(uint256 startingBalance, uint256 issueSizeBufferBps) internal pure returns (uint256) {
        uint256 denominator = 10000;
        return startingBalance * (denominator - issueSizeBufferBps) / denominator;
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
    // HAPPY CASES: createCoffer
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0]
                    == keccak256(
                        "CofferIssued(address,address,bytes32,bytes16,uint32,uint32,uint32,uint128,uint16,uint128)"
                    )
            ) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), validator, "Owner indexed param mismatch");
                assertTrue(uint256(entries[i].topics[2]) != 0, "Coffer address should not be zero");
                assertEq(entries[i].topics[3], validPublicKeyPart1, "publicKeyPart1 indexed param mismatch");
                _assertCofferIssuedData(entries[i].data);
                found = true;
                break;
            }
        }
        assertTrue(found, "CofferIssued event not emitted");
        vm.stopPrank();
    }

    /// @dev Decodes the CofferIssued data payload and asserts every non-indexed field against the createCoffer inputs
    function _assertCofferIssuedData(bytes memory data) private view {
        (
            bytes16 publicKeyPart2,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,
            uint16 issueSizeBufferBps,
            uint128 issueSize
        ) = abi.decode(data, (bytes16, uint32, uint32, uint32, uint128, uint16, uint128));

        assertEq(bytes32(publicKeyPart2), bytes32(validPublicKeyPart2), "publicKeyPart2 mismatch");
        assertEq(interestRate, defaultInterestRate, "interestRate mismatch");
        assertEq(minimumDuration, defaultMinDuration, "minimumDuration mismatch");
        assertEq(maximumDuration, defaultMaxDuration, "maximumDuration mismatch");
        assertEq(minimumValueToAccept, defaultMinimumAmount, "minimumValueToAccept mismatch");
        assertEq(issueSizeBufferBps, defaultIssueSizeBufferBps, "issueSizeBufferBps mismatch");
        assertEq(
            issueSize,
            uint128(uint256(DEFAULT_STARTING_BALANCE) * (10000 - defaultIssueSizeBufferBps) / 10000),
            "issueSize mismatch"
        );
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
            defaultIssueSizeBufferBps
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
            defaultIssueSizeBufferBps
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
            defaultIssueSizeBufferBps
        );

        _assertValidatorConditions(
            cofferAddr,
            uint128(calculateExpectedIssueSize(DEFAULT_STARTING_BALANCE, defaultIssueSizeBufferBps)), // availableAmount
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            1, // version
            0, // outstandingBonds
            defaultIssueSizeBufferBps,
            true, // isActive
            false // validatorDefaulted
        );
    }

    function test_CreateCoffer_Success_IssueSizeNotReduced() public {
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );

        uint256 expectedAvailable = calculateExpectedIssueSize(DEFAULT_STARTING_BALANCE, defaultIssueSizeBufferBps);

        Coffer c = Coffer(payable(cofferAddr));
        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        assertEq(
            issueSize, expectedAvailable, "issueSize is the buffer-scaled starting balance (no 32 ETH floor deduction)"
        );
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
            defaultIssueSizeBufferBps
        );

        address coffer2 = _createCofferAndGetAddress(
            holder1, // different caller
            bytes32(uint256(99)),
            bytes16(uint128(100)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );

        assertTrue(coffer1 != address(0), "First coffer should be non-zero");
        assertTrue(coffer2 != address(0), "Second coffer should be non-zero");
        assertTrue(coffer1 != coffer2, "Coffers should have distinct addresses");
    }

    // ========================================
    // TRIGGER EVERY REVERT: createCoffer
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
        );
    }

    function test_CreateCoffer_Revert_IssueSizeBufferExceedsDenominator() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidIssueSizeBufferBps.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            10001, // exceeds BUFFER_DENOMINATOR (10000)
            DEFAULT_STARTING_BALANCE
        );
    }

    function test_CreateCoffer_Revert_IssueSizeBufferEqualsDenominator() public {
        //buffer == BUFFER_DENOMINATOR (100%) is now rejected; valid range is 0..9999.
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidIssueSizeBufferBps.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            10000, // == BUFFER_DENOMINATOR
            DEFAULT_STARTING_BALANCE
        );
    }

    function test_CreateCoffer_IssueSizeBufferMaxValid_9999_Succeeds() public {
        //9999 (BUFFER_DENOMINATOR - 1) is the maximum valid buffer and must still work.
        // minimumAmount = 1 keeps it within maxMinimumAmount (startingBalance * 1 / 10000) at a 99.99% buffer.
        vm.prank(validator);
        address clone = factory.createCoffer(
            bytes32(uint256(0x9999)),
            bytes16(uint128(0x9999)),
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            1,
            9999,
            DEFAULT_STARTING_BALANCE
        );
        assertTrue(clone != address(0), "createCoffer should succeed at buffer 9999");
        (,,,,,,, uint16 buffer,,) = Coffer(payable(clone)).sValidatorConditions();
        assertEq(buffer, 9999, "buffer stored as 9999");
    }

    function test_CreateCoffer_Revert_MinAmountExceedsMax() public {
        uint256 maxAllowed = _maxMinimumAmount(DEFAULT_STARTING_BALANCE, defaultIssueSizeBufferBps);
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
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
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
            defaultIssueSizeBufferBps
        );
        assertTrue(cofferAddr != address(0), "Should succeed when min == max duration");
    }

    function test_CreateCoffer_Boundary_ExactMaxDuration() public {
        // Use MAX_DURATION for both max and min (min must be > 0 and <= max).
        // A very long duration needs a small minimumAmount to stay under the initial issueSize.
        uint256 maxAllowed = _maxMinimumAmount(DEFAULT_STARTING_BALANCE, defaultIssueSizeBufferBps);
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
                defaultIssueSizeBufferBps
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
            defaultIssueSizeBufferBps
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
            defaultIssueSizeBufferBps
        );
        assertTrue(cofferAddr != address(0), "Should succeed at min rate = 1");
    }

    function test_CreateCoffer_Boundary_ExactMaxMinimumAmount() public {
        uint256 maxAllowed = _maxMinimumAmount(DEFAULT_STARTING_BALANCE, defaultIssueSizeBufferBps);
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
            defaultIssueSizeBufferBps
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
            defaultIssueSizeBufferBps
        );
        assertTrue(cofferAddr != address(0), "Should succeed at min amount = 1 wei");
    }

    // ========================================
    // CREATE2 DETERMINISTIC DEPLOYMENT TESTS
    // ========================================

    function test_PredictCofferAddress_MatchesDeployedAddress() public {
        address predicted = factory.predictCofferAddress(validator, validPublicKeyPart1, validPublicKeyPart2);

        address deployed = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );

        assertEq(predicted, deployed, "Predicted address should match deployed address");
    }

    function test_PredictCofferAddress_DifferentOwners_DifferentAddresses() public {
        address addr1 = factory.predictCofferAddress(validator, validPublicKeyPart1, validPublicKeyPart2);
        address addr2 = factory.predictCofferAddress(holder1, validPublicKeyPart1, validPublicKeyPart2);

        assertTrue(addr1 != addr2, "Different owners should produce different addresses");
    }

    function test_PredictCofferAddress_DifferentPubKeys_DifferentAddresses() public {
        address addr1 = factory.predictCofferAddress(validator, validPublicKeyPart1, validPublicKeyPart2);
        address addr2 = factory.predictCofferAddress(validator, bytes32(uint256(99)), bytes16(uint128(100)));

        assertTrue(addr1 != addr2, "Different pubkeys should produce different addresses");
    }

    function test_CreateCoffer_Revert_DuplicateDeployment() public {
        _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );

        // Second deployment with same sender + pubkey should revert
        vm.prank(validator);
        vm.expectRevert();
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            DEFAULT_STARTING_BALANCE
        );
    }

    // ========================================
    // STARTING BALANCE TESTS
    // ========================================

    function test_CreateCoffer_Revert_StartingBalanceZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidStartingBalance.selector);
        factory.createCoffer(
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            0 // zero starting balance is rejected
        );
    }

    function test_CreateCoffer_Success_StartingBalanceAboveOldMax() public {
        uint128 largeBalance = 5000 ether; // above the former 2048 ETH cap, now allowed
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            largeBalance
        );

        uint256 expected = calculateExpectedIssueSize(largeBalance, defaultIssueSizeBufferBps);
        Coffer c = Coffer(payable(cofferAddr));
        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();
        assertEq(issueSize, expected, "issueSize scales with starting balance above the former 2048 ETH cap");
    }

    function test_CreateCoffer_Success_CustomStartingBalance() public {
        uint128 customBalance = 64 ether;
        address cofferAddr = _createCofferAndGetAddress(
            validator,
            validPublicKeyPart1,
            validPublicKeyPart2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps,
            customBalance
        );

        uint256 expectedWith32 = calculateExpectedIssueSize(32 ether, defaultIssueSizeBufferBps);
        uint256 expectedWith64 = calculateExpectedIssueSize(customBalance, defaultIssueSizeBufferBps);

        Coffer c = Coffer(payable(cofferAddr));
        (uint128 issueSize,,,,,,,,,) = c.sValidatorConditions();

        assertEq(issueSize, expectedWith64, "Issue size should use custom starting balance");
        assertGt(expectedWith64, expectedWith32, "64 ETH should produce larger issue size than 32 ETH");
    }
}
