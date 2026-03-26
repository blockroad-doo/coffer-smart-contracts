//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Coffer} from "./Coffer.sol";
import {CofferBondNft} from "./CofferBondNft.sol";
import {CofferBondsRedeemedEarly} from "./CofferBondsRedeemedEarly.sol";
import {Penalty} from "./libraries/Penalty.sol";

/**
 * @title CofferFactory
 * @notice Factory contract for creating validator offers aka Coffers
 * @notice Deploys shared NFT contract CofferBondNft
 * @author Blockroad Ltd
 * @dev This contract manages the deployment of individual Coffer
 * contracts and shared NFT management
 */
contract CofferFactory {
    error InvalidDuration();
    error InvalidInterestRate();
    error InvalidSafeTotalStake();
    error InvalidMinimumValueToAccept();

    uint256 private constant MAX_RATE = 1e8; // Represents 100% interest rate, so 1e6 is 1%
    uint256 private constant VALIDATOR_STARTING_ETH = 32 ether;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    // Total ETH staked amount that shouldn't be reached in 100 years
    uint256 private constant MAX_SAFE_TOTAL_STAKE = 300_000_000;
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;

    /// @notice Address of the shared CofferBondNft contract
    address public immutable I_COFFER_BOND_NFT_ADDRESS;
    /// @notice Address of the shared CofferBondsRedeemedEarly contract
    address public immutable I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS;

    /// @notice Emitted when a new Coffer contract is created
    /// @param owner The address of the validator who created the Coffer
    /// @param cofferAddress The address of the newly deployed Coffer contract
    event CofferIssued(address indexed owner, address indexed cofferAddress);

    /// @notice Deploys the shared CofferBondNft and CofferBondsRedeemedEarly contracts
    constructor() {
        CofferBondNft iCofferBondNft = new CofferBondNft();
        I_COFFER_BOND_NFT_ADDRESS = address(iCofferBondNft);
        CofferBondsRedeemedEarly iBondsRedeemedEarly = new CofferBondsRedeemedEarly();
        I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS = address(iBondsRedeemedEarly);
    }

    /// @notice Creates a new Coffer contract for a validator
    /// @param _publicKeyPart1 First 32 bytes of the validator BLS public key
    /// @param _publicKeyPart2 Last 16 bytes of the validator BLS public key
    /// @param _interestRate Yearly interest rate offered to bond holders
    /// @param _minimumDuration Minimum bond duration in seconds
    /// @param _maximumDuration Maximum bond duration in seconds
    /// @param _minimumValueToAccept Minimum value a holder must deposit
    /// @param _safeTotalStake Safe total network stake for penalty calculation
    /// @param _exitAllowed Whether holders can initiate validator exits
    /// @return The address of the newly deployed Coffer contract
    function createCoffer(
        bytes32 _publicKeyPart1,
        bytes16 _publicKeyPart2,
        uint32 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _minimumValueToAccept,
        uint32 _safeTotalStake,
        bool _exitAllowed
    ) external returns (address) {
        require(_minimumDuration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration >= _minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration <= MAX_DURATION, InvalidDuration());
        require(_interestRate != 0, InvalidInterestRate());
        // solhint-disable-next-line gas-strict-inequalities
        require(_interestRate <= MAX_RATE, InvalidInterestRate());
        require(_safeTotalStake != 0, InvalidSafeTotalStake());
        // solhint-disable-next-line gas-strict-inequalities
        require(_safeTotalStake <= MAX_SAFE_TOTAL_STAKE, InvalidSafeTotalStake());

        // Validator cannot set the minimum value to accept to more than the maximum it could accept
        uint256 maxMinimumValueToAccept = Penalty.addMaximumPenalty(
            VALIDATOR_STARTING_ETH,
            _safeTotalStake,
            (_maximumDuration + NUMBER_OF_SECONDS_IN_EPOCH - 1) / NUMBER_OF_SECONDS_IN_EPOCH
        );

        require(_minimumValueToAccept != 0, InvalidMinimumValueToAccept());
        // solhint-disable-next-line gas-strict-inequalities
        require(_minimumValueToAccept <= maxMinimumValueToAccept, InvalidMinimumValueToAccept());

        Coffer newCoffer = new Coffer(
            msg.sender,
            I_COFFER_BOND_NFT_ADDRESS,
            I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS,
            _publicKeyPart1,
            _publicKeyPart2,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _minimumValueToAccept,
            _safeTotalStake,
            _exitAllowed
        );

        emit CofferIssued(msg.sender, address(newCoffer));

        return address(newCoffer);
    }
}
