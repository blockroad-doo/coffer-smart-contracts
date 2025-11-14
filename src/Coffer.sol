//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICofferReceivableNFT} from "./interfaces/ICofferReceivableNFT.sol";

/**
 * @title Coffer
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple users per validator with transferable receivable NFT instruments
 * @notice Integrates with EIP-7002 for consensus layer withdrawals
 */
contract Coffer is Ownable, ReentrancyGuard {
    error AmountToSmallToAccept();
    error InvalidDuration();
    error InvalidRate();
    error InterestRateMismatch();
    error InvalidConsensusPublicKeyLength();
    error InvalidSlashingPenalty();

    error ValidatorIsNotActive();
    error ValidatorIsActive();
    error ValidatorHasOpenOffers();
    error ValidatorDoesntHaveEnoughAvailableAmount(uint256 amountWithInterest);

    error HolderDoesntExistOrAlreadyWithdrawnWholeAmount();
    error HolderCannotBeValidator();

    error SendAmountFailed();

    /// @notice at start lastWithdrawTimestamp == block.timestamp
    /// @notice after lastWithdrawTimestamp + durationLeft > block.timestamp, offer has expired
    /// @notice every time creditor withdraws from contract, principal is reduced by the amount withdrawn
    struct HolderConditions {
        uint256 durationLeft;
        uint256 lastWithdrawTimestamp;
        uint256 remainingAmount;
        uint256 startingAmount;
    }

    /// @param isActive represents if validator accepts offers or not
    /// @param availableAmount validator choose this parameter on it's own and that way it determines for holder how sure they can be of the return of their funds in future. It is the total amount that validator can offer to holders. When holder accept the offer with certain amount less than this amount, this amount is decreased by offered amount with interest. That way this amount is amount which validator can withdraw.
    /// @notice parameters other than isActive can be changed by the validator only but only if there are no active creditors
    /// @notice only when startingAmount == availableAmount, validator can change it's parameter since that means there are no ongoing offers
    struct ValidatorConditions {
        bool isActive;
        uint256 maximumSlashingPenalty;
        uint256 interestRate;
        uint256 minimumDuration;
        uint256 maximumDuration;
        uint256 availableAmount;
        uint256 startingAmount;
        uint256 minimumAmountToAccept;
    }

    /// @notice last 8 bytes in WITHDRAWAL_PRECOMPILE represents withdraw amount in Gwei (not wei), so we use uint64 in withdrawFundsOrExit function
    /// @notice if last 8 bytes in WITHDRAWAL_PRECOMPILE are 0, then full exit is initiated
    address private constant WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    address private constant ADD_FUNDS_PRECOMPILE = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice 100% interest rate is the maximum allowed, it can have up to 16 decimal places, for example, 10% interest rate is represented as 10e17
    uint256 private constant RATE_DIVISOR = 1e18; // Interest rate divisor for 100% interest rate
    uint256 private constant SECONDS_IN_YEAR = 31_536_000; // 365 days * 24 hours * 60 minutes * 60 seconds

    address immutable i_validatorAddress;
    ICofferReceivableNFT immutable i_cofferReceivableNFT;

    ValidatorConditions s_validatorConditions;
    mapping(uint256 => HolderConditions) s_holderConditions;

    event HolderAcceptedOffer(address indexed holderAddress);

    modifier deactivatedAndNoAceptedOffers() {
        if (s_validatorConditions.isActive == true) revert ValidatorIsActive();
        if (s_validatorConditions.availableAmount == s_validatorConditions.startingAmount) {
            revert ValidatorHasOpenOffers();
        }
        _;
    }

    modifier holderExists(uint256 _holderId) {
        if (s_holderConditions[_holderId].remainingAmount == 0) {
            revert HolderDoesntExistOrAlreadyWithdrawnWholeAmount();
        }
        _;
    }

    constructor(
        address _validatorAddress,
        address _cofferReceivableNFTAddress,
        uint256 _maximumSlashingPenalty,
        uint256 _interestRate,
        uint256 _minimumDuration,
        uint256 _maximumDuration,
        uint256 _availableAmount,
        uint256 _startingAmount,
        uint256 _minimumAmountToAccept
    ) Ownable(_validatorAddress) {
        i_validatorAddress = _validatorAddress;
        i_cofferReceivableNFT = ICofferReceivableNFT(_cofferReceivableNFTAddress);

        s_validatorConditions = ValidatorConditions({
            isActive: true,
            maximumSlashingPenalty: _maximumSlashingPenalty,
            interestRate: _interestRate,
            minimumDuration: _minimumDuration,
            maximumDuration: _maximumDuration,
            availableAmount: _availableAmount,
            startingAmount: _startingAmount,
            minimumAmountToAccept: _minimumAmountToAccept
        });
    }

    /// @dev Private function to remove holder
    /// @dev used in:
    /// @param _holderId Holder ID of the loan to remove
    function removeCreditor(uint256 _holderId) private {
        // Burn the NFT after offer is expired or closed earlier
        i_cofferReceivableNFT.burnCofferReceivable(_holderId);
        delete s_holderConditions[_holderId];
    }

    /// Function which accepts offer
    /// @param _duration holder defines duration which must be in validators offered interval
    function acceptLoan(uint256 _duration) external payable nonReentrant {
        // The creditor must send the exact amount of ether to the contract
        if (msg.value < s_validatorConditions.minimumAmountToAccept) revert AmountToSmallToAccept();
        if (s_validatorConditions.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == i_validatorAddress) revert HolderCannotBeValidator();
        if (
            (_duration > s_validatorConditions.maximumDuration || _duration < s_validatorConditions.minimumDuration)
                || _duration == 0
        ) revert InvalidDuration();

        uint256 amountWithInterest =
            msg.value + calculateInterest(msg.value, _duration, s_validatorConditions.interestRate);

        if (amountWithInterest > s_validatorConditions.availableAmount) {
            revert ValidatorDoesntHaveEnoughAvailableAmount(amountWithInterest);
        }

        s_validatorConditions.availableAmount -= amountWithInterest;

        // Mint NFT representing the offer ownership and receivables
        uint256 holderId = i_cofferReceivableNFT.mintCofferReceivable(msg.sender);

        // Store loan conditions using creditorId as key
        s_holderConditions[holderId] = HolderConditions({
            durationLeft: _duration,
            lastWithdrawTimestamp: block.timestamp,
            remainingAmount: amountWithInterest,
            startingAmount: amountWithInterest
        });

        emit HolderAcceptedOffer(msg.sender);

        (bool success,) = i_validatorAddress.call{value: msg.value}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Function to calculate the interest based on the amount, duration and interest rate
    /// @notice We use simple interest calulation with timestamp to calculate the interest
    /// @notice The interest is calculated as: (amount * interest rate * duration) / (RATE_DIVISOR * SECONDS_IN_YEAR)
    /// @param _amount The amount for which interest is to be calculated
    /// @param _duration The duration for which interest is to be calculated
    /// @param _rate The yearly interest rate to be applied, should be in the range (0, 10e18)
    /// @notice The interest rate should be in the range (0, 10e18) where 10e18 represents 100% interest rate or 10e16 represents 1% interest rate
    function calculateInterest(uint256 _amount, uint256 _duration, uint256 _rate) public pure returns (uint256) {
        if (_amount == 0) return 0;
        if (_duration == 0) revert InvalidDuration();
        if (_rate == 0 || _rate > RATE_DIVISOR) revert InvalidRate();

        // Calculate the interest based on the amount, interest rate and duration
        return (_amount * _rate * _duration) / (RATE_DIVISOR * SECONDS_IN_YEAR);
    }
}
