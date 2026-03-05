//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import {Interest} from "./libraries/Interest.sol";
import {Penalty} from "./libraries/Penalty.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Coffer
 * @author Coffer Team
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple holders per validator with transferable
 * receivable NFT instruments representing ownership of an offer
 * @notice Uses EIP-7002 for withdrawals from consensus layer
 * to smart contract
 * @notice Uses EIP-7251 for transforming validator to compounding
 * (0x02 withdrawal credentials)
 * @notice Uses IDepositContract interface to allow deposits to
 * consensus layer to top up validator's effective balance
 */
contract Coffer is Ownable, Multicall {
    error ZeroValue();
    error ValueTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();
    error InvalidSafeTotalStake();

    error ValidatorHasExited();
    error ValidatorIsNotActive();
    error ValidatorDoesntCoverTheValue();
    error ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
    error ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
    error ValidatorCannotForbidExitsWhileOutstandingBondExists();
    error ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist();
    error ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists();
    error ValidatorConditionsVersionMismatch();
    error ValidatorDepositValueTooLow();
    error ValidatorDepositValueNotMultipleOfGwei();

    error HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
    error HolderDoesNotExistOrAlreadyWithdrawnValue();
    error HoldersTimeHasNotExpiredYet();
    error HolderCannotBeValidator();

    error CallerIsNotHolder();
    error ContractBalanceLessThanValue();

    error WithdrawlContractCallFailed();
    error ConsolidationContractCallFailed();
    error InsufficientFee();

    /// @notice When block.timestamp >= startTimestamp + duration, the bond reaches maturity
    struct HolderConditions {
        uint128 bondMaturityValue;
        uint32 duration;
        uint32 startTimestamp;
    }

    /// @param issueSize - After finishing Coffer setup, this parameter has
    /// value close to consensus + execution balance minus potential max penalties.
    /// Validator can change this parameter to control holder certainty of
    /// return, but it has to be less than consensus + execution balance minus
    /// penalty costs for bonds to be safe. This value represents how much the
    /// validator can use to issue bonds. When a holder buys a bond, it is decreased
    /// by the bond value with interest.
    /// @param version - Safe measure for holders. Prevents malicious
    /// validator from frontrunning attacks when holder buys a bond.
    /// @param safeTotalStake - Represents the safe total stake on the network
    /// used to calculate potential penalties. A larger difference
    /// (real total stake - safeTotalStake) is safer but issueSize is less.
    /// Validator should set it close to but slightly lower than the real total stake.
    /// Can always be increased when no unmatured bonds exist and decreased
    /// anytime.
    /// @param outstandingBonds - Counter for bonds not redeemed yet.
    /// Those bonds may or may not have matured.
    /// @param isActive - Represents if validator is willing to issue a
    /// bond or not. Can switch on/off at own will.
    /// @param exitAllowed - If (effective balance - (issueSize + max penalties) < 32)
    /// the holder can find themselves in a situation where they are unable to claim a matured bond
    /// and the only way to do it is to exit the validator. In those situations, a
    /// validator without exitAllowed == true is considered unsafe.
    /// If (effective balance - (issueSize + max penalties) > 32) then
    /// exitAllowed can be false and validator is considered safe.

    struct ValidatorConditions {
        uint128 issueSize;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumValueToAccept;
        uint32 version;
        uint32 outstandingBonds;
        uint32 safeTotalStake;
        bool isActive;
        bool exitAllowed;
    }

    /// @notice Last 8 bytes in WITHDRAWAL_CONTRACT represent
    /// withdrawal amount in Gwei (not wei)
    /// @notice If the last 8 bytes are 0, then a full exit is initiated
    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice Address of the DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice Address of the consolidation contract
    address private constant CONSOLIDATION_CONTRACT = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    /// @notice Every validator created by CofferFactory is initially a
    /// validator with 32 ETH effective balance
    uint256 private constant STARTING_EFFECTIVE_BALANCE_FOR_0X00 = 32 ether;
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    // Total ETH staked amount that shouldn't be reached in 100 years
    uint256 private constant MAX_SAFE_TOTAL_STAKE = 300_000_000;

    /// @notice 100% interest rate is the maximum allowed, it can have
    /// up to 8 decimal places, e.g. 10% is represented as 1e7
    uint256 private constant MAX_RATE = 1e8; // 1e8 = 100%
    uint256 private constant GWEI_RATE = 1e9;

    /// @notice Address of the shared CofferBondNft contract
    address public immutable I_COFFER_BOND_NFT_ADDRESS;
    /// @notice First 32 bytes of the validator BLS signing public key
    /// (immutable so validator cannot point contract to different validator)
    bytes32 public immutable I_PUBLIC_KEY_PART1;
    /// @notice Last 16 bytes of the validator BLS signing public key
    bytes16 public immutable I_PUBLIC_KEY_PART2;

    /// @notice Current validator conditions for bond issuance
    ValidatorConditions public sValidatorConditions;
    /// @notice Holder conditions mapped by ERC721 bond NFT ID
    mapping(uint256 => HolderConditions) public sHolderConditions;

    /// @notice Emitted when a holder buys a bond
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param bondMaturityValue The value of the bond at maturity
    /// @param duration The bond duration in seconds
    event BondBought(
        address indexed holderAddress, uint256 indexed bondId, uint128 indexed bondMaturityValue, uint32 duration
    );
    /// @notice Emitted when a holder withdraws from execution layer
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    event HolderWithdrawFromExecutionSuccess(address indexed holderAddress, uint256 indexed bondId);
    /// @notice Emitted when holder initiates consensus layer withdrawal
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param value The value being withdrawn
    /// @param isFullExit Whether this is a full validator exit
    event HolderWithdrawFromConsensusSuccess(
        address indexed holderAddress, uint256 indexed bondId, uint128 value, bool indexed isFullExit
    );
    /// @notice Emitted when validator redeems a bond early
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param valueOwed The value owed to the holder
    event ValidatorsBondRedeem(address indexed holderAddress, uint256 indexed bondId, uint128 indexed valueOwed);
    /// @notice Emitted when validator withdraws from execution layer
    /// @param amount The amount withdrawn
    event ValidatorWithdrawFromExecution(uint128 indexed amount);
    /// @notice Emitted when validator withdraws from consensus layer
    /// @param amount The amount withdrawn in gwei
    event ValidatorWithdrawFromConsensus(uint128 indexed amount);
    /// @notice Emitted when validator adds funds to consensus layer
    /// @param amount The amount of funds added
    event ValidatorFundsAdded(uint128 indexed amount);
    /// @notice Emitted when Coffer is activated
    event CofferActivated();
    /// @notice Emitted when Coffer is deactivated
    event CofferDeactivated();
    /// @notice Emitted when Coffer allows holder exits
    event CofferAllowsHolderToExit();
    /// @notice Emitted when Coffer forbids holder exits
    event CofferForbidsHolderToExit();
    /// @notice Emitted when interest rate changes
    /// @param oldRate The previous interest rate
    /// @param newRate The new interest rate
    event InterestRateChanged(uint32 indexed oldRate, uint32 indexed newRate);
    /// @notice Emitted when duration range changes
    /// @param minimumDuration The new minimum duration
    /// @param maximumDuration The new maximum duration
    event DurationRangeChanged(uint32 indexed minimumDuration, uint32 indexed maximumDuration);
    /// @notice Emitted when issue size changes
    /// @param oldIssueSize The previous issue size
    /// @param newIssueSize The new issue size
    event IssueSizeChanged(uint128 indexed oldIssueSize, uint128 indexed newIssueSize);
    /// @notice Emitted when minimum accepted value changes
    /// @param newMinimum The new minimum value
    event MinimumValueChanged(uint128 indexed newMinimum);
    /// @notice Emitted when safe total stake changes
    /// @param oldSafeTotalStake The previous safe total stake
    /// @param newSafeTotalStake The new safe total stake
    event SafeTotalStakeChanged(uint32 indexed oldSafeTotalStake, uint32 indexed newSafeTotalStake);
    /// @notice Emitted when validator converts to compounding
    event ValidatorConvertedToCompounding();

    ///--------------------------
    ///
    /// CONSTRUCTOR
    ///
    ///--------------------------

    constructor(
        address _owner,
        address _cofferBondNftAddress,
        bytes32 _publicKeyPart1,
        bytes16 _publicKeyPart2,
        uint32 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _minimumValueToAccept,
        uint32 _safeTotalStake,
        bool _exitAllowed
    ) Ownable(_owner) {
        I_COFFER_BOND_NFT_ADDRESS = _cofferBondNftAddress;
        I_PUBLIC_KEY_PART1 = _publicKeyPart1;
        I_PUBLIC_KEY_PART2 = _publicKeyPart2;

        sValidatorConditions = ValidatorConditions({
            issueSize: 0,
            interestRate: _interestRate,
            minimumDuration: _minimumDuration,
            maximumDuration: _maximumDuration,
            minimumValueToAccept: _minimumValueToAccept,
            version: 1,
            outstandingBonds: 0,
            safeTotalStake: _safeTotalStake,
            isActive: true,
            exitAllowed: _exitAllowed
        });

        if (_exitAllowed) {
            // forge-lint: disable-next-line(unsafe-typecast)
            // penalty always fits uint128 because of value,
            // safe total stake and duration limits in CofferFactory
            sValidatorConditions.issueSize = uint128(
                Penalty.addMaximumPenalty(
                    STARTING_EFFECTIVE_BALANCE_FOR_0X00, _safeTotalStake, _maximumDuration / NUMBER_OF_SECONDS_IN_EPOCH
                )
            );
        }
    }

    /// @notice Receive ETH (validator rewards and withdrawals will come here)
    /// @notice A validator can send ETH here to prevent holder initiating exit
    /// @dev Empty body is intentional - contract relies on address(this).balance checks
    /// @dev Anyone can send ETH but only validator/holders benefit from it
    receive() external payable {}

    ///--------------------------
    ///
    /// EXTERNAL FUNCTIONS
    ///
    ///--------------------------

    /// @notice Function in which msg.sender buys a bond
    /// @param _duration Holder defines the duration, which must be within the validator's offered interval
    /// @param _version Version must match the current validator's version to prevent front-runs
    /// @notice Holder sends the bond value as msg.value
    /// @notice Function creates an NFT which gives msg.sender ownership of a bond
    function buyBond(uint32 _duration, uint32 _version) external payable {
        ValidatorConditions storage vs = sValidatorConditions;

        require(vs.version == _version, ValidatorConditionsVersionMismatch());
        // solhint-disable-next-line gas-strict-inequalities
        require(msg.value >= vs.minimumValueToAccept, ValueTooSmallToAccept());
        require(vs.isActive, ValidatorIsNotActive());
        require(msg.sender != owner(), HolderCannotBeValidator());
        require(_duration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_duration >= vs.minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_duration <= vs.maximumDuration, InvalidDuration());

        uint256 bondMaturityValue = msg.value + Interest.calculateInterest(msg.value, _duration, vs.interestRate);

        // solhint-disable-next-line gas-strict-inequalities
        require(bondMaturityValue <= vs.issueSize, ValidatorDoesntCoverTheValue());

        // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
        vs.issueSize -= uint128(bondMaturityValue);
        ++vs.outstandingBonds;

        // Mint NFT representing the bond
        uint256 bondId = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).mintCofferBond(msg.sender);

        // Store coffer conditions using bondId as key
        sHolderConditions[bondId] = HolderConditions({
            duration: _duration,
            startTimestamp: uint32(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
            bondMaturityValue: uint128(bondMaturityValue)
        });

        emit BondBought(
            msg.sender,
            bondId,
            // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
            uint128(bondMaturityValue),
            _duration
        );

        Address.sendValue(payable(owner()), msg.value);
    }

    /// @notice Redeem bonds early
    /// @notice Only the validator can call this function
    /// @notice Bonds are redeemed from the Coffer contract
    /// @notice If the contract doesn't have enough to repay,
    /// the validator can send additional funds via msg.value
    /// @param _bondIds Bond IDs of the bonds to be redeemed early
    function redeemBondsEarly(uint256[] calldata _bondIds) external payable onlyOwner {
        for (uint256 i = 0; i < _bondIds.length; ++i) {
            uint256 bondId = _bondIds[i];
            HolderConditions storage holder = sHolderConditions[bondId];
            uint128 value = holder.bondMaturityValue;

            require(value != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());

            // solhint-disable-next-line gas-strict-inequalities
            require(address(this).balance >= value, ContractBalanceLessThanValue());

            address holderAddress = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).ownerOf(bondId);
            removeHolder(bondId, value);

            emit ValidatorsBondRedeem(holderAddress, bondId, value);

            Address.sendValue(payable(holderAddress), value);
        }
    }

    /// @notice Change the Coffer's activity
    /// @notice If the validator wants to stop issuing bonds, it can flip
    /// from active to inactive and vice versa
    function changeCofferActivity() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;
        bool newState = !vc.isActive;
        vc.isActive = newState;
        if (newState) emit CofferActivated();
        else emit CofferDeactivated();
    }

    /// @notice Validator can decrease the rate without affecting previous bonds
    /// @notice Version of validator conditions must be updated to avoid
    /// the validator front-running the holder
    /// @notice Validator must repay all outstanding bonds in order to
    /// increase the interest rate
    /// @param _rate The new interest rate to set
    function changeInterestRate(uint32 _rate) external onlyOwner {
        require(_rate != 0, InvalidRate());
        // solhint-disable-next-line gas-strict-inequalities
        require(_rate <= MAX_RATE, InvalidRate());
        ValidatorConditions storage vc = sValidatorConditions;

        require(
            // solhint-disable-next-line gas-strict-inequalities
            _rate <= vc.interestRate - 1 || vc.outstandingBonds == 0,
            ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist()
        );

        uint32 oldRate = vc.interestRate;
        vc.interestRate = _rate;
        ++vc.version;
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice Validator can change the duration period without
    /// affecting previous bonds since the duration is defined when a bond is bought
    /// @notice The duration period cannot affect the holder while buying a bond,
    /// so the version doesn't have to be updated
    /// @param _minimumDuration The new minimum duration in seconds
    /// @param _maximumDuration The new maximum duration in seconds
    function changeMinimumAndMaximumDuration(uint32 _minimumDuration, uint32 _maximumDuration) external onlyOwner {
        require(_minimumDuration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration >= _minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration <= MAX_DURATION, InvalidDuration());
        ValidatorConditions storage vc = sValidatorConditions;
        vc.minimumDuration = _minimumDuration;
        vc.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice Validator can change the minimum value to accept
    /// without affecting previous bonds
    /// @notice The minimum value the validator is willing to accept cannot
    /// affect the holder while buying, so the version doesn't have to be updated
    /// @param _value The new minimum value to accept
    function changeMinimumValueToAccept(uint128 _value) external onlyOwner {
        require(_value != 0, ZeroValue());
        sValidatorConditions.minimumValueToAccept = _value;
        emit MinimumValueChanged(_value);
    }

    /// @notice This function is called by the validator to change
    /// the issueSize
    /// @notice Validator should consider not increasing it too much.
    /// Must satisfy: effective balance >= issueSize + possible penalties
    /// @notice Version of validator conditions must be updated to
    /// avoid the validator front-running the holder
    /// @notice Validator must repay all outstanding bonds in order
    /// to increase issueSize
    /// @param _issueSize The new issue size
    function changeIssueSize(uint128 _issueSize) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable-next-line gas-strict-inequalities
        require(
            _issueSize < vc.issueSize || vc.outstandingBonds == 0,
            ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist()
        );

        // solhint-disable-next-line gas-strict-inequalities
        require(_issueSize >= vc.minimumValueToAccept, ValueTooSmallToAccept());

        uint128 oldIssueSize = vc.issueSize;
        vc.issueSize = _issueSize;
        ++vc.version;

        emit IssueSizeChanged(oldIssueSize, _issueSize);
    }

    /// @notice This function is called by the validator to allow or
    /// forbid exits for the holder
    /// @notice Version of validator conditions must be updated to
    /// avoid the validator front-running the holder
    function changeExitAllowed() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        require(!vc.exitAllowed || vc.outstandingBonds == 0, ValidatorCannotForbidExitsWhileOutstandingBondExists());

        vc.exitAllowed = !vc.exitAllowed;

        ++vc.version;

        if (vc.exitAllowed == true) emit CofferAllowsHolderToExit();
        else emit CofferForbidsHolderToExit();
    }

    /// @notice This function is called by the validator to update
    /// the safe total stake
    /// @notice Version of validator conditions must be updated to
    /// avoid the validator front-running the holder
    /// @notice Validator can decrease safeTotalStake at will
    /// @notice Validator must repay all outstanding bonds in order
    /// to increase safeTotalStake
    /// @param _safeTotalStake The new safe total stake value
    function changeSafeTotalStake(uint32 _safeTotalStake) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable-next-line gas-strict-inequalities
        require(
            _safeTotalStake < vc.safeTotalStake || vc.outstandingBonds == 0,
            ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist()
        );

        require(_safeTotalStake != 0, InvalidSafeTotalStake());
        // solhint-disable-next-line gas-strict-inequalities
        require(_safeTotalStake <= MAX_SAFE_TOTAL_STAKE, InvalidSafeTotalStake());

        uint32 oldSafeTotalStake = vc.safeTotalStake;
        vc.safeTotalStake = _safeTotalStake;

        ++vc.version;

        emit SafeTotalStakeChanged(oldSafeTotalStake, _safeTotalStake);
    }

    /// @notice Holder withdraws matured bond from execution layer
    /// @notice Should be called when the contract has enough balance
    /// to cover the holder's bond value
    /// @notice Validator or holder can trigger a consensus withdrawal
    /// to fill up the contract with ETH
    /// @notice If the validator allows holder exit, it can issue bonds for
    /// almost all the consensus amount even if it drops below 32.
    /// Penalties should be considered only while defining issueSize.
    /// @notice If the validator does not allow holder exit, the holder can
    /// withdraw from consensus only the owed value after maturity
    /// @notice The BondNft owner can withdraw using their bondId
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromExecution(uint256 _bondId) external {
        HolderConditions storage holder = sHolderConditions[_bondId];

        require(holder.bondMaturityValue != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());

        holderIsCaller(_bondId);

        // Has time passed so holder can withdraw
        // solhint-disable-next-line gas-strict-inequalities
        require(holder.duration + holder.startTimestamp <= block.timestamp, HoldersTimeHasNotExpiredYet());

        // Verify contract has enough balance to cover the value the creditor wants to withdraw
        // solhint-disable-next-line gas-strict-inequalities
        require(address(this).balance >= holder.bondMaturityValue, ContractBalanceLessThanValue());

        uint128 valueToWithdraw = holder.bondMaturityValue;

        removeHolder(_bondId, valueToWithdraw);

        emit HolderWithdrawFromExecutionSuccess(msg.sender, _bondId);

        Address.sendValue(payable(msg.sender), valueToWithdraw);
    }

    /// @notice Holder initiates consensus layer withdrawal
    /// @notice If the validator allows exits, the holder will always exit
    /// the validator if possible since we cannot properly check the exact
    /// value vs. full exit
    /// @notice If the contract has enough to redeem the bond, the holder cannot
    /// withdraw from consensus
    /// @notice The validator can avoid exits by topping up the contract
    /// @dev Holder's bond value is in wei, so we must convert it to gwei
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromConsensus(uint256 _bondId) external payable {
        HolderConditions storage holder = sHolderConditions[_bondId];

        require(holder.bondMaturityValue != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());

        holderIsCaller(_bondId);

        require(
            // solhint-disable-next-line gas-strict-inequalities
            address(this).balance <= holder.bondMaturityValue - 1,
            HolderConsensusWithdrawNotPossibleContractHasEnoughBalance()
        );

        // Has time passed so holder can withdraw
        // solhint-disable-next-line gas-strict-inequalities
        require(holder.duration + holder.startTimestamp <= block.timestamp, HoldersTimeHasNotExpiredYet());

        uint64 valueToWithdrawInGwei = 0;
        // If the contract allows exits, 0 should be sent in data; if not, the value should be converted to gwei
        if (!sValidatorConditions.exitAllowed) {
            // forge-lint: disable-next-line(unsafe-typecast) holder.bondMaturityValue < 2048 ETH, fits uint64
            valueToWithdrawInGwei = uint64(holder.bondMaturityValue / GWEI_RATE);
        }

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        require(readOk, WithdrawlContractCallFailed());
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check that the fee is not too high.
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= msg.value, InsufficientFee());

        // EIP-7002: 48-byte BLS public key + 8-byte withdrawal amount = 56 bytes
        bytes memory data = abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2, valueToWithdrawInGwei);

        bool isFullExit = (valueToWithdrawInGwei == 0);
        emit HolderWithdrawFromConsensusSuccess(msg.sender, _bondId, holder.bondMaturityValue, isFullExit);

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        require(writeOk, WithdrawlContractCallFailed());
    }

    /// @notice Validator withdraws from execution layer when no
    /// outstanding bonds exist
    /// @notice Version of validator conditions must be updated to
    /// avoid the validator front-running the holder
    /// @param _amount The amount to withdraw
    function validatorWithdrawFromExecution(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        require(vc.outstandingBonds == 0, ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists());

        // solhint-disable-next-line gas-strict-inequalities
        require(_amount <= address(this).balance, ContractBalanceLessThanValue());

        ++vc.version;

        emit ValidatorWithdrawFromExecution(_amount);

        Address.sendValue(payable(msg.sender), _amount);
    }

    /// @notice Validator can withdraw from consensus as much as it
    /// wants, even perform an exit. Holders' funds are still covered.
    /// @dev If _amount == 0, a full exit is initiated; otherwise a partial
    /// withdrawal is initiated. When the validator exits, there shouldn't be any flags in
    /// the contract to switch since the validator can bypass the contract and exit
    /// through the beacon chain directly. The contract must work whenever
    /// the validator chooses to exit.
    /// @dev If _amount != 0, a partial withdrawal will be initiated.
    /// The validator should be aware it cannot withdraw from the Coffer while
    /// there are outstanding bonds.
    /// @dev If we try to partially withdraw an amount that would lower
    /// the effective balance below 32, WITHDRAWAL_CONTRACT won't revert;
    /// the beacon chain would withdraw a smaller amount to keep the balance at 32.
    /// @dev This function is called using gwei, not wei, since
    /// the beacon chain operates in gwei
    /// @param _amount The amount to withdraw in gwei
    function validatorWithdrawFromConsensus(uint64 _amount) external payable onlyOwner {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        require(readOk, WithdrawlContractCallFailed());
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check that the fee is not too high.
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= msg.value, InsufficientFee());

        // Construct the 56-byte payload:
        // [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2, _amount);

        emit ValidatorWithdrawFromConsensus(_amount);

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        require(writeOk, WithdrawlContractCallFailed());
    }

    /// @notice Validator can add funds at will
    /// @param _depositDataRoot Validator must create the deposit data root
    /// off-chain using JavaScript with the ChainSafe/ssz library,
    /// the validator public signing key, and the intended amount.
    function validatorAddFundsToConsensus(bytes32 _depositDataRoot) external payable onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        require(msg.value >= 1 ether, ValidatorDepositValueTooLow());
        require(msg.value % GWEI_RATE == 0, ValidatorDepositValueNotMultipleOfGwei());

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg.value}(
            abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2),
            new bytes(32), // withdrawal credentials can be all 0
            new bytes(96), // signature can be all 0
            _depositDataRoot
        );

        ValidatorConditions storage vc = sValidatorConditions;

        // forge-lint: disable-next-line(unsafe-typecast) penalty on msg.value (≤ validator balance) fits uint128
        vc.issueSize += uint128(
            Penalty.addMaximumPenalty(msg.value, vc.safeTotalStake, vc.maximumDuration / NUMBER_OF_SECONDS_IN_EPOCH)
        );

        // forge-lint: disable-next-line(unsafe-typecast) msg.value checked ≥ 1 ether and is gwei-aligned, fits uint128
        emit ValidatorFundsAdded(uint128(msg.value));
    }

    /// @notice Should be called after the contract address is successfully
    /// assigned to the validator's BLS public key
    function convertToCompounding() external payable onlyOwner {
        (bool readOk, bytes memory feeData) = CONSOLIDATION_CONTRACT.staticcall("");
        require(readOk, ConsolidationContractCallFailed());
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= msg.value, InsufficientFee());

        // Source and target are the same for self-consolidation
        bytes memory data = abi.encodePacked(
            //source
            I_PUBLIC_KEY_PART1,
            I_PUBLIC_KEY_PART2,
            //target
            I_PUBLIC_KEY_PART1,
            I_PUBLIC_KEY_PART2
        );

        (bool success,) = CONSOLIDATION_CONTRACT.call{value: fee}(data);
        require(success, ConsolidationContractCallFailed());

        emit ValidatorConvertedToCompounding();
    }

    ///--------------------------
    ///
    /// PRIVATE FUNCTIONS
    ///
    ///--------------------------

    /// @notice Cleans up holder data and updates validator data
    /// @notice Used in: redeemBondsEarly and holderWithdrawFromExecution
    /// @dev _bondId is verified in callers so no check here
    /// @param _bondId The ID of the bond NFT to remove
    /// @param _value The value to restore to issueSize
    function removeHolder(uint256 _bondId, uint256 _value) private {
        ValidatorConditions storage vc = sValidatorConditions;
        // forge-lint: disable-next-line(unsafe-typecast) _value originates from HolderConditions.bondMaturityValue
        vc.issueSize += uint128(_value);
        --vc.outstandingBonds;
        ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).burnCofferBond(_bondId);
        delete sHolderConditions[_bondId];
    }

    /// @notice Checks if msg.sender owns the bond NFT
    /// @notice Used in: holderWithdrawFromConsensus and
    /// holderWithdrawFromExecution
    /// @dev _bondId is verified in callers so no check here
    /// @param _bondId The ID of the bond NFT to check ownership
    function holderIsCaller(uint256 _bondId) private view {
        require(msg.sender == ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).ownerOf(_bondId), CallerIsNotHolder());
    }
}
