//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferFactory} from "../../../src/CofferFactory.sol";

contract CofferFactoryHandler is Test {
    CofferFactory public factory;
    address[] public actors;

    uint256 private constant MAX_RATE = 1e8;
    uint256 private constant MAX_DURATION = 157_68_00_000; // 50 years
    uint256 private constant BUFFER_DENOMINATOR = 10000;

    // Ghost state
    address[] public ghostDeployedCoffers;
    uint256 public ghostDeploymentCount;

    constructor(CofferFactory _factory) {
        factory = _factory;
        actors.push(makeAddr("factoryActor0"));
        actors.push(makeAddr("factoryActor1"));
        actors.push(makeAddr("factoryActor2"));
        actors.push(makeAddr("factoryActor3"));
        actors.push(makeAddr("factoryActor4"));
    }

    function handlerCreateCoffer(
        uint256 actorSeed,
        bytes32 pk1,
        bytes16 pk2,
        uint32 rate,
        uint32 minDur,
        uint32 maxDur,
        uint128 minAmount,
        uint16 issueSizeBufferBps,
        bool exitAllowed,
        uint128 startingBalance
    ) external {
        address actor = actors[actorSeed % actors.length];

        // Clamp rate
        rate = uint32(bound(uint256(rate), 1, MAX_RATE));

        // Clamp durations
        minDur = uint32(bound(uint256(minDur), 1, MAX_DURATION));
        maxDur = uint32(bound(uint256(maxDur), minDur, MAX_DURATION));

        // Clamp issueSizeBufferBps
        issueSizeBufferBps = uint16(bound(uint256(issueSizeBufferBps), 0, BUFFER_DENOMINATOR));

        // Clamp startingBalance to EIP-7251 range
        startingBalance = uint128(bound(uint256(startingBalance), 32 ether, 2048 ether));

        // Compute maxMinAmount
        uint256 maxMinAmount = uint256(startingBalance) * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR;
        if (maxMinAmount == 0) return;

        // Clamp minAmount
        minAmount = uint128(bound(uint256(minAmount), 1, maxMinAmount));

        // Use predictCofferAddress and try/catch for duplicate salt reverts
        address predicted = factory.predictCofferAddress(actor, pk1, pk2);
        vm.prank(actor);
        try factory.createCoffer(
            pk1, pk2, rate, minDur, maxDur, minAmount, issueSizeBufferBps, exitAllowed, startingBalance
        ) {
            ghostDeployedCoffers.push(predicted);
            ++ghostDeploymentCount;
        } catch {
            // Duplicate (actor, pk1, pk2): skip
        }
    }

    function handlerCreateCofferInvalid(
        uint256 actorSeed,
        bytes32 pk1,
        bytes16 pk2,
        uint32 rate,
        uint32 minDur,
        uint32 maxDur,
        uint128 minAmount,
        uint16 issueSizeBufferBps,
        bool exitAllowed,
        uint128 startingBalance
    ) external {
        address actor = actors[actorSeed % actors.length];
        // Pass raw unclamped inputs: expected to revert
        vm.prank(actor);
        factory.createCoffer(
            pk1, pk2, rate, minDur, maxDur, minAmount, issueSizeBufferBps, exitAllowed, startingBalance
        );
        // Ghost state NOT updated
    }

    // Helper views
    function getDeployedCoffersLength() external view returns (uint256) {
        return ghostDeployedCoffers.length;
    }

    function getDeployedCofferAt(uint256 index) external view returns (address) {
        return ghostDeployedCoffers[index];
    }
}
