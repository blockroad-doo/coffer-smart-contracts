//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";
import {CofferBondsRedeemedEarly} from "../../src/CofferBondsRedeemedEarly.sol";
import {FeeCurve} from "../../src/FeeCurve.sol";
import {EIP7002Mock, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, SYSTEM_ADDRESS} from "../mock/EIP7002Mock.sol";
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
    // TEST CONTRACTS AND ACCOUNTS
    // ========================================

    CofferFactory public factory;
    CofferBondNft public bondNft;
    CofferBondsRedeemedEarly public bondsRedeemedEarly;
    Coffer public coffer;
    FeeCurve public feeCurve;
    EIP7002Mock public withdrawalMock;
    EIP7251Mock public consolidationMock;

    // Test accounts
    address public validator = makeAddr("validator");
    address public holder1 = makeAddr("holder1");
    address public holder2 = makeAddr("holder2");
    address public holder3 = makeAddr("holder3");
    address public unauthorizedUser = makeAddr("unauthorized");
    address public feeRecipient = makeAddr("feeRecipient");

    // Valid test parameters
    bytes32 public validPublicKeyPart1 = bytes32(uint256(1));
    bytes16 public validPublicKeyPart2 = bytes16(uint128(2));
    uint32 public defaultInterestRate = MEDIUM_RATE; // 5%
    uint32 public defaultMinDuration = ONE_MONTH;
    uint32 public defaultMaxDuration = ONE_YEAR;
    uint128 public defaultMinimumAmount = 1 ether;
    uint16 public defaultIssueSizeBufferBps = 250; // 2.5% (1% = 100, denominator = 10000)
    uint128 public defaultStartingBalance = 32 ether;

    // ========================================
    // SETUP FUNCTIONS
    // ========================================

    function setUp() public virtual {
        // Deploy mocks at canonical addresses
        deployEip7002Mock();
        deployEip7251Mock();
        deployDepositContractMock();

        // Deploy factory (which deploys the shared NFT, FeeCurve, and Coffer implementation)
        factory = new CofferFactory(feeRecipient);

        // Get the NFT address and other deployed addresses from factory
        bondNft = CofferBondNft(factory.I_COFFER_BOND_NFT_ADDRESS());
        bondsRedeemedEarly = CofferBondsRedeemedEarly(factory.I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS());
        feeCurve = FeeCurve(factory.I_FEE_CURVE_ADDRESS());

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
            defaultIssueSizeBufferBps,
            defaultStartingBalance
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
        uint16 issueSizeBufferBps
    ) public returns (address) {
        return createCoffer(
            owner,
            pubKeyPart1,
            pubKeyPart2,
            interestRate,
            minDuration,
            maxDuration,
            minimumAmount,
            issueSizeBufferBps,
            defaultStartingBalance
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
        uint16 issueSizeBufferBps,
        uint128 startingBalance
    ) public returns (address) {
        address predicted = factory.predictCofferAddress(owner, pubKeyPart1, pubKeyPart2);
        vm.prank(owner);
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
        return predicted;
    }

    // ========================================
    // HELPER FUNCTIONS - BOND OPERATIONS
    // ========================================

    uint256 private bondIdCounter = 0;

    function getNextBondId() private returns (uint256) {
        return ++bondIdCounter;
    }

    function buyBond(address cofferAddr, address buyer, uint128 amount, uint32 duration, uint32 version)
        public
        returns (uint256)
    {
        Coffer targetCoffer = Coffer(payable(cofferAddr));

        // Track current supply before minting
        uint256 currentSupply = getNextBondId();

        vm.startPrank(buyer);
        targetCoffer.buyBond{value: amount}(duration, version);
        vm.stopPrank();

        return currentSupply;
    }

    // ========================================
    // HELPER FUNCTIONS - TIME MANIPULATION
    // ========================================

    function advanceTime(uint256 seconds_) public {
        vm.warp(block.timestamp + seconds_);
    }

    // ========================================
    // HELPER FUNCTIONS - ISSUE SIZE CALCULATION
    // ========================================

    function calculateExpectedIssueSize(uint256 startingBalance, uint256 issueSizeBufferBps)
        public
        pure
        returns (uint256)
    {
        uint256 denominator = 10000;
        return startingBalance * (denominator - issueSizeBufferBps) / denominator;
    }

    // ========================================
    // EIP7002 MOCK HELPER FUNCTIONS
    // ========================================

    /**
     * @dev Deploy and initialize the EIP7002Mock at the canonical address
     */
    function deployEip7002Mock() public {
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
    function deployEip7251Mock() public {
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
    function addWithdrawalRequest(bytes32 pubkeyPart1, bytes16 pubkeyPart2, uint64 amount, uint256 fee) public {
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
    function getQueueState() public view returns (uint256 excess, uint256 count, uint256 queueHead, uint256 queueTail) {
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
                or(
                    shl(8, byte(0, mload(add(ptr, 1)))),
                    or(
                        shl(16, byte(0, mload(add(ptr, 2)))),
                        or(
                            shl(24, byte(0, mload(add(ptr, 3)))),
                            or(
                                shl(32, byte(0, mload(add(ptr, 4)))),
                                or(
                                    shl(40, byte(0, mload(add(ptr, 5)))),
                                    or(shl(48, byte(0, mload(add(ptr, 6)))), shl(56, byte(0, mload(add(ptr, 7)))))
                                )
                            )
                        )
                    )
                )
            )
        }

        assertEq(source, expectedSource, "Source address mismatch");
        assertEq(pubkeyPart1, expectedPubkeyPart1, "Pubkey part 1 mismatch");
        assertEq(pubkeyPart2, expectedPubkeyPart2, "Pubkey part 2 mismatch");
        assertEq(amount, expectedAmount, "Amount mismatch");
    }
}

// Event interfaces for cleaner event emission expectations
interface CofferFactoryEvents {
    event CofferIssued(
        address indexed owner,
        address indexed cofferAddress,
        bytes32 indexed publicKeyPart1,
        bytes16 publicKeyPart2,
        uint32 interestRate,
        uint32 minimumDuration,
        uint32 maximumDuration,
        uint128 minimumValueToAccept,
        uint16 issueSizeBufferBps,
        uint128 issueSize
    );
}

interface CofferEvents {
    event BondBought(
        address indexed holderAddress,
        uint256 indexed bondId,
        uint128 indexed bondMaturityValue,
        uint32 duration,
        uint128 principal,
        uint32 interestRate
    );
    event BondFeePaid(uint256 indexed bondId, address indexed feeRecipient, uint128 indexed feeAmount, uint256 feeBps);
    event BondRedeemed(address indexed holderAddress, uint256 indexed bondId);
    event BondRedeemedPartially(
        address indexed holderAddress,
        uint256 indexed bondId,
        uint128 valueWithdrawn,
        uint128 remainingBondMaturityValue
    );
    event ValidatorsBondRedeem(address indexed holderAddress, uint256 indexed bondId);
    event ValidatorWithdrawFromExecution(uint128 indexed amount);
    event ValidatorWithdrawFromConsensus(uint128 indexed amount);
    event ValidatorFundsAdded(uint128 indexed amount);
    event CofferActivated();
    event CofferDeactivated();
    event ValidatorDefaulted(uint256 indexed bondId, address indexed caller);
    event ValidatorExitRequested(address indexed caller);
    event InterestRateChanged(uint32 indexed oldRate, uint32 indexed newRate);
    event DurationRangeChanged(uint32 indexed minimumDuration, uint32 indexed maximumDuration);
    event IssueSizeChanged(uint128 indexed newIssueSize);
    event MinimumValueChanged(uint128 indexed newMinimum);
    event IssueSizeBufferBpsChanged(uint16 indexed oldBuffer, uint16 indexed newBuffer);
    event ValidatorConvertedToCompounding();
}

interface CofferBondNftEvents {
    event CofferBondTokenMinted(uint256 indexed bondId, address indexed holder);
    event CofferBondTokenBurned(uint256 indexed bondId);
    event MetadataUpdate(uint256 _tokenId);
}

interface CofferBondsRedeemedEarlyEvents {
    event ClaimDeposited(address indexed holder, uint128 indexed amount);
    event ClaimWithdrawn(address indexed claimant, address indexed to, uint256 indexed amount);
}
