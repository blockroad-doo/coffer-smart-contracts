//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title CofferFactory
 * @notice Factory contract for creating validator offers aka Coffers
 * @notice Deploys shared NFT contract CofferBondNft
 * @author Coffer Team
 * @dev This contract manages the deployment of individual Coffer contracts and shared NFT management
 */
import {Coffer} from "./Coffer.sol";
import {CofferBondNft} from "./CofferBondNft.sol";
import {Penalty} from "./libraries/Penalty.sol";

contract CofferFactory {
    error InvalidDuration();
    error InvalidInterestRate();
    error InvalidMinimumAmountToAccept();

    uint32 private constant MAX_RATE = 1e8; // Represents 100% interest rate, so 1e6 is 1%
    uint128 private constant VALIDATOR_STARTING_ETH = 32 ether;
    uint32 private constant MAX_DURATION = 157_68_00_000; // 50 years
    uint16 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;

    address public immutable I_COFFER_BOND_NFT_ADDRESS;

    event CofferIssued(address indexed owner, address indexed cofferAddress);

    constructor() {
        CofferBondNft iCofferBondNft = new CofferBondNft();
        I_COFFER_BOND_NFT_ADDRESS = address(iCofferBondNft);
    }

    function createCoffer(
        bytes32 _publicKeyPart1,
        bytes16 _publicKeyPart2,
        uint32 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _minimumAmountToAccept,
        uint32 _safeTotalStake,
        bool _exitAllowed
    ) external {
        if (
            _maximumDuration < _minimumDuration ||
            _maximumDuration > MAX_DURATION ||
            _minimumDuration == 0
        ) {
            revert InvalidDuration();
        }
        if (_interestRate == 0 || _interestRate > MAX_RATE)
            revert InvalidInterestRate();

        // validator cannot set minimum amount to accept more that maximum it could accept
        uint128 maxMinimumAmountToAccept = Penalty.addMaximumPenalty(
            VALIDATOR_STARTING_ETH,
            _safeTotalStake,
            _maximumDuration / NUMBER_OF_SECONDS_IN_EPOCH
        );

        if (
            _minimumAmountToAccept == 0 ||
            _minimumAmountToAccept > maxMinimumAmountToAccept
        ) {
            revert InvalidMinimumAmountToAccept();
        }

        Coffer newCoffer = new Coffer(
            msg.sender,
            I_COFFER_BOND_NFT_ADDRESS,
            _publicKeyPart1,
            _publicKeyPart2,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _minimumAmountToAccept,
            _safeTotalStake,
            _exitAllowed
        );

        emit CofferIssued(msg.sender, address(newCoffer));
    }
}
