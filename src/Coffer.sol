//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICofferReceivableNFT} from "./interfaces/ICofferReceivableNFT.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import {Interest} from "./libraries/Interest.sol";

/**
 * @title Coffer
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple holders per validator with transferable receivable NFT instruments representing ownership of offer
 * @notice Integrates with EIP-7002 for withdrawals from consensus layer to smart contract
 * @notice Used IDepositContract interface to allow deposits to consensus layer to top up validators effective balance
 */
contract Coffer is Ownable, ReentrancyGuard {
    error ZeroAmount();
    error AmountTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();

    error InvalidSlashingPenalty();

    error ValidatorIsNotActive();
    error ValidatorIsActive();
    error ValidatorHasOpenOffers();
    error ValidatorInsufficientAmountForClosingOffer(address holderAddress, uint256 amountOwed);
    error ValidatorDoesNotHaveEnoughAvailableAmount(uint256 amountWithInterest);

    error HolderDoesNotExistOrAlreadyWithdrawnAmount();
    error HoldersTimeHasNotExpiredYet();
    error HolderCannotBeValidator();
    error CallerIsNotHolder();

    error NotEnoughAvailableAmountToWithdrawFromContract();
    error SendAmountFailed();
    error PrecompileFailed();
    error InsufficientPrecompileFee();

    /// @notice after startTimestamp + duration > block.timestamp, offer has expired
    struct HolderConditions {
        uint256 duration;
        uint256 startTimestamp;
        uint256 amount;
    }

    /// @param isActive represents if validator accepts offers or not
    /// @param availableAmount validator chooses this parameter on its own and that way it determines for holder how sure they can be of the return of their funds in future. This value has to be in line with consensus amount of validator in some sense. It is the total amount that validator can offer to holders. When holder accepts the offer with certain amount less than this amount, this amount is decreased by offered amount with interest. This amount also represents amount which validator can withdraw from consensus
    /// @param returnAmountRate after offer ends and holder gets their share, validator can fill up its availableAmount parameter by their choice. Default value should be 1. This way validator can create new offer as soon as one is finished with execution and consensus amounts in sync, without ending all other offers in order to update parameters. Should we have this feature or remove it?
    /// @notice parameters other than isActive can be changed by the validator only but only if there are no active creditors
    /// @notice only when startingAmount == availableAmount, validator can change its parameter since that means there are no ongoing offers
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
    //uint256 returnAmonutRate;
    //bool exitAllowed;

    /// @notice last 8 bytes in WITHDRAWAL_PRECOMPILE represents withdraw amount in Gwei (not wei), so we use uint64 in functions which are using withdrawals from consensus layer
    /// @notice if last 8 bytes in WITHDRAWAL_PRECOMPILE are 0, then full exit is initiated
    address private constant WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice address of DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice 100% interest rate is the maximum allowed, it can have up to 16 decimal places, for example, 10% interest rate is represented as 1e17
    uint256 private constant RATE_DIVISOR = 1e18; // Divisor for calculating rate

    // we should probably make validator address not immutable so validator can change it at will.
    address immutable i_validatorAddress;
    address immutable i_cofferReceivableNFTAddress;
    // make those two parts to be only one bytes
    bytes32 immutable i_public_key_part1;
    bytes16 immutable i_public_key_part2;

    ValidatorConditions s_validatorConditions;
    mapping(uint256 => HolderConditions) s_holderConditions;

    event HolderAcceptedOffer(address indexed holderAddress);
    event HolderWithdrawFromExecution(address indexed holderAddress, uint256 amountToWithdraw);
    event HolderWithdrawFromConsensus(address indexed holderAddress, uint256 amountToWithdraw);
    event OfferClosed(address indexed holderAddress, uint256 amountOwed);

    modifier deactivatedAndNoAcceptedOffers() {
        if (s_validatorConditions.isActive == true) revert ValidatorIsActive();
        if (s_validatorConditions.availableAmount == s_validatorConditions.startingAmount) {
            revert ValidatorHasOpenOffers();
        }
        _;
    }

    modifier holderExists(uint256 _holderId) {
        if (s_holderConditions[_holderId].amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }
        _;
    }

    modifier holderIsCaller(uint256 _holderId) {
        if (msg.sender != ICofferReceivableNFT(i_cofferReceivableNFTAddress).getHolderAddress(_holderId)) {
            revert CallerIsNotHolder();
        }
        _;
    }

    constructor(
        address _validatorAddress,
        bytes32 _public_key_part1,
        bytes16 _public_key_part2,
        address _cofferReceivableNFTAddress,
        uint256 _maximumSlashingPenalty,
        uint256 _interestRate,
        uint256 _minimumDuration,
        uint256 _maximumDuration,
        uint256 _availableAmount,
        uint256 _minimumAmountToAccept //,
            //uint256 _returnAmonutRate,
            //bool _exitAllowed
    ) Ownable(_validatorAddress) {
        i_validatorAddress = _validatorAddress;
        i_cofferReceivableNFTAddress = _cofferReceivableNFTAddress;
        i_public_key_part1 = _public_key_part1;
        i_public_key_part2 = _public_key_part2;

        s_validatorConditions = ValidatorConditions({
            isActive: true,
            maximumSlashingPenalty: _maximumSlashingPenalty,
            interestRate: _interestRate,
            minimumDuration: _minimumDuration,
            maximumDuration: _maximumDuration,
            availableAmount: _availableAmount,
            startingAmount: _availableAmount,
            minimumAmountToAccept: _minimumAmountToAccept //,
                //returnAmonutRate: _returnAmonutRate,
                //exitAllowed: _exitAllowed
        });
    }

    ///
    /// EXTERNAL FUNCTIONS
    ///

    /// @notice Function in which msg.sender accepts an offer
    /// @param _duration holder defines duration which must be in validators offered interval
    /// @notice holder sends offers amount within msg.value
    /// @notice Function creates NFT which gives msg.sender ownership of accepted offer
    function acceptOffer(uint256 _duration) external payable nonReentrant {
        // The creditor must send the exact amount of ether to the contract
        if (msg.value < s_validatorConditions.minimumAmountToAccept) revert AmountTooSmallToAccept();
        if (s_validatorConditions.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == i_validatorAddress) revert HolderCannotBeValidator();
        if (
            (_duration > s_validatorConditions.maximumDuration || _duration < s_validatorConditions.minimumDuration)
                || _duration == 0
        ) revert InvalidDuration();

        uint256 amountWithInterest =
            msg.value + Interest.calculateInterest(msg.value, _duration, s_validatorConditions.interestRate);

        if (amountWithInterest > s_validatorConditions.availableAmount) {
            revert ValidatorDoesNotHaveEnoughAvailableAmount(amountWithInterest);
        }

        // Mint NFT representing the offer ownership and receivables
        uint256 holderId = ICofferReceivableNFT(i_cofferReceivableNFTAddress).mintCofferReceivable(msg.sender);

        // Store coffer conditions using holderId as key
        s_holderConditions[holderId] =
            HolderConditions({duration: _duration, startTimestamp: block.timestamp, amount: amountWithInterest});

        s_validatorConditions.availableAmount -= amountWithInterest;

        emit HolderAcceptedOffer(msg.sender);

        (bool success,) = i_validatorAddress.call{value: msg.value}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Close an offer by repaying the full amount early
    /// @notice Can only be called by the validator
    /// @param _holderId Holder ID which offer validator is closing
    function closeOffer(uint256 _holderId) external payable onlyOwner nonReentrant holderExists(_holderId) {
        address holderAddress = ICofferReceivableNFT(i_cofferReceivableNFTAddress).getHolderAddress(_holderId);
        uint256 amountOwed = s_holderConditions[_holderId].amount;

        if (msg.value != amountOwed) {
            revert ValidatorInsufficientAmountForClosingOffer(holderAddress, amountOwed);
        }

        //s_validatorConditions.availableAmount += (s_validatorConditions.returnAmonutRate * amountOwed);
        s_validatorConditions.availableAmount += amountOwed;
        removeHolder(_holderId);

        emit OfferClosed(holderAddress, amountOwed);

        (bool success,) = holderAddress.call{value: amountOwed}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice This function is called by the validator to deactivate the validator
    /// @notice After deactivation, the validator cannot accept new offers
    function deactivateValidator() external onlyOwner {
        if (s_validatorConditions.isActive == false) revert ValidatorIsNotActive();
        s_validatorConditions.isActive = false;
    }

    /// @notice This function is called by the validator to activate the validator
    /// @notice After activation, the validator can accept new offers
    function activateValidator() external onlyOwner {
        if (s_validatorConditions.isActive == true) revert ValidatorIsActive();
        s_validatorConditions.isActive = true;
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeMaximumSlashingPenalty(uint256 _maximumSlashingPenalty)
        external
        onlyOwner
        deactivatedAndNoAcceptedOffers
    {
        if (_maximumSlashingPenalty == 0) revert InvalidSlashingPenalty();
        s_validatorConditions.maximumSlashingPenalty = _maximumSlashingPenalty;
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeInterestRate(uint256 _rate) external onlyOwner deactivatedAndNoAcceptedOffers {
        if (_rate == 0 || _rate > RATE_DIVISOR) revert InvalidRate();
        s_validatorConditions.interestRate = _rate;
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeMinimumAndMaximumDuration(uint256 _minimumDuration, uint256 _maximumDuration)
        external
        onlyOwner
        deactivatedAndNoAcceptedOffers
    {
        if ((_maximumDuration <= _minimumDuration) || _minimumDuration == 0) revert InvalidDuration();
        s_validatorConditions.minimumDuration = _minimumDuration;
        s_validatorConditions.maximumDuration = _maximumDuration;
    }

    /// @notice This function is called by the validator to increase the available amount
    /// @notice Validator should consider not to increase too much the available amount so that it satisfies the condition: effective balance on consensus layer >= available amount + slashing penalty
    function changeAvailableAmount(uint256 _amount) external onlyOwner deactivatedAndNoAcceptedOffers {
        if (_amount < s_validatorConditions.minimumAmountToAccept) revert AmountTooSmallToAccept();
        s_validatorConditions.availableAmount = _amount;
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeMinimumAmountToAccept(uint256 _amount) external onlyOwner deactivatedAndNoAcceptedOffers {
        if (_amount == 0) revert ZeroAmount();
        s_validatorConditions.minimumAmountToAccept = _amount;
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    /// @notice if Validator doesn't want to update availableAmount after offer is paid, returnAmountRate can be set to 0
    //function changereturnAmountRate(uint256 _rate) external onlyOwner deactivatedAndNoAcceptedOffers {
    //    if (_rate > RATE_DIVISOR) revert InvalidRate();
    //    s_validatorConditions.returnAmonutRate = _rate;
    //}

    /// @notice If contract has amount holder wants to withdraw and holder conditions are met, holder can call this function to withdraw the amount with interest
    /// @notice This function should be called when the contract has enough balance to cover the amount holder wants to withdraw
    /// @notice Either validator or holder can trigger consensus withdraw in order to fill up contract with ETH
    /// @notice Holder can withdraw from consensus only the amount validator owes them (?) and after offers maturity
    /// @notice NFT owner can withdraw using their holderId
    function holderWithdrawFromExecution(uint256 _holderId)
        external
        nonReentrant
        holderExists(_holderId)
        holderIsCaller(_holderId)
    {
        HolderConditions storage holderConditions = s_holderConditions[_holderId];

        // Has time passed so holder can withdraw
        if (holderConditions.duration + holderConditions.startTimestamp < block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Verify contract has enough balance to cover the amount creditor wants to withdraw
        if (address(this).balance < holderConditions.amount) {
            revert NotEnoughAvailableAmountToWithdrawFromContract();
        }

        uint256 amountToWithdraw = holderConditions.amount;

        removeHolder(_holderId);

        //s_validatorConditions.availableAmount += (s_validatorConditions.returnAmonutRate * amountToWithdraw);
        s_validatorConditions.availableAmount += amountToWithdraw;

        emit HolderWithdrawFromExecution(msg.sender, amountToWithdraw);

        (bool success,) = msg.sender.call{value: amountToWithdraw}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice this function cannot guarantee that amount will be withdrawn from consensus after successful execution
    // TO DO: holder must be able to exit validator if it doesn't have enough eth to return after offer is matured. validator must allow exits if it's going to offer that kind of offers.... blah
    function holderWithdrawFromConsensus(uint256 _holderId)
        external
        payable
        nonReentrant
        holderExists(_holderId)
        holderIsCaller(_holderId)
    {
        uint256 amountToWithdraw = s_holderConditions[_holderId].amount;

        // Has time passed so holder can withdraw
        if (s_holderConditions[_holderId].duration + s_holderConditions[_holderId].startTimestamp >= block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Check msg.value before calling precompile - it's needed to send 1 gwei in order to call precompile
        if (msg.value < 1) revert InsufficientPrecompileFee();

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(i_public_key_part1, i_public_key_part2, uint64(amountToWithdraw));

        // test if this part is more gas-efficient
        /*
        bytes32 pk1 = i_public_key_part1;
        bytes16 pk2 = i_public_key_part2;

        assembly {
            mstore(add(data, 0x20), pk1) // Copy first 32 bytes
            mstore(add(data, 0x40), pk2) // Copy remaining 16 bytes
            mstore(add(data, 0x50), shl(192, amount)) // Add amount (shift left 192 bits = 24 bytes)
        }
        */

        emit HolderWithdrawFromConsensus(msg.sender, amountToWithdraw);

        (bool success,) = WITHDRAWAL_PRECOMPILE.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }
    }

    function validatorWithdrawFromExecution() external nonReentrant onlyOwner {}
    function validatorAddFundsToConsensus() external payable nonReentrant onlyOwner {}
    function validatorWithdrawFromConsensus(bytes32 public_key_p1, bytes16 public_key_p2, uint64 _amount)
        external
        payable
        nonReentrant
        onlyOwner
    {}

    ///
    /// PRIVATE FUNCTIONS
    ///

    /// @notice Function which cleans up holders data in contract
    /// @notice Used in: closeOffer & creditorWithdrawFromExecution
    function removeHolder(uint256 _holderId) private {
        ICofferReceivableNFT(i_cofferReceivableNFTAddress).burnCofferReceivable(_holderId);
        delete s_holderConditions[_holderId];
    }

    ///
    /// VIEW FUNCTIONS
    ///

    function getValidatorConditions()
        external
        view
        returns (
            bool isActive,
            uint256 maximumSlashingPenalty,
            uint256 interestRate,
            uint256 minimumDuration,
            uint256 maximumDuration,
            uint256 availableAmount,
            uint256 startingAmount,
            uint256 minimumAmountToAccept //,
                //uint256 returnAmonutRate,
                //bool exitAllowed
        )
    {
        ValidatorConditions storage conditions = s_validatorConditions;
        return (
            conditions.isActive,
            conditions.maximumSlashingPenalty,
            conditions.interestRate,
            conditions.minimumDuration,
            conditions.maximumDuration,
            conditions.availableAmount,
            conditions.startingAmount,
            conditions.minimumAmountToAccept //,
                //conditions.returnAmonutRate
                //conditions.exitAllowed
        );
    }

    function getHolderConditions(uint256 _holderId)
        external
        view
        holderExists(_holderId)
        returns (uint256 duration, uint256 startTimestamp, uint256 amount)
    {
        HolderConditions storage conditions = s_holderConditions[_holderId];
        return (conditions.duration, conditions.startTimestamp, conditions.amount);
    }
}
