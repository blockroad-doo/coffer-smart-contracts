// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {CofferFactory} from "../../src/CofferFactory.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferReceivableNFT} from "../../src/CofferReceivableNFT.sol";

contract CofferFactoryTest is Test {
    CofferFactory public factory;
    CofferReceivableNFT public nft;

    address public validator = makeAddr("validator");
    address public holder = makeAddr("holder");

    // Valid default parameters
    bytes32 public constant VALID_PK_PART1 = bytes32(uint256(1));
    bytes16 public constant VALID_PK_PART2 = bytes16(uint128(1));
    uint256 public constant VALID_MAX_SLASHING = 1 ether;
    uint256 public constant VALID_INTEREST_RATE = 1e17; // 10%
    uint256 public constant VALID_MIN_DURATION = 30 days;
    uint256 public constant VALID_MAX_DURATION = 365 days;
    uint256 public constant VALID_AVAILABLE_AMOUNT = 32 ether;
    uint256 public constant VALID_MIN_AMOUNT = 1 ether;
    //uint256 public constant VALID_RETURN_RATE = 1e18; // 100%
    uint256 public constant MAX_RATE = 1e18;

    // Events
    event CofferCreated(address indexed validator, uint256 availableAmount, uint256 interestRate);

    function setUp() public {
        factory = new CofferFactory();
        // Get the NFT contract deployed by the factory
        nft = CofferReceivableNFT(factory.getCofferReceivableNFTAddress());
    }

    function test_CreateCoffer_HasCorrectValidatorConditions() public {
        vm.prank(validator);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            VALID_MIN_DURATION,
            VALID_MAX_DURATION,
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );

        address cofferAddress = factory.getCofferAddress(validator);
        Coffer coffer = Coffer(payable(cofferAddress));

        (
            bool isActive,
            uint256 maxSlashing,
            uint256 interestRate,
            uint256 minDuration,
            uint256 maxDuration,
            uint256 availableAmount,
            uint256 startingAmount,
            uint256 minAmount //,
                //uint256 returnRate
                //bool exitAllowed
        ) = coffer.getValidatorConditions();

        assertTrue(isActive, "Should be active");
        assertEq(maxSlashing, VALID_MAX_SLASHING, "Max slashing incorrect");
        assertEq(interestRate, VALID_INTEREST_RATE, "Interest rate incorrect");
        assertEq(minDuration, VALID_MIN_DURATION, "Min duration incorrect");
        assertEq(maxDuration, VALID_MAX_DURATION, "Max duration incorrect");
        assertEq(availableAmount, VALID_AVAILABLE_AMOUNT, "Available amount incorrect");
        assertEq(startingAmount, VALID_AVAILABLE_AMOUNT, "Starting amount incorrect");
        assertEq(minAmount, VALID_MIN_AMOUNT, "Min amount incorrect");
        //assertEq(returnRate, VALID_RETURN_RATE, "Return rate incorrect");
        //assertEq(exitAllowed, "Should be allowed");
    }

    function test_CreateCoffer_RevertsWhenMinimumDurationIsZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            0, // minimumDuration = 0
            VALID_MAX_DURATION,
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );
    }

    function test_CreateCoffer_RevertsWhenMaxDurationLessThanMinDuration() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidDuration.selector);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            365 days,
            30 days, // maxDuration < minDuration
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );
    }

    function test_CreateCoffer_RevertsWhenInterestRateGreaterThanMaxRate() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidInterestRate.selector);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            MAX_RATE + 1, // interestRate > MAX_RATE
            VALID_MIN_DURATION,
            VALID_MAX_DURATION,
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );
    }

    function test_CreateCoffer_RevertsWhenAvailableAmountLessThanMinAmount() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.MinimumAmountToAcceptGreaterThanAvailableAmount.selector);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            VALID_MIN_DURATION,
            VALID_MAX_DURATION,
            1 ether, // availableAmount
            2 ether //, // minimumAmountToAccept > availableAmount
                //VALID_RETURN_RATE,
                //true
        );
    }

    function test_CreateCoffer_RevertsWhenPublicKeyIsZero() public {
        vm.prank(validator);
        vm.expectRevert(CofferFactory.InvalidConsensusPublicKeyLength.selector);
        factory.createCoffer(
            bytes32(0), // Invalid public key part 1
            bytes16(0), // Invalid public key part 2
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            VALID_MIN_DURATION,
            VALID_MAX_DURATION,
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );
    }

    function test_CreateCoffer_CreatedCofferCanAcceptOffers() public {
        // Create coffer
        vm.prank(validator);
        factory.createCoffer(
            VALID_PK_PART1,
            VALID_PK_PART2,
            address(nft),
            VALID_MAX_SLASHING,
            VALID_INTEREST_RATE,
            VALID_MIN_DURATION,
            VALID_MAX_DURATION,
            VALID_AVAILABLE_AMOUNT,
            VALID_MIN_AMOUNT //,
                //VALID_RETURN_RATE,
                //true
        );

        address cofferAddress = factory.getCofferAddress(validator);
        Coffer coffer = Coffer(payable(cofferAddress));

        // Fund holder and accept offer
        vm.deal(holder, 10 ether);

        vm.prank(holder);
        coffer.acceptOffer{value: 2 ether}(VALID_MIN_DURATION);

        // Verify holder received NFT (tokenId 0 since it's the first mint)
        assertEq(nft.ownerOf(0), holder, "Holder should own the NFT");
    }
}
