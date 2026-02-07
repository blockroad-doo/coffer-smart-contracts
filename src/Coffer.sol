//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
    error ValidatorIsNotActive();
    error ValidatorIsActive();
    error ValidatorHasOpenOffers();
    error ValidatorAmountMissmatchForClosingOffer();
    error ValidatorDoesNotHaveEnoughAvailableAmount();
    error HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
    error HolderDoesNotExistOrAlreadyWithdrawnAmount();
    error HoldersTimeHasNotExpiredYet();
    error HolderCannotBeValidator();
    error CallerIsNotHolder();
    error ContractBalanceLessThanAmount();
    error SendAmountFailed();
    error PrecompileFailed();
    error InsufficientPrecompileFee();

    /// @notice after startTimestamp + duration > block.timestamp, offer has expired
    struct HolderConditions {
        uint256 amount;
        uint256 duration;
        uint256 startTimestamp;
    }

    /// @param isActive represents if validator accepts offers or not
    /// @param openOffers counter for open offers
    /// @param availableAmount validator chooses this parameter on its own and that way it determines for holder how sure they can be of the return of their funds in future. This value has to be in line with consensus amount of validator in some sense. It is the total amount that validator can offer to holders. When holder accepts the offer with certain amount less than this amount, this amount is decreased by offered amount with interest. This amount also represents amount which validator can withdraw from consensus
    /// @param exitAllowed validator can make availableAmount small enough so holder has no other way to claim amount than to exit a validator
    /// @notice parameters other than isActive, openOffers can be changed by the validator only but only if there are no active creditors
    /// @notice only when openOffers == 0, validator can change its parameter since that means there are no ongoing offers
    struct ValidatorConditions {
        bool isActive;
        uint256 openOffers;
        uint256 interestRate;
        uint256 minimumDuration;
        uint256 maximumDuration;
        uint256 availableAmount;
        uint256 minimumAmountToAccept;
        bool exitAllowed;
    }

    /// @notice last 8 bytes in WITHDRAWAL_PRECOMPILE represents withdraw amount in Gwei (not wei), so we use uint64 in functions which are using withdrawals from consensus layer
    /// @notice if last 8 bytes in WITHDRAWAL_PRECOMPILE are 0, then full exit is initiated
    address private constant WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice address of DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice address of consolidation contract, must be called from coffer contract
    address private constant CONSOLIDATION_CONTRACT = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    /// @notice 100% interest rate is the maximum allowed, it can have up to 16 decimal places, for example, 10% interest rate is represented as 1e17
    uint256 private constant RATE_DIVISOR = 1e18; // Divisor for calculating rate
    uint256 private constant AMOUNT_IN_GWEI = 1e9;

    address public immutable i_validatorAddress;
    address public immutable i_cofferReceivableNFTAddress;
    // signing public key must stay immutable, it shouldn't be changed in any possible way so that validator cannot point this contract do different validator
    bytes32 public immutable i_public_key_part1;
    bytes16 public immutable i_public_key_part2;

    ValidatorConditions public s_validatorConditions;
    mapping(uint256 => HolderConditions) public s_holderConditions;

    event HolderAcceptedOffer(
        address indexed holderAddress,
        uint256 indexed holderId,
        uint256 amount,
        uint256 duration,
        uint256 amountWithInterest
    );
    event HolderWithdrawFromExecutionSuccess(address indexed holderAddress, uint256 indexed holderId);
    event HolderWithdrawFromConsensusSuccess(
        address indexed holderAddress, uint256 indexed holderId, uint256 amount, bool isFullExit
    );
    event ValidatorOfferClosed(address indexed holderAddress, uint256 indexed holderId, uint256 amountOwed);
    event ValidatorWithdrawFromExecution(uint256 amount);
    event ValidatorWithdrawFromConsensus(uint64 amount);
    event ValidatorFundsAdded(uint256 amount);
    event ValidatorActivated();
    event ValidatorDeactivated();
    event InterestRateChanged(uint256 oldRate, uint256 newRate);
    event DurationRangeChanged(uint256 minimumDuration, uint256 maximumDuration);
    event AvailableAmountChanged(uint256 oldAmount, uint256 newAmount);
    event MinimumAmountChanged(uint256 newMinimum);
    event ValidatorConvertedToCompounding();

    modifier deactivatedAndNoOpenOffers() {
        if (s_validatorConditions.isActive == true) revert ValidatorIsActive();
        if (s_validatorConditions.openOffers != 0) {
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

    ///@notice
    constructor(
        address _validatorAddress,
        address _cofferReceivableNFTAddress,
        bytes32 _public_key_part1,
        bytes16 _public_key_part2,
        uint256 _interestRate,
        uint256 _minimumDuration,
        uint256 _maximumDuration,
        uint256 _availableAmount,
        uint256 _minimumAmountToAccept,
        bool _exitAllowed
    ) Ownable(_validatorAddress) {
        i_validatorAddress = _validatorAddress;
        i_cofferReceivableNFTAddress = _cofferReceivableNFTAddress;

        i_public_key_part1 = _public_key_part1;
        i_public_key_part2 = _public_key_part2;

        s_validatorConditions = ValidatorConditions({
            isActive: false,
            openOffers: 0,
            interestRate: _interestRate,
            minimumDuration: _minimumDuration,
            maximumDuration: _maximumDuration,
            availableAmount: _availableAmount,
            minimumAmountToAccept: _minimumAmountToAccept,
            exitAllowed: _exitAllowed
        });
    }

    /// @notice Receive ETH (validator rewards and withdrawals will come here)
    /// @notice A validator can send here ETH in order to prevent holder to initate exit
    receive() external payable {}

    ///
    /// EXTERNAL FUNCTIONS
    ///

    /// @notice Function in which msg.sender accepts an offer
    /// @param _duration holder defines duration which must be in validators offered interval
    /// @notice holder sends offers amount within msg.value
    /// @notice Function creates NFT which gives msg.sender ownership of accepted offer
    function acceptOffer(uint256 _duration) external payable nonReentrant {
        // The creditor must send the exact amount of ether to the contract
        ValidatorConditions memory vs = s_validatorConditions;
        if (msg.value < vs.minimumAmountToAccept) revert AmountTooSmallToAccept();
        if (vs.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == i_validatorAddress) revert HolderCannotBeValidator();
        if ((_duration > vs.maximumDuration || _duration < vs.minimumDuration) || _duration == 0) {
            revert InvalidDuration();
        }

        uint256 amountWithInterest = msg.value + Interest.calculateInterest(msg.value, _duration, vs.interestRate);

        if (amountWithInterest > vs.availableAmount) {
            revert ValidatorDoesNotHaveEnoughAvailableAmount();
        }

        // Mint NFT representing the offer ownership and receivables
        uint256 holderId = ICofferReceivableNFT(i_cofferReceivableNFTAddress).mintCofferReceivable(msg.sender);

        // Store coffer conditions using holderId as key
        s_holderConditions[holderId] =
            HolderConditions({duration: _duration, startTimestamp: block.timestamp, amount: amountWithInterest});

        s_validatorConditions.availableAmount -= amountWithInterest;
        unchecked {
            s_validatorConditions.openOffers++;
        }

        emit HolderAcceptedOffer(msg.sender, holderId, msg.value, _duration, amountWithInterest);

        (bool success,) = i_validatorAddress.call{value: msg.value}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Close an offer by repaying the full amount early
    /// @notice Only validator can call this function
    /// @notice Amount is repayed from validators address
    /// @param _holderId Holder ID which offer validator is closing
    function closeOfferWithExactAmountFromValidator(uint256 _holderId)
        external
        payable
        onlyOwner
        nonReentrant
        holderExists(_holderId)
    {
        address holderAddress = ICofferReceivableNFT(i_cofferReceivableNFTAddress).getHolderAddress(_holderId);
        uint256 amountOwed = s_holderConditions[_holderId].amount;

        if (msg.value != amountOwed) {
            revert ValidatorAmountMissmatchForClosingOffer();
        }

        removeHolder(_holderId);

        emit ValidatorOfferClosed(holderAddress, _holderId, amountOwed);

        (bool success,) = holderAddress.call{value: amountOwed}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Close an offer by repaying the full amount early
    /// @notice Only validator can call this function
    /// @notice Amount is repayed from Coffer contract
    /// @param _holderId Holder ID which offer validator is closing
    function closeOfferFromCofferContract(uint256 _holderId) external onlyOwner nonReentrant holderExists(_holderId) {
        address holderAddress = ICofferReceivableNFT(i_cofferReceivableNFTAddress).getHolderAddress(_holderId);
        uint256 amountOwed = s_holderConditions[_holderId].amount;

        if (address(this).balance < amountOwed) {
            revert ContractBalanceLessThanAmount();
        }

        removeHolder(_holderId);

        emit ValidatorOfferClosed(holderAddress, _holderId, amountOwed);

        (bool success,) = holderAddress.call{value: amountOwed}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice This function is called by the validator to deactivate the validator. After deactivation, the validator cannot accept new offers
    function deactivateValidator() external onlyOwner {
        if (s_validatorConditions.isActive == false) revert ValidatorIsNotActive();
        s_validatorConditions.isActive = false;
        emit ValidatorDeactivated();
    }

    /// @notice This function is called by the validator to activate the validator. After activation, the validator can accept new offers
    function activateValidator() external onlyOwner {
        if (s_validatorConditions.isActive == true) revert ValidatorIsActive();
        s_validatorConditions.isActive = true;
        emit ValidatorActivated();
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeInterestRate(uint256 _rate) external onlyOwner deactivatedAndNoOpenOffers {
        if (_rate == 0 || _rate > RATE_DIVISOR) revert InvalidRate();
        uint256 oldRate = s_validatorConditions.interestRate;
        s_validatorConditions.interestRate = _rate;
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeMinimumAndMaximumDuration(uint256 _minimumDuration, uint256 _maximumDuration)
        external
        onlyOwner
        deactivatedAndNoOpenOffers
    {
        if ((_maximumDuration <= _minimumDuration) || _minimumDuration == 0) revert InvalidDuration();
        s_validatorConditions.minimumDuration = _minimumDuration;
        s_validatorConditions.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice This function is called by the validator to increase the available amount
    /// @notice Validator should consider not to increase too much the available amount so that it satisfies the condition: effective balance on consensus layer >= available amount + slashing penalty
    function changeAvailableAmount(uint256 _amount) external onlyOwner deactivatedAndNoOpenOffers {
        if (_amount < s_validatorConditions.minimumAmountToAccept) revert AmountTooSmallToAccept();
        uint256 oldAmount = s_validatorConditions.availableAmount;
        s_validatorConditions.availableAmount = _amount;
        emit AvailableAmountChanged(oldAmount, _amount);
    }

    /// @notice function can be called only when validator is deactivated and has no accepted offers
    function changeMinimumAmountToAccept(uint256 _amount) external onlyOwner deactivatedAndNoOpenOffers {
        if (_amount == 0) revert ZeroAmount();
        s_validatorConditions.minimumAmountToAccept = _amount;
        emit MinimumAmountChanged(_amount);
    }

    /// @notice If contract has amount holder wants to withdraw and holder conditions are met, holder can call this function to withdraw the amount with interest
    /// @notice This function should be called when the contract has enough balance to cover the amount holder wants to withdraw
    /// @notice Validator or holder can trigger consensus withdraw in order to fill up contract with ETH
    /// @notice If validator allows holder to initiate full exit than it can ask offers for (almost) all the amount, even so it can drop to less than 32
    /// @notice If validator doesn not allows holder to initiate full exit, a holder can withdraw from consensus only the amount validator owes them and after offers maturity
    /// @notice NFT owner can withdraw using their holderId
    function holderWithdrawFromExecution(uint256 _holderId)
        external
        nonReentrant
        holderExists(_holderId)
        holderIsCaller(_holderId)
    {
        HolderConditions storage holder = s_holderConditions[_holderId];

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp >= block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Verify contract has enough balance to cover the amount creditor wants to withdraw
        if (address(this).balance < holder.amount) {
            revert ContractBalanceLessThanAmount();
        }

        uint256 amountToWithdraw = holder.amount;

        removeHolder(_holderId);

        emit HolderWithdrawFromExecutionSuccess(msg.sender, _holderId);

        (bool success,) = msg.sender.call{value: amountToWithdraw}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice this function cannot guarantee that amount will be withdrawn from consensus after successful execution
    /// TO DO: find out what are those exact situations in which withdrawls won't work (if any?)
    /// @notice if Validators allows exits, we cannot have proper way to check if holder should withdraw its exact amount or exit validator, thus holder will always exit validator if it's possible
    /// @notice if contract has enough amount to close holder's offer, holder isn't able to withdraw any amount from consensus
    /// @notice in order for validator to avoid exits by holder, toping up a contract with holder amount is neccesary
    function holderWithdrawFromConsensus(uint256 _holderId)
        external
        payable
        nonReentrant
        holderExists(_holderId)
        holderIsCaller(_holderId)
    {
        HolderConditions storage holder = s_holderConditions[_holderId];

        uint256 amountToWithdraw = holder.amount;

        if (address(this).balance >= amountToWithdraw) {
            revert HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
        }

        uint256 amountToWithdrawInGwei = amountToWithdraw / 1e9;

        // if precompile contract receives 0 as withdraw amount, exit is initiated
        if (s_validatorConditions.exitAllowed == true) amountToWithdrawInGwei = 0;

        // Has time passed so holder can withdraw

        if (holder.duration + holder.startTimestamp >= block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Check msg.value before calling precompile - it's needed to send 1 gwei in order to call precompile
        if (msg.value < 1) revert InsufficientPrecompileFee();

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdrawInGwei (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data =
            abi.encodePacked(i_public_key_part1, i_public_key_part2, SafeCast.toUint64(amountToWithdrawInGwei));

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

        bool isFullExit = (amountToWithdrawInGwei == 0);
        emit HolderWithdrawFromConsensusSuccess(msg.sender, _holderId, amountToWithdraw, isFullExit);

        (bool success,) = WITHDRAWAL_PRECOMPILE.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }
    }

    /// @notice Validator that has no open offers can withdraw everything from contract
    /// @notice If validator has open offers, than it can withdraw only less than `availableAmount`
    function validatorWithdrawFromExecution(uint256 _amount) external nonReentrant onlyOwner {
        if (s_validatorConditions.openOffers > 0) {
            if (_amount > s_validatorConditions.availableAmount) {
                revert ValidatorDoesNotHaveEnoughAvailableAmount();
            }
            s_validatorConditions.availableAmount -= _amount;
        }

        if (_amount > address(this).balance) revert ContractBalanceLessThanAmount();

        emit ValidatorWithdrawFromExecution(_amount);

        (bool success,) = msg.sender.call{value: _amount}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Validator can withdraw from contract as much as it wants, even perform an exit. Holders funds are still covered
    // TODO: should I use uint64 at all?
    // TODO: check does WITHDRAWAL_PRECOMPILE really expects amount, packed in data, to come in Gwei? C-3 in report
    function validatorWithdrawFromConsensus(uint64 _amount) external payable nonReentrant onlyOwner {
        if (s_validatorConditions.openOffers > 0) {
            if (_amount > s_validatorConditions.availableAmount) {
                revert ValidatorDoesNotHaveEnoughAvailableAmount();
            } else {
                s_validatorConditions.availableAmount -= _amount;
            }
        }

        // Check msg.value before calling precompile - it's needed to send 1 gwei in order to call precompile
        if (msg.value < 1) revert InsufficientPrecompileFee();

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(i_public_key_part1, i_public_key_part2, _amount);

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

        emit ValidatorWithdrawFromConsensus(_amount);

        (bool success,) = WITHDRAWAL_PRECOMPILE.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }
    }

    /// @notice Validator can add funds at his own will
    /// @param _deposit_data_root Validator must create deposit data root off chain, can do it using Using JavaScript with @chainsafe/ssz with validator public signing key and the amount intented to add
    /// @param _more_available_amount It can be calculated off chain how much available amount can increase when deposit of more ETH is made to a validator
    // TODO: Test this! When validator adds funds we can safely update `availableAmount` with new amount, dont we?
    // TODO: Check what how to create deposit_data_root, what if we send wrong one? Does .deposit returns success?
    function validatorAddFundsToConsensus(bytes32 _deposit_data_root, uint256 _more_available_amount)
        external
        payable
        nonReentrant
        onlyOwner
    {
        if (msg.value == 0) revert ZeroAmount();

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg.value}(
            abi.encodePacked(i_public_key_part1, i_public_key_part2),
            new bytes(32), //withdraw credentials
            new bytes(96), //signature
            _deposit_data_root
        );

        s_validatorConditions.availableAmount += _more_available_amount;

        emit ValidatorFundsAdded(msg.value);
    }

    /// @notice this should be called after contract address is successfuly assigned to validators BLS public key
    function convertToCompounding() external payable nonReentrant onlyOwner {
        // Source and target are the same for self-consolidation
        bytes memory data = abi.encodePacked(
            //source
            i_public_key_part1,
            i_public_key_part2,
            //target
            i_public_key_part1,
            i_public_key_part2
        );

        (bool success,) = CONSOLIDATION_CONTRACT.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }

        emit ValidatorConvertedToCompounding();
    }

    ///
    /// PRIVATE FUNCTIONS
    ///

    /// @notice Function which cleans up holders data and updates validators data
    /// @notice Used in: closeOfferWithExactAmountFromValidator, closeOfferFromCofferContract & holderWithdrawFromExecution
    function removeHolder(uint256 _holderId) private {
        unchecked {
            s_validatorConditions.availableAmount += s_holderConditions[_holderId].amount;
            s_validatorConditions.openOffers--;
        }
        ICofferReceivableNFT(i_cofferReceivableNFTAddress).burnCofferReceivable(_holderId);
        delete s_holderConditions[_holderId];
    }
}
