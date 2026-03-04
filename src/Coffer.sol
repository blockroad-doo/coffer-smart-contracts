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
    error ZeroAmount();
    error AmountTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();
    error InvalidSafeTotalStake();

    error ValidatorHasExited();
    error ValidatorIsNotActive();
    error ValidatorDoesntCoverTheAmount();
    error ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
    error ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
    error ValidatorCannotForbidExitsWhileOutstandingBondExists();
    error ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist();
    error ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists();
    error ValidatorConditionsVersionMismatch();
    error ValidatorDepositValueTooLow();
    error ValidatorDepositValueNotMultipleOfGwei();

    error HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
    error HolderDoesNotExistOrAlreadyWithdrawnAmount();
    error HoldersTimeHasNotExpiredYet();
    error HolderCannotBeValidator();

    error CallerIsNotHolder();
    error ContractBalanceLessThanAmount();

    error WithdrawlContractCallFailed();
    error ConsolidationContractCallFailed();
    error InsufficientFee();

    /// @notice after startTimestamp + duration >= block.timestamp, bond reaches maturity
    struct HolderConditions {
        uint128 amount;
        uint32 duration;
        uint32 startTimestamp;
    }

    /// @param issueSize Initially set to 32 eth; after Coffer setup it has
    /// value close to real beacon chain balance minus potential max penalties.
    /// Validator can change this parameter to control holder certainty of
    /// return. Must be less than consensus balance minus penalty costs for
    /// bonds to be safe. Total amount validator can use to issue bonds.
    /// When holder buys a bond, decreased by bond amount with interest.
    /// Also represents amount validator can withdraw from consensus.
    /// @param version Safe measure for holders. Prevents malicious
    /// validator from frontrunning attacks when holder buys a bond.
    /// @param safeTotalStake Represents safe total stake on network
    /// used to calculate potential penalties. Larger difference
    /// (real total stake - safeTotalStake) is safer but issueSize is less.
    /// Validator should be close but slightly lower than real total stake.
    /// Can always be changed when no unmatured bonds exist.
    /// @param outstandingBonds Counter for bonds not redeemed yet.
    /// Those bonds can be matured or not.
    /// @param isActive Represents if validator is willing to issue a
    /// bond or not. Can switch on/off at own will.
    /// @param exitAllowed If (validator effective balance on beacon
    /// chain - issueSize < 32) holder has no other way to claim matured
    /// bond other than to exit validator, if not enough ETH on Coffer.
    /// Validator without exitAllowed==true is considered unsafe.
    /// If (effective balance - (issueSize + max penalties) > 32) then
    /// exitAllowed can be false and validator is considered safe.

    struct ValidatorConditions {
        uint128 issueSize;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumAmountToAccept;
        uint32 version;
        uint32 outstandingBonds;
        uint32 safeTotalStake;
        bool isActive;
        bool exitAllowed;
    }

    /// @notice last 8 bytes in WITHDRAWAL_CONTRACT represents
    /// withdraw amount in Gwei (not wei)
    /// @notice if last 8 bytes are 0, then full exit is initiated
    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice address of DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice address of consolidation contract
    address private constant CONSOLIDATION_CONTRACT = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    /// @notice every validator created by CofferFactory is initially
    /// validator with 32 ETH effective balance
    uint256 private constant STARTING_EFFECTIVE_BALANCE_FOR_0X00 = 32 ether;
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    // total ETH amount that size shouldn't be reached in 100 years
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
    /// @param amount The amount deposited by the holder
    /// @param duration The bond duration in seconds
    /// @param amountWithInterest The total amount owed at maturity
    event HolderAcceptedOffer(
        address indexed holderAddress,
        uint256 indexed bondId,
        uint128 indexed amount,
        uint32 duration,
        uint128 amountWithInterest
    );
    /// @notice Emitted when a holder withdraws from execution layer
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    event HolderWithdrawFromExecutionSuccess(address indexed holderAddress, uint256 indexed bondId);
    /// @notice Emitted when holder initiates consensus layer withdrawal
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param amount The amount being withdrawn
    /// @param isFullExit Whether this is a full validator exit
    event HolderWithdrawFromConsensusSuccess(
        address indexed holderAddress, uint256 indexed bondId, uint128 amount, bool indexed isFullExit
    );
    /// @notice Emitted when validator redeems a bond early
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param amountOwed The amount owed to the holder
    event ValidatorsBondRedeem(address indexed holderAddress, uint256 indexed bondId, uint128 indexed amountOwed);
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
    /// @param oldAmount The previous issue size
    /// @param newAmount The new issue size
    event IssueSizeChanged(uint128 indexed oldAmount, uint128 indexed newAmount);
    /// @notice Emitted when minimum accepted amount changes
    /// @param newMinimum The new minimum amount
    event MinimumAmountChanged(uint128 indexed newMinimum);
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
        uint128 _minimumAmountToAccept,
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
            minimumAmountToAccept: _minimumAmountToAccept,
            version: 1,
            outstandingBonds: 0,
            safeTotalStake: _safeTotalStake,
            isActive: true,
            exitAllowed: _exitAllowed
        });

        if (_exitAllowed) {
            // forge-lint: disable-next-line(unsafe-typecast)
            // penalty always fits uint128 because of amount,
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

    /// @notice Function in which msg.sender buys bond
    /// @param _duration holder defines duration which must be in validator's offered interval
    /// @param _version version must fit with current validator's version to prevent frontruns
    /// @notice holder sends bonds amount within msg.value
    /// @notice Function creates NFT which gives msg.sender ownership of a bond
    function buyBond(uint32 _duration, uint32 _version) external payable {
        ValidatorConditions storage vs = sValidatorConditions;

        if (vs.version != _version) revert ValidatorConditionsVersionMismatch();
        if (msg.value < vs.minimumAmountToAccept) {
            revert AmountTooSmallToAccept();
        }
        if (vs.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == owner()) revert HolderCannotBeValidator();
        if (_duration == 0) revert InvalidDuration();
        if (_duration < vs.minimumDuration) revert InvalidDuration();
        if (_duration > vs.maximumDuration) revert InvalidDuration();

        uint256 amountWithInterest = msg.value + Interest.calculateInterest(msg.value, _duration, vs.interestRate);

        if (amountWithInterest > vs.issueSize) {
            revert ValidatorDoesntCoverTheAmount();
        }

        // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
        vs.issueSize -= uint128(amountWithInterest);
        ++vs.outstandingBonds;

        // Mint NFT representing the bond
        uint256 bondId = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).mintCofferBond(msg.sender);

        // Store coffer conditions using bondId as key
        sHolderConditions[bondId] = HolderConditions({
            duration: _duration,
            startTimestamp: uint32(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
            amount: uint128(amountWithInterest)
        });

        emit HolderAcceptedOffer(
            msg.sender,
            bondId,
            // forge-lint: disable-next-line(unsafe-typecast) msg.value bounded by uint128 issueSize check
            uint128(msg.value),
            _duration,
            // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
            uint128(amountWithInterest)
        );

        Address.sendValue(payable(owner()), msg.value);
    }

    /// @notice Redeem bonds early
    /// @notice Only validator can call this function
    /// @notice Amounts are redeemed from Coffer contract
    /// @notice If contract doesn't have enough amount to repay,
    /// validator can send additional amount using msg.value
    /// @param _bondIds Bond IDs which bonds are intended to redeem early
    function redeemBondsEarly(uint256[] calldata _bondIds) external payable onlyOwner {
        for (uint256 i = 0; i < _bondIds.length; ++i) {
            uint256 bondId = _bondIds[i];
            HolderConditions storage holder = sHolderConditions[bondId];
            uint128 amount = holder.amount;

            if (amount == 0) {
                revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
            }

            if (address(this).balance < amount) {
                revert ContractBalanceLessThanAmount();
            }

            address holderAddress = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).ownerOf(bondId);
            removeHolder(bondId, amount);

            emit ValidatorsBondRedeem(holderAddress, bondId, amount);

            Address.sendValue(payable(holderAddress), amount);
        }
    }

    /// @notice Change Coffers activity
    /// @notice If validator wants to stop issuing bonds it can flip
    /// from active to inactive and vice versa
    function changeCofferActivity() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;
        bool newState = !vc.isActive;
        vc.isActive = newState;
        if (newState) emit CofferActivated();
        else emit CofferDeactivated();
    }

    /// @notice validator can decrease its rate without affecting previous bonds
    /// @notice version of validator conditions must be updated to avoid
    /// validator frontrun holder
    /// @notice validator must repay all outstanding bonds in order to
    /// increase interestRate
    /// @param _rate The new interest rate to set
    function changeInterestRate(uint32 _rate) external onlyOwner {
        if (_rate == 0 || _rate > MAX_RATE) revert InvalidRate();
        ValidatorConditions storage vc = sValidatorConditions;

        if (_rate > vc.interestRate - 1 && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
        }

        uint32 oldRate = vc.interestRate;
        vc.interestRate = _rate;
        ++vc.version;
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice validator can change its duration period without
    /// affecting previous bonds since duration is defined when bond is bought
    /// @notice duration period cannot affect holder while buying a bond
    /// so version doesn't have to be updated
    /// @param _minimumDuration The new minimum duration in seconds
    /// @param _maximumDuration The new maximum duration in seconds
    function changeMinimumAndMaximumDuration(uint32 _minimumDuration, uint32 _maximumDuration) external onlyOwner {
        if (_maximumDuration > MAX_DURATION || _maximumDuration < _minimumDuration || _minimumDuration == 0) {
            revert InvalidDuration();
        }
        ValidatorConditions storage vc = sValidatorConditions;
        vc.minimumDuration = _minimumDuration;
        vc.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice validator can change its minimum amount to accept the
    /// bond without affecting previous bonds
    /// @notice minimum amount validator is willing to accept cannot
    /// affect holder while buying so version doesn't have to be updated
    /// @param _amount The new minimum amount to accept
    function changeMinimumAmountToAccept(uint128 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        sValidatorConditions.minimumAmountToAccept = _amount;
        emit MinimumAmountChanged(_amount);
    }

    /// @notice this function is called by the validator to change
    /// the issueSize
    /// @notice validator should consider not to increase too much.
    /// Must satisfy: effective balance >= issueSize + possible penalties
    /// @notice version of validator conditions must be updated to
    /// avoid validator frontrun holder
    /// @notice validator must repay all outstanding bonds in order
    /// to increase issueSize
    /// @param _amount The new issue size
    function changeIssueSize(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable-next-line gas-strict-inequalities
        if (_amount >= vc.issueSize && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
        }

        if (_amount < vc.minimumAmountToAccept) revert AmountTooSmallToAccept();

        uint128 oldAmount = vc.issueSize;
        vc.issueSize = _amount;
        ++vc.version;

        emit IssueSizeChanged(oldAmount, _amount);
    }

    /// @notice This function is called by the validator to allow or
    /// forbid exits to holder
    /// @notice version of validator conditions must be updated to
    /// avoid validator frontrun holder
    function changeExitAllowed() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (vc.exitAllowed == true && vc.outstandingBonds != 0) {
            revert ValidatorCannotForbidExitsWhileOutstandingBondExists();
        }

        vc.exitAllowed = !vc.exitAllowed;

        ++vc.version;

        if (vc.exitAllowed == true) emit CofferAllowsHolderToExit();
        else emit CofferForbidsHolderToExit();
    }

    /// @notice This function is called by the validator to update
    /// safe total stake
    /// @notice version of validator conditions must be updated to
    /// avoid validator frontrun holder
    /// @notice validator can decrease safeTotalStake at will
    /// @notice validator must repay all outstanding bonds in order
    /// to increase safeTotalStake
    /// @param _safeTotalStake The new safe total stake value
    function changeSafeTotalStake(uint32 _safeTotalStake) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable-next-line gas-strict-inequalities
        if (_safeTotalStake >= vc.safeTotalStake && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist();
        }

        if (_safeTotalStake == 0 || _safeTotalStake > MAX_SAFE_TOTAL_STAKE) {
            revert InvalidSafeTotalStake();
        }

        uint32 oldSafeTotalStake = vc.safeTotalStake;
        vc.safeTotalStake = _safeTotalStake;

        ++vc.version;

        emit SafeTotalStakeChanged(oldSafeTotalStake, _safeTotalStake);
    }

    /// @notice Holder withdraws matured bond from execution layer
    /// @notice Should be called when the contract has enough balance
    /// to cover the holder's amount
    /// @notice Validator or holder can trigger consensus withdraw
    /// to fill up contract with ETH
    /// @notice If validator allows holder exit it can issue bonds for
    /// almost all consensus amount even if it drops below 32.
    /// Penalties should be considered only while defining issueSize.
    /// @notice If validator does not allow holder exit, holder can
    /// withdraw from consensus only the owed amount after maturity
    /// @notice BondNft owner can withdraw using their bondId
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromExecution(uint256 _bondId) external {
        HolderConditions storage holder = sHolderConditions[_bondId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        holderIsCaller(_bondId);

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp > block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Verify contract has enough balance to cover the amount creditor wants to withdraw
        if (address(this).balance < holder.amount) {
            revert ContractBalanceLessThanAmount();
        }

        uint128 amountToWithdraw = holder.amount;

        removeHolder(_bondId, amountToWithdraw);

        emit HolderWithdrawFromExecutionSuccess(msg.sender, _bondId);

        Address.sendValue(payable(msg.sender), amountToWithdraw);
    }

    /// @notice Holder initiates consensus layer withdrawal
    /// @notice If validator allows exits, holder will always exit
    /// validator if possible since we cannot properly check exact
    /// amount vs full exit
    /// @notice If contract has enough to redeem bond, holder cannot
    /// withdraw from consensus
    /// @notice Validator can avoid exits by topping up the contract
    /// @dev holders amount is in wei so we must convert it to gwei
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromConsensus(uint256 _bondId) external payable {
        HolderConditions storage holder = sHolderConditions[_bondId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        holderIsCaller(_bondId);

        if (address(this).balance > holder.amount - 1) {
            revert HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
        }

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp > block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        uint64 amountToWithdrawInGwei = 0;
        // if contract allows exits 0 should be sent in data, if not amount should be converted to gwei
        if (!sValidatorConditions.exitAllowed) {
            // forge-lint: disable-next-line(unsafe-typecast) holder.amount < 2048 ETH, fits uint64
            amountToWithdrawInGwei = uint64(holder.amount / GWEI_RATE);
        }

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) {
            revert WithdrawlContractCallFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check the fee is not too high.
        if (fee > msg.value) {
            revert InsufficientFee();
        }

        // EIP-7002: 48-byte BLS public key + 8-byte withdrawal amount = 56 bytes
        bytes memory data = abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2, amountToWithdrawInGwei);

        bool isFullExit = (amountToWithdrawInGwei == 0);
        emit HolderWithdrawFromConsensusSuccess(msg.sender, _bondId, holder.amount, isFullExit);

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        if (!writeOk) {
            revert WithdrawlContractCallFailed();
        }
    }

    /// @notice Validator withdraws from execution layer when no
    /// outstanding bonds exist
    /// @notice version of validator conditions must be updated to
    /// avoid validator frontrun holder
    /// @param _amount The amount to withdraw
    function validatorWithdrawFromExecution(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (vc.outstandingBonds != 0) {
            revert ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists();
        }

        if (_amount > address(this).balance) {
            revert ContractBalanceLessThanAmount();
        }

        ++vc.version;

        emit ValidatorWithdrawFromExecution(_amount);

        Address.sendValue(payable(msg.sender), _amount);
    }

    /// @notice Validator can withdraw from consensus as much as it
    /// wants, even perform an exit. Holders' funds are still covered.
    /// @dev if _amount == 0 full exit is initiated, otherwise partial
    /// withdraw. When validator exits there shouldn't be any flags in
    /// contract to switch since validator can bypass contract and exit
    /// through beacon chain directly. Contract must work whenever
    /// validator chooses to exit.
    /// @dev if _amount != 0 partial withdraw will be initiated.
    /// Validator should be aware it cannot withdraw from Coffer while
    /// there are outstanding bonds.
    /// @dev if we try to partially withdraw an amount that would lower
    /// effective balance below 32, WITHDRAWAL_CONTRACT won't revert;
    /// beacon chain would withdraw a smaller amount to keep balance at 32.
    /// @dev this function is called using gwei not wei since
    /// beacon chain operates in gwei
    /// @param _amount The amount to withdraw in gwei
    function validatorWithdrawFromConsensus(uint64 _amount) external payable onlyOwner {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) {
            revert WithdrawlContractCallFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check the fee is not too high.
        if (fee > msg.value) {
            revert InsufficientFee();
        }

        // Construct the 56-byte payload:
        // [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2, _amount);

        emit ValidatorWithdrawFromConsensus(_amount);

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        if (!writeOk) {
            revert WithdrawlContractCallFailed();
        }
    }

    /// @notice Validator can add funds at their own will
    /// @param _depositDataRoot Validator must create deposit data root
    /// off chain using JavaScript with chainsafe/ssz library,
    /// validator public signing key, and the intended amount.
    function validatorAddFundsToConsensus(bytes32 _depositDataRoot) external payable onlyOwner {
        if (msg.value < 1 ether) revert ValidatorDepositValueTooLow();
        if (msg.value % GWEI_RATE != 0) {
            revert ValidatorDepositValueNotMultipleOfGwei();
        }

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg.value}(
            abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2),
            new bytes(32), // withdraw credentials can be all 0
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

    /// @notice Should be called after contract address is successfully
    /// assigned to validator's BLS public key
    function convertToCompounding() external payable onlyOwner {
        (bool readOk, bytes memory feeData) = CONSOLIDATION_CONTRACT.staticcall("");
        if (!readOk) {
            revert ConsolidationContractCallFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        if (fee > msg.value) {
            revert InsufficientFee();
        }

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
        if (!success) {
            revert ConsolidationContractCallFailed();
        }

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
    /// @param _amount The amount to restore to issueSize
    function removeHolder(uint256 _bondId, uint256 _amount) private {
        ValidatorConditions storage vc = sValidatorConditions;
        // forge-lint: disable-next-line(unsafe-typecast) _amount originates from uint128 HolderConditions.amount
        vc.issueSize += uint128(_amount);
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
        if (msg.sender != ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).ownerOf(_bondId)) {
            revert CallerIsNotHolder();
        }
    }
}
