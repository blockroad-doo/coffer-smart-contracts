//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Test, Vm} from "forge-std/Test.sol";
import {CofferFactory} from "../../../src/CofferFactory.sol";
import {Penalty} from "../../../src/libraries/Penalty.sol";

contract CofferFactoryHandler is Test {
    CofferFactory public factory;
    address[] public actors;

    uint256 private constant MAX_RATE = 1e8;
    uint256 private constant MAX_DURATION = 157_68_00_000; // 50 years
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;

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
        uint32 safeTotalStake,
        bool exitAllowed
    ) external {
        address actor = actors[actorSeed % actors.length];

        // Clamp rate
        rate = uint32(bound(uint256(rate), 1, MAX_RATE));

        // Clamp durations
        minDur = uint32(bound(uint256(minDur), 1, MAX_DURATION));
        maxDur = uint32(bound(uint256(maxDur), minDur, MAX_DURATION));

        // Clamp safeTotalStake
        safeTotalStake = uint32(bound(uint256(safeTotalStake), 1, 300_000_000));

        // Compute maxMinAmount
        uint256 maxMinAmount = Penalty.addMaximumPenalty(32 ether, safeTotalStake, maxDur / NUMBER_OF_SECONDS_IN_EPOCH);
        if (maxMinAmount == 0) return;

        // Clamp minAmount
        minAmount = uint128(bound(uint256(minAmount), 1, maxMinAmount));

        vm.recordLogs();
        vm.prank(actor);
        factory.createCoffer(pk1, pk2, rate, minDur, maxDur, minAmount, safeTotalStake, exitAllowed);

        // Extract deployed address from CofferIssued event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        address cofferAddress;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("CofferIssued(address,address)")) {
                cofferAddress = address(uint160(uint256(entries[i].topics[2])));
                break;
            }
        }

        ghostDeployedCoffers.push(cofferAddress);
        ++ghostDeploymentCount;
    }

    function handlerCreateCofferInvalid(
        uint256 actorSeed,
        bytes32 pk1,
        bytes16 pk2,
        uint32 rate,
        uint32 minDur,
        uint32 maxDur,
        uint128 minAmount,
        uint32 safeTotalStake,
        bool exitAllowed
    ) external {
        address actor = actors[actorSeed % actors.length];
        // Pass raw unclamped inputs — expected to revert
        vm.prank(actor);
        factory.createCoffer(pk1, pk2, rate, minDur, maxDur, minAmount, safeTotalStake, exitAllowed);
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
