//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";
import {Interest} from "../../src/libraries/Interest.sol";
import {Penalty} from "../../src/libraries/Penalty.sol";
import {EIP7002Mock, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, SYSTEM_ADDRESS, EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";
import {EIP7251Mock, CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS} from "../mock/EIP7251Mock.sol";

/**
 * @title BaseTest
 * @notice Base contract for all Coffer tests following DRY principles
 * @dev Contains common setup, helper functions, and constants for test consistency
 */
abstract contract BaseTest is Test {
    // ========================================
    // REALISTIC TEST CONSTANTS
    // ========================================

    // Realistic amount boundaries (in ETH)
    uint128 constant MIN_AMOUNT = 0.01 ether;
    uint128 constant SMALL_AMOUNT = 1 ether;
    uint128 constant MEDIUM_AMOUNT = 32 ether;
    uint128 constant LARGE_AMOUNT = 1000 ether;
    uint128 constant MAX_REALISTIC_AMOUNT = 1_000_000 ether; // 1 million ETH max

    // Realistic duration boundaries (in seconds)
    uint32 constant ONE_DAY = 86_400;
    uint32 constant ONE_WEEK = 604_800;
    uint32 constant ONE_MONTH = 2_629_746; // ~30.44 days
    uint32 constant SIX_MONTHS = 15_778_476;
    uint32 constant ONE_YEAR = 31_536_000;
    uint32 constant FIVE_YEARS = 157_680_000;
    uint32 constant MAX_REALISTIC_DURATION = 315_360_000; // 10 years - safe maximum to avoid penalty overflow

    // Interest rate constants (using 1e8 divisor)
    uint32 constant RATE_DIVISOR = 1e8;
    uint32 constant MIN_RATE = 1e6; // 1%
    uint32 constant LOW_RATE = 3e6; // 3%
    uint32 constant MEDIUM_RATE = 5e6; // 5%
    uint32 constant HIGH_RATE = 1e8; // 100%

    // ========================================
    // ERROR MESSAGES
    // ========================================

    // Coffer errors
    string constant ERROR_ZERO_AMOUNT = "ZeroAmount()";
    string constant ERROR_AMOUNT_TOO_SMALL = "AmountTooSmallToAccept()";
    string constant ERROR_INVALID_DURATION = "InvalidDuration()";
    string constant ERROR_INVALID_RATE = "InvalidRate()";
    string constant ERROR_VALIDATOR_NOT_ACTIVE = "ValidatorIsNotActive()";
    string constant ERROR_VALIDATOR_HAS_UNREPAID = "ValidatorHasUnrepaidBonds()";
    string constant ERROR_VERSION_MISMATCH = "ValidatorConditionsVersionMismatch()";
    string constant ERROR_INSUFFICIENT_AVAILABLE = "ValidatorDoesNotHaveEnoughAvailableAmount()";
    string constant ERROR_CONSENSUS_WITHDRAW_NOT_POSSIBLE =
        "HolderConsensusWithdrawNotPossibleContractHasEnoughBalance()";
    string constant ERROR_HOLDER_DOES_NOT_EXIST = "HolderDoesNotExistOrAlreadyWithdrawnAmount()";
    string constant ERROR_TIME_NOT_EXPIRED = "HoldersTimeHasNotExpiredYet()";
    string constant ERROR_HOLDER_CANNOT_BE_VALIDATOR = "HolderCannotBeValidator()";
    string constant ERROR_NOT_HOLDER = "CallerIsNotHolder()";
    string constant ERROR_INSUFFICIENT_BALANCE = "ContractBalanceLessThanAmount()";
    string constant ERROR_SEND_FAILED = "SendAmountFailed()";
    string constant ERROR_PRECOMPILE_FAILED = "PrecompileFailed()";
    string constant ERROR_INSUFFICIENT_PRECOMPILE_FEE = "InsufficientPrecompileFee()";

    // CofferFactory errors
    string constant ERROR_FACTORY_INVALID_DURATION = "InvalidDuration()";
    string constant ERROR_FACTORY_INVALID_RATE = "InvalidInterestRate()";
    string constant ERROR_FACTORY_INVALID_MIN_AMOUNT = "InvalidMinimumAmountToAccept()";

    // CofferBondNft errors
    string constant ERROR_TOKEN_DOES_NOT_EXIST = "TokenDoesNotExist()";
    string constant ERROR_UNAUTHORIZED_MINTER = "UnauthorizedMinter()";

    // ========================================
    // TEST CONTRACTS AND ACCOUNTS
    // ========================================

    CofferFactory public factory;
    CofferBondNft public bondNft;
    Coffer public coffer;
    EIP7002Mock public withdrawalMock;
    EIP7251Mock public consolidationMock;

    // Test accounts
    address public validator = makeAddr("validator");
    address public holder1 = makeAddr("holder1");
    address public holder2 = makeAddr("holder2");
    address public holder3 = makeAddr("holder3");
    address public unauthorizedUser = makeAddr("unauthorized");

    // Valid test parameters
    bytes32 public validPublicKeyPart1 = bytes32(uint256(1));
    bytes16 public validPublicKeyPart2 = bytes16(uint128(2));
    uint32 public defaultInterestRate = MEDIUM_RATE; // 5%
    uint32 public defaultMinDuration = ONE_MONTH;
    uint32 public defaultMaxDuration = ONE_YEAR;
    uint128 public defaultMinimumAmount = 1 ether;
    uint32 public defaultSafeTotalStake = 20_000_000; // 20M ETH as default total stake
    bool public defaultExitAllowed = false;

    // ========================================
    // SETUP FUNCTIONS
    // ========================================

    function setUp() public virtual {
        // Deploy mocks at canonical addresses
        deployEIP7002Mock();
        deployEIP7251Mock();
        deployDepositContractMock();

        // Deploy factory (which deploys the shared NFT)
        factory = new CofferFactory();

        // Get the NFT address from factory
        bondNft = CofferBondNft(factory.I_COFFER_BOND_NFT_ADDRESS());

        // Fund test accounts
        vm.deal(validator, 1000 ether);
        vm.deal(holder1, 1000 ether);
        vm.deal(holder2, 1000 ether);
        vm.deal(holder3, 1000 ether);
    }

    // ========================================
    // HELPER FUNCTIONS - COFFER CREATION
    // ========================================

    function createDefaultCoffer() public returns (address) {
        return createCoffer(
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
    }

    function createCoffer(
        address owner,
        bytes32 pubKeyPart1,
        bytes16 pubKeyPart2,
        uint32 interestRate,
        uint32 minDuration,
        uint32 maxDuration,
        uint128 minimumAmount,
        uint32 safeTotalStake,
        bool exitAllowed
    ) public returns (address) {
        vm.startPrank(owner);

        // Record logs before the call
        vm.recordLogs();

        factory.createCoffer(
            pubKeyPart1,
            pubKeyPart2,
            interestRate,
            minDuration,
            maxDuration,
            minimumAmount,
            safeTotalStake,
            exitAllowed
        );

        // Get the deployed coffer address from the recorded logs
        Vm.Log[] memory entries = vm.getRecordedLogs();
        address cofferAddress;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("CofferIssued(address,address)")) {
                cofferAddress = address(uint160(uint256(entries[i].topics[2])));
                break;
            }
        }

        vm.stopPrank();

        return cofferAddress;
    }

    // ========================================
    // HELPER FUNCTIONS - BOND OPERATIONS
    // ========================================

    uint256 private holderIdCounter = 0;

    function getNextHolderId() private returns (uint256) {
        return ++holderIdCounter;
    }

    function buyBond(address cofferAddr, address buyer, uint128 amount, uint32 duration, uint32 version)
        public
        returns (uint256)
    {
        Coffer targetCoffer = Coffer(payable(cofferAddr));

        // Track current supply before minting
        uint256 currentSupply = getNextHolderId();

        vm.startPrank(buyer);
        targetCoffer.buyBond{value: amount}(duration, version);
        vm.stopPrank();

        return currentSupply;
    }

    function buyBondExpectRevert(
        address cofferAddr,
        address buyer,
        uint128 amount,
        uint32 duration,
        uint32 version,
        bytes memory expectedError
    ) public {
        Coffer targetCoffer = Coffer(payable(cofferAddr));

        vm.startPrank(buyer);
        vm.expectRevert(expectedError);
        targetCoffer.buyBond{value: amount}(duration, version);
        vm.stopPrank();
    }

    // ========================================
    // HELPER FUNCTIONS - TIME MANIPULATION
    // ========================================

    function advanceTime(uint256 seconds_) public {
        vm.warp(block.timestamp + seconds_);
    }

    function advanceTimeAndBlock(uint256 seconds_) public {
        advanceTime(seconds_);
        vm.roll(block.number + 1);
    }

    // ========================================
    // HELPER FUNCTIONS - BALANCE CHECKS
    // ========================================

    function getBalance(address account) public view returns (uint256) {
        return account.balance;
    }

    function assertBalance(address account, uint256 expected) public {
        assertEq(account.balance, expected, "Balance mismatch");
    }

    // ========================================
    // HELPER FUNCTIONS - STATE ASSERTIONS
    // ========================================

    function assertValidatorConditions(
        address cofferAddr,
        uint128 expectedAvailable,
        uint32 expectedUnrepaid,
        bool expectedActive
    ) public {
        Coffer targetCoffer = Coffer(payable(cofferAddr));
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            uint32 unrepaidBonds,
            uint32 safeTotalStake,
            bool isActive,
            bool exitAllowed
        ) = targetCoffer.s_validatorConditions();

        assertEq(availableAmount, expectedAvailable, "Available amount mismatch");
        assertEq(unrepaidBonds, expectedUnrepaid, "Unrepaid bonds mismatch");
        assertEq(isActive, expectedActive, "Active status mismatch");
    }

    function assertHolderConditions(
        address cofferAddr,
        uint256 holderId,
        uint128 expectedAmount,
        uint32 expectedDuration
    ) public {
        Coffer targetCoffer = Coffer(payable(cofferAddr));
        (uint128 amount, uint64 duration, uint64 startTimestamp) = targetCoffer.s_holderConditions(holderId);

        assertEq(amount, expectedAmount, "Holder amount mismatch");
        assertEq(duration, expectedDuration, "Holder duration mismatch");
        assertTrue(startTimestamp > 0, "Start timestamp not set");
    }

    // ========================================
    // HELPER FUNCTIONS - INTEREST CALCULATION
    // ========================================

    function calculateExpectedInterest(uint128 amount, uint32 duration, uint32 rate) public pure returns (uint128) {
        return Interest.calculateInterest(amount, duration, rate);
    }

    // ========================================
    // HELPER FUNCTIONS - PENALTY CALCULATION
    // ========================================

    function calculateExpectedAvailableAmount(uint32 safeTotalStake, uint32 maxDuration) public pure returns (uint128) {
        uint128 slashingPenalty = Penalty.slashing(32 ether, safeTotalStake);
        // Convert duration in seconds to epochs (384 seconds per epoch)
        uint32 epochs = maxDuration / 384;
        uint128 attestationPenalty = Penalty.missingAttestations(32 ether, safeTotalStake, epochs);
        return 32 ether - (slashingPenalty + attestationPenalty);
    }

    // ========================================
    // HELPER FUNCTIONS - EVENT ASSERTIONS
    // ========================================

    function expectHolderAcceptedOfferEvent(
        address holder,
        uint256 holderId,
        uint128 amount,
        uint32 duration,
        uint128 amountWithInterest
    ) public {
        vm.expectEmit(true, true, false, true);
        emit CofferEvents.HolderAcceptedOffer(holder, holderId, amount, duration, amountWithInterest);
    }

    // ========================================
    // EIP7002 MOCK HELPER FUNCTIONS
    // ========================================

    /**
     * @dev Deploy and initialize the EIP7002Mock at the canonical address
     */
    function deployEIP7002Mock() public {
        // Deploy the mock
        withdrawalMock = new EIP7002Mock();

        // Use vm.etch to place the code at the canonical address
        vm.etch(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, address(withdrawalMock).code);

        // Initialize storage to avoid EXCESS_INHIBITOR revert
        // Set excess to 0 (slot 0)
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));
    }

    /**
     * @dev Deploy and initialize the EIP7251Mock at the canonical address
     */
    function deployEIP7251Mock() public {
        consolidationMock = new EIP7251Mock();
        vm.etch(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, address(consolidationMock).code);
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));
    }

    /**
     * @dev Deploy DepositContract (solc 0.6.11) at the canonical address via deployCode
     */
    function deployDepositContractMock() public {
        address canonical = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
        address temp = deployCode("DepositContract.sol:DepositContract");
        vm.etch(canonical, temp.code);
        for (uint256 i = 0; i < 65; i++) {
            bytes32 val = vm.load(temp, bytes32(i));
            vm.store(canonical, bytes32(i), val);
        }
    }

    /**
     * @dev Get the current withdrawal request fee from the mock
     */
    function getWithdrawalFee() public view returns (uint256) {
        (bool success, bytes memory data) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.staticcall("");
        require(success, "Failed to get fee");
        return abi.decode(data, (uint256));
    }

    /**
     * @dev Get the current consolidation request fee from the mock
     */
    function getConsolidationFee() public view returns (uint256) {
        (bool success, bytes memory data) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.staticcall("");
        require(success, "Failed to get consolidation fee");
        return abi.decode(data, (uint256));
    }

    /**
     * @dev Helper to add a withdrawal request
     */
    function addWithdrawalRequest(
        bytes32 pubkeyPart1,
        bytes16 pubkeyPart2,
        uint64 amount,
        uint256 fee
    ) public {
        bytes memory data = abi.encodePacked(pubkeyPart1, pubkeyPart2, amount);
        (bool success,) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        require(success, "Failed to add withdrawal request");
    }

    /**
     * @dev Trigger system call to dequeue requests (must be called from SYSTEM_ADDRESS)
     */
    function triggerSystemCall() public returns (bytes memory) {
        vm.prank(SYSTEM_ADDRESS);
        (bool success, bytes memory data) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call("");
        require(success, "System call failed");
        return data;
    }

    /**
     * @dev Get current queue state from mock
     */
    function getQueueState() public view returns (
        uint256 excess,
        uint256 count,
        uint256 queueHead,
        uint256 queueTail
    ) {
        excess = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).getExcess();
        count = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).getCount();
        queueHead = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).getQueueHead();
        queueTail = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).getQueueTail();
    }

    /**
     * @dev Assert withdrawal request data matches expected values
     */
    function assertWithdrawalRequest(
        bytes memory returnData,
        uint256 index,
        address expectedSource,
        bytes32 expectedPubkeyPart1,
        bytes16 expectedPubkeyPart2,
        uint64 expectedAmount
    ) public {
        uint256 offset = index * 76;

        // Extract source address (20 bytes)
        address source;
        assembly {
            source := shr(96, mload(add(add(returnData, 0x20), offset)))
        }

        // Extract pubkey parts
        bytes32 pubkeyPart1;
        bytes16 pubkeyPart2;
        assembly {
            pubkeyPart1 := mload(add(add(returnData, 0x34), offset)) // offset + 20
            // Load from offset + 52: returnData starts at 0x20, so 0x20 + 52 = 0x54
            let temp := mload(add(add(returnData, 0x54), offset))
            pubkeyPart2 := temp // bytes16 cast takes the first 16 bytes
        }

        // Extract amount (little-endian, 8 bytes at offset + 68)
        uint64 amount;
        assembly {
            let ptr := add(add(returnData, 0x20), add(offset, 68))
            amount := or(
                byte(0, mload(ptr)),
                or(shl(8, byte(0, mload(add(ptr, 1)))),
                or(shl(16, byte(0, mload(add(ptr, 2)))),
                or(shl(24, byte(0, mload(add(ptr, 3)))),
                or(shl(32, byte(0, mload(add(ptr, 4)))),
                or(shl(40, byte(0, mload(add(ptr, 5)))),
                or(shl(48, byte(0, mload(add(ptr, 6)))),
                   shl(56, byte(0, mload(add(ptr, 7)))))))))))
        }

        assertEq(source, expectedSource, "Source address mismatch");
        assertEq(pubkeyPart1, expectedPubkeyPart1, "Pubkey part 1 mismatch");
        assertEq(pubkeyPart2, expectedPubkeyPart2, "Pubkey part 2 mismatch");
        assertEq(amount, expectedAmount, "Amount mismatch");
    }
}

