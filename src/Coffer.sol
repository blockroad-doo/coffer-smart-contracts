//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import {Interest} from "./libraries/Interest.sol";

/**
 * @title Coffer
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple holders per validator with transferable receivable NFT instruments representing ownership of offer
 * @notice Integrates with EIP-7002 for withdrawals from consensus layer to smart contract
 * @notice Used IDepositContract interface to allow deposits to consensus layer to top up validators effective balance
 */
contract Coffer is Ownable, ReentrancyGuard, Multicall {
    using SafeCast for uint256;
    using SafeCast for uint128;

    error ZeroAmount();
    error AmountTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();
    error ValidatorIsNotActive();
    error ValidatorHasUnrepayedBonds();
    error ValidatorConditionsVersionMismatch();
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
        uint128 amount;
        uint64 duration;
        uint64 startTimestamp;
    }

    /// @param isActive represents if validator is willing to issue a bond
    /// @param existingBonds counter for exiting bonds
    /// @param availableAmount validator chooses this parameter on its own and that way it determines for holder how sure they can be of the return of their funds in future. This value has to be less than validators consensus balance, by at least a cost of penalties which could occur, in order for this validators bonds to be safe to buy. It is the total amount that validator can use to issue a bonds. When holder buys a bond, this amount is decreased by the bond amount with interest. This amount also represents amount which validator can withdraw from consensus to execution.
    /// @param exitAllowed validator can make availableAmount small enough so holder has no other way to claim amount than to exit a validator. Those are situations in which validator issues bonds which total value makes validator effective balance less than 32 ETH. If validator set availableAmount less than its consenus balance by 32 ETH plus cost of penalties which could occur, that this parameter can be false and validator would be considered as safe.
    /// @notice parameters other than isActive, openOffers can be changed by the validator only but only if there are no active creditors
    /// @notice only when existingBonds == 0, validator can change its parameter since that means there are no bonds with
    struct ValidatorConditions {
        uint128 availableAmount; // Full 18 decimal ETH precision
        uint64 interestRate; // Keep 1e18 divisor for max precision
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint32 version;
        uint128 minimumAmountToAccept; // Full 18 decimal ETH precision
        uint32 unrepayedBonds;
        bool isActive;
        bool exitAllowed;
    }

    /// @notice last 8 bytes in WITHDRAWAL_PRECOMPILE represents withdraw amount in Gwei (not wei), so we use uint64 in functions which are using withdrawals from consensus layer
    /// @notice if last 8 bytes in WITHDRAWAL_PRECOMPILE are 0, then full exit is initiated
    address private constant WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice address of DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice address of consolidation contract, must be called from coffer contract
    address private constant CONSOLIDATION_CONTRACT = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    /// @notice 100% interest rate is the maximum allowed, it can have up to 8 decimal places, for example, 10% interest rate is represented as 1e7
    uint64 private constant RATE_DIVISOR = 1e8; // Divisor for calculating rate
    uint128 private constant AMOUNT_IN_GWEI = 1e9;

    address public immutable i_cofferBondNftAddress;
    // signing public key must stay immutable, it shouldn't be changed in any possible way so that validator cannot point this contract do different validator
    bytes32 public immutable i_public_key_part1;
    bytes16 public immutable i_public_key_part2;

    ValidatorConditions public s_validatorConditions;
    mapping(uint256 => HolderConditions) public s_holderConditions;

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
    event ValidatorBondRepayed(address indexed holderAddress, uint256 indexed holderId, uint128 amountOwed);
    event ValidatorWithdrawFromExecution(uint128 amount);
    event ValidatorWithdrawFromConsensus(uint128 amount);
    event ValidatorFundsAdded(uint128 amount);
    event CofferActivated();
    event CofferDeactivated();
    event CofferAllowsHolderToExit();
    event CofferForbidsHolderToExit();
    event InterestRateChanged(uint64 oldRate, uint64 newRate);
    event DurationRangeChanged(uint32 minimumDuration, uint32 maximumDuration);
    event AvailableAmountChanged(uint128 oldAmount, uint128 newAmount);
    event MinimumAmountChanged(uint128 newMinimum);
    event ValidatorConvertedToCompounding();

    modifier holderIsCaller(uint256 _holderId) {
        if (msg.sender != ICofferBondNft(i_cofferBondNftAddress).getHolderAddress(_holderId)) {
            revert CallerIsNotHolder();
        }
        _;
    }

    ///@notice
    constructor(
        address _owner,
        address _cofferBondNftAddress,
        bytes32 _public_key_part1,
        bytes16 _public_key_part2,
        uint64 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _availableAmount,
        uint128 _minimumAmountToAccept,
        bool _exitAllowed
    ) Ownable(_owner) {
        i_cofferBondNftAddress = _cofferBondNftAddress;
        i_public_key_part1 = _public_key_part1;
        i_public_key_part2 = _public_key_part2;

        s_validatorConditions = ValidatorConditions({
            version: 0,
            isActive: true,
            unrepayedBonds: 0,
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

    /// @notice Function in which msg.sender buys bond
    /// @param _duration holder defines duration which must be in validators offered interval
    /// @param _version version must fit with current validators version to prevent frontruns
    /// @notice holder sends bonds amount within msg.value
    /// @notice Function creates NFT which gives msg.sender ownership of a bond
    function buyBond(uint32 _duration, uint32 _version) external payable nonReentrant {
        // The creditor must send the exact amount of ether to the contract
        ValidatorConditions storage vs = s_validatorConditions;

        if (vs.version != _version) revert ValidatorConditionsVersionMismatch();
        if (msg.value < vs.minimumAmountToAccept) revert AmountTooSmallToAccept();
        if (vs.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == owner()) revert HolderCannotBeValidator();
        if ((_duration > vs.maximumDuration || _duration < vs.minimumDuration) || _duration == 0) {
            revert InvalidDuration();
        }

        uint128 msg_value_128 = SafeCast.toUint128(msg.value);
        uint128 amountWithInterest =
            msg_value_128 + Interest.calculateInterest(msg_value_128, _duration, vs.interestRate);

        if (amountWithInterest > vs.availableAmount) {
            revert ValidatorDoesNotHaveEnoughAvailableAmount();
        }

        // Mint NFT representing the bond
        uint256 holderId = ICofferBondNft(i_cofferBondNftAddress).mintCofferBond(msg.sender);

        // Store coffer conditions using holderId as key
        s_holderConditions[holderId] = HolderConditions({
            duration: _duration, startTimestamp: SafeCast.toUint32(block.timestamp), amount: amountWithInterest
        });

        vs.availableAmount -= amountWithInterest;
        unchecked {
            vs.unrepayedBonds++;
        }

        emit HolderAcceptedOffer(msg.sender, holderId, msg_value_128, _duration, amountWithInterest);

        (bool success,) = owner().call{value: msg_value_128}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice Repaying bonds early
    /// @notice Only validator can call this function
    /// @notice Amounts are repayed from Coffer contract
    /// @notice If contract doesn't have enough amount to repay, validator can send additional amount using msg.value
    /// @param _holderIds Holder IDs which bonds are intented to repay early
    function repayBondsEarly(uint256[] memory _holderIds) external payable onlyOwner nonReentrant {
        for (uint256 i = 0; i < _holderIds.length; ++i) {
            HolderConditions memory holder = s_holderConditions[_holderIds[i]];

            if (holder.amount == 0) {
                revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
            }

            if (address(this).balance < holder.amount) {
                revert ContractBalanceLessThanAmount();
            }

            address holderAddress = ICofferBondNft(i_cofferBondNftAddress).getHolderAddress(_holderIds[i]);
            removeHolder(_holderIds[i]);

            emit ValidatorBondRepayed(holderAddress, _holderIds[i], holder.amount);

            (bool success,) = holderAddress.call{value: holder.amount}("");
            if (!success) revert SendAmountFailed();
        }
    }

    /// @notice Change Coffers activity
    /// @notice If validator want's to stop issueing a bonds it can flip from active to inactive and vice versa
    function changeCofferActivity() external onlyOwner {
        s_validatorConditions.isActive = !s_validatorConditions.isActive;
        if (s_validatorConditions.isActive == true) emit CofferActivated();
        else emit CofferDeactivated();
    }

    /// @notice validaror can change it's rate without affecting previous bonds since rate is calculated when bond is bought
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    function changeInterestRate(uint64 _rate) external onlyOwner {
        if (_rate == 0 || _rate > RATE_DIVISOR) revert InvalidRate();
        ValidatorConditions storage vc = s_validatorConditions;
        uint64 oldRate = vc.interestRate;
        vc.interestRate = _rate;
        unchecked {
            vc.version++;
        }
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice validaror can change it's duration period without affecting previous bonds since duration is defined when bond is bought
    /// @notice duration period cannot affect holder while buying a bond so version doesn't have to be updated
    function changeMinimumAndMaximumDuration(uint32 _minimumDuration, uint32 _maximumDuration) external onlyOwner {
        if ((_maximumDuration < _minimumDuration) || _minimumDuration == 0) revert InvalidDuration();
        ValidatorConditions storage vc = s_validatorConditions;
        vc.minimumDuration = _minimumDuration;
        vc.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice validaror can change it's minimum amount to accept the bond without affecting previous bonds
    /// @notice minimum amount validator is willing to accept cannot affect holder while buying a bond so version doesn't have to be updated
    function changeMinimumAmountToAccept(uint128 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        s_validatorConditions.minimumAmountToAccept = _amount;
        emit MinimumAmountChanged(_amount);
    }

    /// @notice This function is called by the validator to increase the available amount
    /// @notice Validator should consider not to increase too much the available amount so that it satisfies the condition: effective balance on consensus layer >= available amount + possible penalties
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    function changeAvailableAmount(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = s_validatorConditions;

        if (vc.unrepayedBonds != 0) revert ValidatorHasUnrepayedBonds();
        if (_amount < vc.minimumAmountToAccept) revert AmountTooSmallToAccept();

        uint128 oldAmount = vc.availableAmount;
        vc.availableAmount = _amount;
        unchecked {
            vc.version++;
        }
        emit AvailableAmountChanged(oldAmount, _amount);
    }

    /// @notice This function is called by the validator to allow or forbids exits to holder
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    function changeExitAllowed() external onlyOwner {
        ValidatorConditions storage vc = s_validatorConditions;

        if (vc.unrepayedBonds != 0) revert ValidatorHasUnrepayedBonds();

        s_validatorConditions.exitAllowed = !s_validatorConditions.exitAllowed;

        unchecked {
            vc.version++;
        }
        if (s_validatorConditions.exitAllowed == true) emit CofferAllowsHolderToExit();
        else emit CofferForbidsHolderToExit();
    }

    /// @notice If contract has amount holder wants to withdraw and holders bond reached maturity, holder can call this function to withdraw the amount with interest
    /// @notice This function should be called when the contract has enough balance to cover the amount holder wants to withdraw
    /// @notice Validator or holder can trigger consensus withdraw in order to fill up contract with ETH
    /// @notice If validator allows holder to initiate full exit than it can issue bonds for (almost) all the consensus amount, even so it can drop to less than 32. Penalties should be considered only while defining availableAmount in this situation.
    /// @notice If validator doesn not allows holder to initiate full exit, a holder can withdraw from consensus only the amount validator owes them and after bond reach its maturity
    /// @notice BondNft owner can withdraw using their holderId
    function holderWithdrawFromExecution(uint256 _holderId) external nonReentrant holderIsCaller(_holderId) {
        HolderConditions storage holder = s_holderConditions[_holderId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp >= block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Verify contract has enough balance to cover the amount creditor wants to withdraw
        if (address(this).balance < holder.amount) {
            revert ContractBalanceLessThanAmount();
        }

        uint128 amountToWithdraw = holder.amount;

        removeHolder(_holderId);

        emit HolderWithdrawFromExecutionSuccess(msg.sender, _holderId);

        (bool success,) = msg.sender.call{value: amountToWithdraw}("");
        if (!success) revert SendAmountFailed();
    }

    /// @notice this function cannot guarantee that amount will be withdrawn from consensus after successful execution
    /// @notice if Validators allows exits, we cannot have proper way to check if holder should withdraw its exact amount or exit validator, thus holder will always exit validator if it's possible
    /// @notice if contract has enough amount to close holder's offer, holder isn't able to withdraw any amount from consensus
    /// @notice in order for validator to avoid exits by holder, toping up a contract with holder amount is neccesary
    // TODO: find out what are those exact situations in which withdrawls won't work (if any?)
    function holderWithdrawFromConsensus(uint256 _holderId) external payable nonReentrant holderIsCaller(_holderId) {
        HolderConditions storage holder = s_holderConditions[_holderId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        if (address(this).balance >= holder.amount) {
            revert HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
        }

        uint128 amountToWithdrawInGwei = holder.amount / AMOUNT_IN_GWEI;

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
        emit HolderWithdrawFromConsensusSuccess(msg.sender, _holderId, holder.amount, isFullExit);

        (bool success,) = WITHDRAWAL_PRECOMPILE.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }
    }

    /// @notice Validator that has no unpayed bonds can withdraw everything from contract
    /// @notice If validator has unpayed bonds, than it can withdraw only `availableAmount` or less
    function validatorWithdrawFromExecution(uint128 _amount) external nonReentrant onlyOwner {
        if (s_validatorConditions.unrepayedBonds > 0) {
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

    /// @notice Validator can withdraw from consensus as much as it wants, even perform an exit. Holders funds are still covered
    function validatorWithdrawFromConsensus(uint128 _amount) external payable nonReentrant onlyOwner {
        if (s_validatorConditions.unrepayedBonds > 0) {
            if (_amount > s_validatorConditions.availableAmount) {
                revert ValidatorDoesNotHaveEnoughAvailableAmount();
            } else {
                s_validatorConditions.availableAmount -= _amount;
            }
        }

        // Check msg.value before calling precompile - it's needed to send 1 gwei in order to call precompile
        if (msg.value < 1) revert InsufficientPrecompileFee();

        uint128 amountInGwei = _amount / AMOUNT_IN_GWEI;

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(i_public_key_part1, i_public_key_part2, SafeCast.toUint64(amountInGwei));

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
    /// @param _deposit_data_root Validator must create deposit data root off chain. It can be done using Using JavaScript with @chainsafe/ssz with validator public signing key and the amount intented to add
    /// @param _more_available_amount It can be calculated off chain how much available amount can increase when deposit of more ETH is made to a validator
    // TODO: Test this! When validator adds funds we can safely update `availableAmount` with new amount, dont we?
    // TODO: Check what how to create deposit_data_root, what if we send wrong one? Does .deposit returns success?
    function validatorAddFundsToConsensus(bytes32 _deposit_data_root, uint128 _more_available_amount)
        external
        payable
        nonReentrant
        onlyOwner
    {
        if (msg.value == 0) revert ZeroAmount();

        uint128 msg_value_128 = SafeCast.toUint128(msg.value);

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg_value_128}(
            abi.encodePacked(i_public_key_part1, i_public_key_part2),
            new bytes(32), //withdraw credentials
            new bytes(96), //signature
            _deposit_data_root
        );

        s_validatorConditions.availableAmount += _more_available_amount;

        emit ValidatorFundsAdded(msg_value_128);
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
            s_validatorConditions.unrepayedBonds--;
        }
        delete s_holderConditions[_holderId];
    }
}
