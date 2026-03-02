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
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple holders per validator with transferable receivable NFT instruments representing ownership of an offer
 * @notice Uses EIP-7002 for withdrawals from consensus layer to smart contract
 * @notice Uses EIP-7251 for transforming validator to compounding (0x02 withdrawl credentials)
 * @notice Uses IDepositContract interface to allow deposits to consensus layer to top up validator's effective balance
 */
contract Coffer is Ownable, Multicall {
    error ZeroAmount();
    error AmountTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();

    error ValidatorHasExited();
    error ValidatorIsNotActive();
    error ValidatorDoesntCoverTheAmount();
    error ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
    error ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
    error ValidatorCannotChangeExitAllowedWhileOutstandingBondExists();
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

    /// @param issueSize initialy this parameter is set to 32 eth and after Coffer setup is finished it has value really close to real beacon chain balance minus potential maximal penalties. Validator can change this parameter on its own and that way it determines for holder how sure they can be of the return of their funds in future. This value has to be less than validator's consensus balance, by at least a cost of penalties which could occur, in order for this validator's bonds to be safe to buy. It is the total amount that validator can use to issue bonds. When holder buys a bond, this amount is decreased by the bond amount with interest. This amount also represents amount which validator can withdraw from consensus to execution.
    /// @param version is a safe measure for holders. When holder is buying a bond version prevents malicious validator from frontruning attacks
    /// @param safeTotalStake represents safe total stake on network used to calculate potetnial penalties. The bigger difference (real total stake - safeTotalStake) is, the safer Contract is, but issueSize is less. So validator should consider to be close but a little bit lower than real total stake. If that difference becomes to close to zero or even go negative, validator can allways change that parameter, but only when it has no unmatured bonds.
    /// @param outstandingBonds counter for bonds that are not redeemed yet. Those bonds can be matured or not.
    /// @param isActive represents if validator is willing to issue a bond or not. Can switch on/off at own will
    /// @param exitAllowed - if (validator effective balance on beacon chain - issueSize < 32) holder has no other way to claim matured bond other than to exit a validator, if there are no enough ETH on Coffer contract. In those situations, validator who doesn't set (exitAllowed == true) is considered unsafe. If (validator effective balance on beacon chain - (issueSize + maximal penalties) > 32) then exitAllowed can be false and validator would be considered as safe.

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

    /// @notice last 8 bytes in WITHDRAWAL_CONTRACT represents withdraw amount in Gwei (not wei)
    /// @notice if last 8 bytes in WITHDRAWAL_CONTRACT are 0, then full exit is initiated
    address private constant WITHDRAWAL_CONTRACT =
        0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice address of DepositContract
    address private constant DEPOSIT_CONTRACT =
        0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice address of consolidation contract
    address private constant CONSOLIDATION_CONTRACT =
        0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    /// @notice every validator created by CofferFactory is initially validator with 32 ETH effective balance
    uint256 private constant STARTING_EFFECTIVE_BALANCE_FOR_0X00 = 32 ether;
    uint256 private constant NUMBER_OF_SECONDS_IN_EPOCH = 384;
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    uint256 private constant MAX_SAFE_TOTAL_STAKE = 300_000_000; // total ETH amount that size shouldn't be reached in 100 years

    /// @notice 100% interest rate is the maximum allowed, it can have up to 8 decimal places, for example, 10% interest rate is represented as 1e7
    uint256 private constant MAX_RATE = 1e8; // 1e8 = 100%, so rate has precision of 6 decimals
    uint256 private constant GWEI_RATE = 1e9;

    address public immutable I_COFFER_BOND_NFT_ADDRESS;
    // signing public key must stay immutable, it shouldn't be changed in any possible way so that validator cannot point this contract do different validator
    bytes32 public immutable I_PUBLIC_KEY_PART1;
    bytes16 public immutable I_PUBLIC_KEY_PART2;

    ValidatorConditions public sValidatorConditions;
    // uint256 represents Id of ERC721 NFT from I_COFFER_BOND_NFT_ADDRESS
    mapping(uint256 => HolderConditions) public sHolderConditions;

    event HolderAcceptedOffer(
        address indexed holderAddress,
        uint256 indexed holderId,
        uint128 amount,
        uint32 duration,
        uint128 amountWithInterest
    );
    event HolderWithdrawFromExecutionSuccess(
        address indexed holderAddress,
        uint256 indexed holderId
    );
    event HolderWithdrawFromConsensusSuccess(
        address indexed holderAddress,
        uint256 indexed holderId,
        uint128 amount,
        bool isFullExit
    );
    event ValidatorsBondRedeem(
        address indexed holderAddress,
        uint256 indexed holderId,
        uint128 amountOwed
    );
    event ValidatorWithdrawFromExecution(uint128 amount);
    event ValidatorWithdrawFromConsensus(uint128 amount);
    event ValidatorFundsAdded(uint128 amount);
    event CofferActivated();
    event CofferDeactivated();
    event CofferAllowsHolderToExit();
    event CofferForbidsHolderToExit();
    event InterestRateChanged(uint32 oldRate, uint32 newRate);
    event DurationRangeChanged(uint32 minimumDuration, uint32 maximumDuration);
    event IssueSizeChanged(uint128 oldAmount, uint128 newAmount);
    event MinimumAmountChanged(uint128 newMinimum);
    event SafeTotalStakeChanged(
        uint32 oldSafeTotalStake,
        uint32 newSafeTotalStake
    );
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
            // forge-lint: disable-next-line(unsafe-typecast) penalty always fits uint128 because of amount, safe total stake and duration limits introduced in CofferFactory
            sValidatorConditions.issueSize = uint128(Penalty.addMaximumPenalty(
                STARTING_EFFECTIVE_BALANCE_FOR_0X00,
                _safeTotalStake,
                _maximumDuration / NUMBER_OF_SECONDS_IN_EPOCH
            ));
        }
    }

    /// @notice Receive ETH (validator rewards and withdrawals will come here)
    /// @notice A validator can send ETH here in order to prevent holder to initiate an exit
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
        if (msg.value < vs.minimumAmountToAccept)
            revert AmountTooSmallToAccept();
        if (vs.isActive == false) revert ValidatorIsNotActive();
        if (msg.sender == owner()) revert HolderCannotBeValidator();
        if (_duration == 0) revert InvalidDuration();
        if (_duration < vs.minimumDuration) revert InvalidDuration();
        if (_duration > vs.maximumDuration) revert InvalidDuration();

        uint256 amountWithInterest = msg.value +
            Interest.calculateInterest(msg.value, _duration, vs.interestRate);

        if (amountWithInterest > vs.issueSize) {
            revert ValidatorDoesntCoverTheAmount();
        }

        // Mint NFT representing the bond
        uint256 holderId = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS)
            .mintCofferBond(msg.sender);

        // Store coffer conditions using holderId as key
        sHolderConditions[holderId] = HolderConditions({
            duration: _duration,
            startTimestamp: uint32(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
            amount: uint128(amountWithInterest)
        });

        // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
        vs.issueSize -= uint128(amountWithInterest);
        ++vs.outstandingBonds;

        emit HolderAcceptedOffer(
            msg.sender,
            holderId,
            // forge-lint: disable-next-line(unsafe-typecast) msg.value bounded by uint128 issueSize check
            uint128(msg.value),
            _duration,
            // forge-lint: disable-next-line(unsafe-typecast) amountWithInterest ≤ issueSize which is uint128
            uint128(amountWithInterest)
        );

        Address.sendValue(payable(owner()), msg.value);
    }

    /// @notice Reddem bonds early
    /// @notice Only validator can call this function
    /// @notice Amounts are redeemed from Coffer contract
    /// @notice If contract doesn't have enough amount to repay, validator can send additional amount using msg.value
    /// @param _holderIds Holder IDs which bonds are intended to redeem early
    function redeemBondsEarly(
        uint256[] calldata _holderIds
    ) external payable onlyOwner {
        for (uint256 i = 0; i < _holderIds.length; ++i) {
            uint256 holderId = _holderIds[i];
            HolderConditions storage holder = sHolderConditions[holderId];
            uint128 amount = holder.amount;

            if (amount == 0) {
                revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
            }

            if (address(this).balance < amount) {
                revert ContractBalanceLessThanAmount();
            }

            address holderAddress = ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS)
                .ownerOf(holderId);
            removeHolder(holderId, amount);

            emit ValidatorsBondRedeem(
                holderAddress,
                holderId,
                amount
            );

            Address.sendValue(payable(holderAddress), amount);
        }
    }

    /// @notice Change Coffers activity
    /// @notice If validator wants to stop issuing bonds it can flip from active to inactive and vice versa
    function changeCofferActivity() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;
        bool newState = !vc.isActive;
        vc.isActive = newState;
        if (newState) emit CofferActivated();
        else emit CofferDeactivated();
    }

    /// @notice validator can decrease its rate without affecting previous bonds
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    /// @notice validator must repay all outstanding bonds in order to increase interestRate
    function changeInterestRate(uint32 _rate) external onlyOwner {
        if (_rate == 0 || _rate > MAX_RATE) revert InvalidRate();
        ValidatorConditions storage vc = sValidatorConditions;

        if (_rate >= vc.interestRate && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
        }

        uint32 oldRate = vc.interestRate;
        vc.interestRate = _rate;
        ++vc.version;
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice validator can change its duration period without affecting previous bonds since duration is defined when bond is bought
    /// @notice duration period cannot affect holder while buying a bond so version doesn't have to be updated
    function changeMinimumAndMaximumDuration(
        uint32 _minimumDuration,
        uint32 _maximumDuration
    ) external onlyOwner {
        if (
            _maximumDuration > MAX_DURATION ||
            _maximumDuration < _minimumDuration ||
            _minimumDuration == 0
        ) revert InvalidDuration();
        ValidatorConditions storage vc = sValidatorConditions;
        vc.minimumDuration = _minimumDuration;
        vc.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice validator can change its minimum amount to accept the bond without affecting previous bonds
    /// @notice minimum amount validator is willing to accept cannot affect holder while buying a bond so version doesn't have to be updated
    function changeMinimumAmountToAccept(uint128 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        sValidatorConditions.minimumAmountToAccept = _amount;
        emit MinimumAmountChanged(_amount);
    }

    /// @notice this function is called by the validator to change the issueSize
    /// @notice validator should consider not to increase too much. It must satisfy condition: effective balance on consensus layer >= issueSize + possible penalties
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    /// @notice validator must repay all outstanding bonds in order to increase issueSize
    function changeIssueSize(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (_amount >= vc.issueSize && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
        }

        if (_amount < vc.minimumAmountToAccept) revert AmountTooSmallToAccept();

        uint128 oldAmount = vc.issueSize;
        vc.issueSize = _amount;
        ++vc.version;

        emit IssueSizeChanged(oldAmount, _amount);
    }

    /// @notice This function is called by the validator to allow or forbids exits to holder
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    function changeExitAllowed() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (vc.outstandingBonds != 0) {
            revert ValidatorCannotChangeExitAllowedWhileOutstandingBondExists();
        }

        vc.exitAllowed = !vc.exitAllowed;

        ++vc.version;

        if (vc.exitAllowed == true) emit CofferAllowsHolderToExit();
        else emit CofferForbidsHolderToExit();
    }

    /// @notice This function is called by the validator to update safe total stake
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    /// @notice validator can decrease safeTotalStake at will
    /// @notice validator must repay all outstanding bonds in order to increase safeTotalStake
    function changeSafeTotalStake(uint32 _safeTotalStake) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (_safeTotalStake >= vc.safeTotalStake && vc.outstandingBonds != 0) {
            revert ValidatorCannotIncreaseSafeTotalStakeWhileOutstandingBondExist();
        }

        uint32 oldSafeTotalStake = vc.safeTotalStake;
        vc.safeTotalStake = _safeTotalStake;

        ++vc.version;

        emit SafeTotalStakeChanged(oldSafeTotalStake, _safeTotalStake);
    }

    /// @notice If contract has amount holder wants to withdraw and holders bond reached maturity, holder can call this function to withdraw the amount with interest
    /// @notice This function should be called when the contract has enough balance to cover the amount holder wants to withdraw
    /// @notice Validator or holder can trigger consensus withdraw in order to fill up contract with ETH
    /// @notice If validator allows holder to initiate full exit than it can issue bonds for (almost) all the consensus amount, even so it can drop to less than 32. Penalties should be considered only while defining issueSize in this situation.
    /// @notice If validator doesn not allows holder to initiate full exit, a holder can withdraw from consensus only the amount validator owes them and after bond reach its maturity
    /// @notice BondNft owner can withdraw using their holderId
    function holderWithdrawFromExecution(uint256 _holderId) external {
        HolderConditions storage holder = sHolderConditions[_holderId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        holderIsCaller(_holderId);

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp > block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        // Verify contract has enough balance to cover the amount creditor wants to withdraw
        if (address(this).balance < holder.amount) {
            revert ContractBalanceLessThanAmount();
        }

        uint128 amountToWithdraw = holder.amount;

        removeHolder(_holderId, amountToWithdraw);

        emit HolderWithdrawFromExecutionSuccess(msg.sender, _holderId);

        Address.sendValue(payable(msg.sender), amountToWithdraw);
    }

    /// @notice if validator allows exits, we cannot have proper way to check if holder should withdraw its exact amount or exit validator, thus holder will always exit validator if it's possible
    /// @notice if contract has enough amount to redeem holders bond, holder isn't able to withdraw any amount from consensus
    /// @notice in order for validator to avoid exits by holder, topping up a contract with holder amount is necessary
    /// @dev holders amount is represented in wei so we must convert it to gwei
    function holderWithdrawFromConsensus(uint256 _holderId) external payable {
        HolderConditions storage holder = sHolderConditions[_holderId];

        if (holder.amount == 0) {
            revert HolderDoesNotExistOrAlreadyWithdrawnAmount();
        }

        holderIsCaller(_holderId);

        if (address(this).balance >= holder.amount) {
            revert HolderConsensusWithdrawNotPossibleContractHasEnoughBalance();
        }

        // Has time passed so holder can withdraw
        if (holder.duration + holder.startTimestamp > block.timestamp) {
            revert HoldersTimeHasNotExpiredYet();
        }

        uint64 amountToWithdrawInGwei = 0;

        // if contract allows exits 0 should be sent in data, if not amount should be converted to gwei
        if (!sValidatorConditions.exitAllowed) {
            // forge-lint: disable-next-line(unsafe-typecast) holder.amount is always < 2048 ETH = 2.048 ** 21 and GWEI_RATE fits in uint64, so (holder.amount / GWEI_RATE) < 2.048 ** 13
            amountToWithdrawInGwei = uint64(holder.amount / GWEI_RATE);
        }

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall(
            ""
        );
        if (!readOk) {
            revert WithdrawlContractCallFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check the fee is not too high.
        if (fee > msg.value) {
            revert InsufficientFee();
        }

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdrawInGwei (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(
            I_PUBLIC_KEY_PART1,
            I_PUBLIC_KEY_PART2,
            amountToWithdrawInGwei
        );

        bool isFullExit = (amountToWithdrawInGwei == 0);
        emit HolderWithdrawFromConsensusSuccess(
            msg.sender,
            _holderId,
            holder.amount,
            isFullExit
        );

        (bool writeOk, ) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        if (!writeOk) {
            revert WithdrawlContractCallFailed();
        }
    }

    /// @notice Validator that has no unmatured bonds can withdraw everything from contract, otherwise it cannot
    /// @notice version of validator conditions must be updated to avoid validator frontrun holder
    function validatorWithdrawFromExecution(
        uint128 _amount
    ) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (vc.outstandingBonds != 0) {
            revert ValidatorCannotWithdrawFromExecutionWhileOutstandingBondExists();
        }

        if (_amount > address(this).balance)
            revert ContractBalanceLessThanAmount();

        ++vc.version;

        emit ValidatorWithdrawFromExecution(_amount);

        Address.sendValue(payable(msg.sender), _amount);
    }

    /// @notice Validator can withdraw from consensus as much as it wants, even perform an exit. Holders' funds are still covered
    /// @dev if _amount == 0 than full exit is initiated, otherwise it's partial withdraw. When validator exits there shouldn't be any flags in contract to switch since there is possibility for validator to pass by contract and exit through beacon chain directly. So contract itself must be designed to work whenever validator chooses to exit
    /// @dev if _amount != 0 partial withdraw will be initiated. Validator should be aware that it's unable to withdraw funds from Coffer contract while there are outstanding bonds.
    /// @dev if we try to partially withdraw amount, which would lower validators effective balance bellow 32, WITHDRAWAL_CONTRACT won't revert it would proccess it but beacon chain would withdraw different, smaller amount, just as much as it can so that validators effective balance stays at 32
    /// @dev this function is called using gwei not wei since beacon chain operates in gwei
    function validatorWithdrawFromConsensus(
        uint64 _amount
    ) external payable onlyOwner {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall(
            ""
        );
        if (!readOk) {
            revert WithdrawlContractCallFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check the fee is not too high.
        if (fee > msg.value) {
            revert InsufficientFee();
        }

        // Construct the 56-byte payload: [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for correct tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(
            I_PUBLIC_KEY_PART1,
            I_PUBLIC_KEY_PART2,
            _amount
        );

        emit ValidatorWithdrawFromConsensus(_amount);

        (bool writeOk, ) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        if (!writeOk) {
            revert WithdrawlContractCallFailed();
        }
    }

    /// @notice Validator can add funds at his own will
    /// @param _depositDataRoot Validator must create deposit data root off chain. It can be done using Using JavaScript with @chainsafe/ssz with validator public signing key and the amount intended to add

    function validatorAddFundsToConsensus(
        bytes32 _depositDataRoot
    ) external payable onlyOwner {
        if (msg.value < 1 ether) revert ValidatorDepositValueTooLow();
        if (msg.value % GWEI_RATE != 0)
            revert ValidatorDepositValueNotMultipleOfGwei();

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg.value}(
            abi.encodePacked(I_PUBLIC_KEY_PART1, I_PUBLIC_KEY_PART2),
            new bytes(32), // withdraw credentials can be all 0
            new bytes(96), // signature can be all 0
            _depositDataRoot
        );

        ValidatorConditions storage vc = sValidatorConditions;

        // forge-lint: disable-next-line(unsafe-typecast) penalty on msg.value (≤ validator balance) fits uint128
        vc.issueSize += uint128(Penalty.addMaximumPenalty(
            msg.value,
            vc.safeTotalStake,
            vc.maximumDuration / NUMBER_OF_SECONDS_IN_EPOCH
        ));

        // forge-lint: disable-next-line(unsafe-typecast) msg.value checked ≥ 1 ether and is gwei-aligned, fits uint128
        emit ValidatorFundsAdded(uint128(msg.value));
    }

    /// @notice this should be called after contract address is successfully assigned to validator's BLS public key
    function convertToCompounding() external payable onlyOwner {
        (bool readOk, bytes memory feeData) = CONSOLIDATION_CONTRACT.staticcall(
            ""
        );
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

        (bool success, ) = CONSOLIDATION_CONTRACT.call{value: fee}(data);
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

    /// @notice Function which cleans up holders data and updates validators data
    /// @notice Used in: closeOfferWithExactAmountFromValidator, closeOfferFromCofferContract & holderWithdrawFromExecution
    /// @dev It's checked in all functions that _holderId indeed is in storage sHolderConditions, so we do not check here
    function removeHolder(uint256 _holderId, uint256 _amount) private {
        ValidatorConditions storage vc = sValidatorConditions;
        // forge-lint: disable-next-line(unsafe-typecast) _amount originates from uint128 HolderConditions.amount
        vc.issueSize += uint128(_amount);
        --vc.outstandingBonds;
        ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).burnCofferBond(_holderId);
        delete sHolderConditions[_holderId];
    }

    /// @notice Function which checks if msg.sender has BondNft
    /// @notice Used in: holderWithdrawFromConsensus & holderWithdrawFromExecution
    /// @dev It's checked in both functions that _holderId indeed is in storage sHolderConditions, so we do not check here
    function holderIsCaller(uint256 _holderId) private view {
        if (
            msg.sender !=
            ICofferBondNft(I_COFFER_BOND_NFT_ADDRESS).ownerOf(_holderId)
        ) {
            revert CallerIsNotHolder();
        }
    }
}