// Event interfaces for cleaner event emission expectations
interface CofferFactoryEvents {
    event CofferIssued(address indexed owner, address indexed cofferAddress);
}

interface CofferEvents {
    event HolderAcceptedOffer(
        address indexed holderAddress,
        uint256 indexed holderId,
        uint128 amount,
        uint32 duration,
        uint128 amountWithInterest
    );
    event HolderWithdrawFromExecutionSuccess(address indexed holderAddress, uint256 indexed holderId);
    event HolderWithdrawFromConsensusSuccess(
        address indexed holderAddress, uint256 indexed holderId, uint128 amount, bool isFullExit
    );
    event ValidatorsBondRedeem(address indexed holderAddress, uint256 indexed holderId, uint128 amountOwed);
    event ValidatorWithdrawFromExecution(uint128 amount);
    event ValidatorWithdrawFromConsensus(uint128 amount);
    event ValidatorFundsAdded(uint128 amount);
    event CofferActivated();
    event CofferDeactivated();
    event CofferAllowsHolderToExit();
    event CofferForbidsHolderToExit();
    event InterestRateChanged(uint32 oldRate, uint32 newRate);
    event DurationRangeChanged(uint32 minimumDuration, uint32 maximumDuration);
    event AvailableAmountChanged(uint128 oldAmount, uint128 newAmount);
    event MinimumAmountChanged(uint128 newMinimum);
    event SafeTotalStakeChanged(uint32 oldSafeTotalStake, uint32 newSafeTotalStake);
    event ValidatorConvertedToCompounding();
}

interface CofferBondNftEvents {
    event CofferBondTokenMinted(uint256 indexed holderId, address indexed holder);
    event CofferBondTokenBurned(uint256 indexed holderId);
}
