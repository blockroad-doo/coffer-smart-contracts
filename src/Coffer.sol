//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICofferBondsRedeemedEarly} from "./interfaces/ICofferBondsRedeemedEarly.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import {IFeeCurve} from "./interfaces/IFeeCurve.sol";
import {Interest} from "./libraries/Interest.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Coffer
 * @author Blockroad Ltd
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple holders per validator with transferable receivable NFT instruments representing
 * ownership of an offer
 * @notice Uses EIP-7002 for withdrawals from consensus layer to smart contract
 * @notice Uses EIP-7251 for transforming validator to compounding (0x02 withdrawal credentials)
 * @notice Uses IDepositContract interface to allow deposits to consensus layer to top up validator's consensus balance
 */
contract Coffer is Ownable2Step, Multicall, Initializable {
    error ZeroValue();
    error ValueTooSmallToAccept();
    error InvalidDuration();
    error InvalidRate();
    error InvalidIssueSizeBufferBps();

    error ValidatorIsNotActive();
    error ValidatorDoesntCoverTheValue();
    error ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist();
    error ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist();
    error ValidatorCannotForbidExitsWhileOutstandingBondExists();
    error ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist();
    error ValidatorCannotIncreaseMaximumDurationWhileOutstandingBondExist();
    error ValidatorDepositValueNotMultipleOfGwei();
    error ValidatorConditionsVersionMismatch();
    error ValidatorDepositValueTooLow();

    error HolderDoesNotExistOrAlreadyWithdrawnValue();
    error HoldersTimeHasNotExpiredYet();
    error HolderCannotBeValidator();
    error ConsensusWithdrawAlreadyClosed();

    error CallerIsNotHolder();
    error ContractBalanceLessThanValue();

    error WithdrawalContractCallFailed();
    error WithdrawalAmountExceedsUint64Gwei();
    error ConsolidationContractCallFailed();
    error InsufficientFee();
    error FeeExceedsPrincipal();
    error ZeroAddressFeeCurve();
    error RenounceOwnershipDisabled();

    /// @notice When block.timestamp >= startTimestamp + duration, the bond reaches maturity
    /// @notice consensusWithdrawClosed can be triggered only once
    struct HolderConditions {
        uint128 bondMaturityValue;
        uint32 duration;
        uint32 startTimestamp;
        bool consensusWithdrawClosed;
    }

    /// @param issueSize - After finishing Coffer setup, this parameter has value close to consensus + execution
    /// balance minus a conservatism buffer (issueSizeBufferBps). Validator can change this parameter to control
    /// holder certainty of return. This value represents how much the validator can use to issue bonds. When a
    /// holder buys a bond, it is decreased by the bond value with interest.
    /// @param version - Prevents malicious validator from frontrunning attacks when holder buys a bond.
    /// @param issueSizeBufferBps - Conservatism buffer set by the validator. issueSize is derived from consensus
    /// balance as balance * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR. 1% = 100.
    /// Holders must assess whether the chosen buffer is adequate. A higher value is more conservative (smaller
    /// issueSize). Can always be increased and can be decreased only when no unmatured bonds exist.
    /// @param outstandingBonds - Counter for bonds not redeemed yet. Those bonds may or may not have matured.
    /// @param isActive - Represents if validator is willing to issue a bond or not. Can switch on/off at own will.
    /// @param exitAllowed - If (consensus balance - issueSize < MIN_ACTIVATION_BALANCE), the holder may be unable
    /// to claim a matured bond from the execution layer because partial consensus withdrawals are capped at the
    /// MIN_ACTIVATION_BALANCE active-validator floor; the only path to recovery is a full validator exit. In that
    /// regime a validator without exitAllowed == true is undercollateralized from the holder's perspective. When
    /// (consensus balance - issueSize >= MIN_ACTIVATION_BALANCE), exitAllowed can be false and the validator is
    /// fully collateralized. See README "Exit Mechanics".

    struct ValidatorConditions {
        uint128 issueSize;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumValueToAccept;
        uint32 version;
        uint32 outstandingBonds;
        uint16 issueSizeBufferBps;
        bool isActive;
        bool exitAllowed;
    }

    /// @notice Last 8 bytes in WITHDRAWAL_CONTRACT represent withdrawal amount in Gwei (not wei)
    /// @notice If the last 8 bytes are 0, then a full exit is initiated
    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    /// @notice Address of the DepositContract
    address private constant DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    /// @notice Address of the consolidation contract
    address private constant CONSOLIDATION_CONTRACT = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    uint256 private constant BUFFER_DENOMINATOR = 10000; // basis points: 1% = 100
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years

    /// @notice 100% interest rate is the maximum allowed, it can have
    /// up to 8 decimal places, e.g. 10% is represented as 1e7
    uint256 private constant MAX_RATE = 1e8; // 1e8 = 100%
    uint256 private constant GWEI_RATE = 1e9;

    /// @notice CWIA args offset: proxy runtime bytecode is 0x2d (45) bytes,
    /// immutable args are appended after that in the clone's deployed bytecode.
    /// During delegatecall, address(this) is the clone, so extcodecopy reads the clone's code.
    uint256 private constant _ARGS_OFFSET = 0x2d;

    /// @notice Shared protocol fee curve (set on the implementation, read by all clones)
    address public immutable FEE_CURVE;

    /// @notice Current validator conditions for bond issuance
    ValidatorConditions public sValidatorConditions;
    /// @notice Holder conditions mapped by ERC721 bond NFT Id
    mapping(uint256 => HolderConditions) public sHolderConditions;
    /// @notice Tracking how much has been withdrawn from Consensus by holders
    uint128 public totalConsensusReserved;

    /// @notice Emitted when a holder buys a bond
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param bondMaturityValue The value of the bond at maturity
    /// @param duration The bond duration in seconds
    /// @param principal The amount holder sends via msg.value
    /// @param interestRate The interest rate at the time of buying a bond
    event BondBought(
        address indexed holderAddress,
        uint256 indexed bondId,
        uint128 indexed bondMaturityValue,
        uint32 duration,
        uint128 principal,
        uint32 interestRate
    );
    /// @notice Emitted when a protocol fee is taken on a bond purchase
    /// @param bondId The ID of the bond NFT
    /// @param feeRecipient The address that received the fee
    /// @param feeAmount The fee paid, in wei
    /// @param feeBps The fee rate applied, in basis points
    event BondFeePaid(uint256 indexed bondId, address indexed feeRecipient, uint128 indexed feeAmount, uint256 feeBps);
    /// @notice Emitted when a holder withdraws from execution layer
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    event HolderWithdrawFromExecutionSuccess(address indexed holderAddress, uint256 indexed bondId);
    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when a holder does a partial withdrawal from execution layer
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param valueWithdrawn The amount withdrawn
    /// @param remainingBondMaturityValue The remaining bond maturity value
    event HolderPartialWithdrawFromExecutionSuccess(
        address indexed holderAddress,
        uint256 indexed bondId,
        uint128 valueWithdrawn,
        uint128 remainingBondMaturityValue
    );
    /* solhint-enable gas-indexed-events */
    /// @notice Emitted when holder initiates consensus layer withdrawal
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    /// @param value The value being withdrawn
    /// @param isFullExit Whether this is a full validator exit
    event HolderWithdrawFromConsensusClosed(
        address indexed holderAddress, uint256 indexed bondId, uint128 value, bool indexed isFullExit
    );
    /// @notice Emitted when validator redeems a bond early
    /// @param holderAddress The address of the bond holder
    /// @param bondId The ID of the bond NFT
    event ValidatorsBondRedeem(address indexed holderAddress, uint256 indexed bondId);
    /// @notice Emitted when validator withdraws from execution layer
    /// @param amount The amount withdrawn
    event ValidatorWithdrawFromExecution(uint128 indexed amount);
    /// @notice Emitted when validator withdraws from consensus layer
    /// @dev Emitted in wei for consistency with all other events, even though the function accepts gwei
    /// @param amount The amount withdrawn in wei
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
    /// @param newIssueSize The new issue size
    event IssueSizeChanged(uint128 indexed newIssueSize);
    /// @notice Emitted when minimum accepted value changes
    /// @param newMinimum The new minimum value
    event MinimumValueChanged(uint128 indexed newMinimum);
    /// @notice Emitted when issue size buffer changes
    /// @param oldBuffer The previous buffer
    /// @param newBuffer The new buffer
    event IssueSizeBufferBpsChanged(uint16 indexed oldBuffer, uint16 indexed newBuffer);
    /// @notice Emitted when validator converts to compounding
    event ValidatorConvertedToCompounding();
    /// @notice Emitted when the validator conditions version increments (anti-frontrun counter)
    /// @param newVersion The new version number
    event VersionChanged(uint32 indexed newVersion);
    /// @notice Emitted when totalConsensusReserved changes
    /// @param newValue The new total consensus reserved value
    event TotalConsensusReservedChanged(uint128 indexed newValue);

    ///--------------------------
    ///
    /// CONSTRUCTOR & INITIALIZER
    ///
    ///--------------------------

    /// @dev Implementation constructor that locks the implementation so it cannot be initialized.
    /// Passes address(1) to Ownable because OZ reverts on address(0).
    constructor(address _feeCurve) Ownable(address(1)) {
        require(_feeCurve != address(0), ZeroAddressFeeCurve());
        FEE_CURVE = _feeCurve;
        _disableInitializers();
    }

    /// @notice Disables renounceOwnership to prevent irreversible protocol bricking
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Address of the shared CofferBondNft contract (CWIA arg at offset 0)
    /// @return result The CofferBondNft contract address
    function iCofferBondNftAddress() public view returns (address result) {
        assembly {
            extcodecopy(address(), 12, _ARGS_OFFSET, 20)
            result := mload(0)
        }
    }

    /// @notice Address of the shared CofferBondsRedeemedEarly contract (CWIA arg at offset 20)
    /// @return result The CofferBondsRedeemedEarly contract address
    function iCofferBondsRedeemedEarly() public view returns (address result) {
        assembly {
            extcodecopy(address(), 12, add(_ARGS_OFFSET, 20), 20)
            result := mload(0)
        }
    }

    /// @notice First 32 bytes of the validator BLS signing public key (CWIA arg at offset 40)
    /// @return result The first 32 bytes of the BLS public key
    function iPublicKeyPart1() public view returns (bytes32 result) {
        assembly {
            extcodecopy(address(), 0, add(_ARGS_OFFSET, 40), 32)
            result := mload(0)
        }
    }

    /// @notice Last 16 bytes of the validator BLS signing public key (CWIA arg at offset 72)
    /// @return result The last 16 bytes of the BLS public key
    function iPublicKeyPart2() public view returns (bytes16 result) {
        assembly {
            extcodecopy(address(), 0, add(_ARGS_OFFSET, 72), 16)
            result := mload(0)
        }
    }

    /// @notice Initializes a CWIA clone with validator parameters
    /// @dev Called once by CofferFactory after cloning. The 4 "immutable" values (NFT address, early redemption
    /// address, public key parts) are read from CWIA args appended to this clone's bytecode, not passed here.
    /// @param _owner The validator address that will own this Coffer
    /// @param _interestRate Yearly interest rate offered to bond holders
    /// @param _minimumDuration Minimum bond duration in seconds
    /// @param _maximumDuration Maximum bond duration in seconds
    /// @param _minimumValueToAccept Minimum value a holder must deposit
    /// @param _issueSizeBufferBps Conservatism buffer for deriving issueSize from starting balance.
    /// 1% = 100. A higher value means more conservative provisioning (smaller issueSize). The protocol does
    /// not model consensus-layer penalties on-chain.
    /// @param _exitAllowed Whether holders can initiate validator exits
    /// @param _startingBalance Validator's starting balance used to seed the initial issueSize (scaled by the buffer)
    /// @notice issueSize is computed as _startingBalance scaled by the buffer.
    function initialize(
        address _owner,
        uint32 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _minimumValueToAccept,
        uint16 _issueSizeBufferBps,
        bool _exitAllowed,
        uint128 _startingBalance
    ) external initializer {
        _transferOwnership(_owner);

        sValidatorConditions = ValidatorConditions({
            issueSize: 0,
            interestRate: _interestRate,
            minimumDuration: _minimumDuration,
            maximumDuration: _maximumDuration,
            minimumValueToAccept: _minimumValueToAccept,
            version: 1,
            outstandingBonds: 0,
            issueSizeBufferBps: _issueSizeBufferBps,
            isActive: true,
            exitAllowed: _exitAllowed
        });

        sValidatorConditions.issueSize =
        // forge-lint: disable-next-line(unsafe-typecast) buffer-scaled balance (<= _startingBalance) fits uint128
        uint128(uint256(_startingBalance) * (BUFFER_DENOMINATOR - _issueSizeBufferBps) / BUFFER_DENOMINATOR);
    }

    /// @notice Receive ETH and increase issueSize by the received amount
    /// @notice Beacon chain withdrawals (EIP-4895) credit balance without code execution, so receive() is only
    /// triggered by execution-layer transfers. This ETH is real on-execution backing, so it is safe to increase
    /// issueSize.
    /// @notice A validator can send ETH here to prevent a holder from initiating an exit. This is a known
    /// trust model trade-off: by topping up the contract balance, the validator blocks holderWithdrawFromConsensus
    /// but simultaneously enables holderWithdrawFromExecution, ensuring the holder can still claim their funds from
    /// the execution layer.
    /// @notice The contributor set is unrestricted by design. Funds from any sender are pooled into the Coffer
    /// balance and credited to issueSize, and any AML or sanctions filtering is performed off-chain. This is an
    /// inherent property of every ETH-accepting Ethereum address, including the validator's own 0x01 or 0x02
    /// withdrawal credential, and is not a Coffer-specific weakness.
    /// @dev Anyone can send ETH but only validator/holders benefit from it
    // solhint-disable-next-line no-complex-fallback, use-natspec
    /// #if_succeeds {:msg "issueSize increases by msg.value on receive"} sValidatorConditions.issueSize ==
    ///     old(sValidatorConditions.issueSize) + msg.value;
    receive() external payable {
        // forge-lint: disable-next-line(unsafe-typecast) msg.value < total ETH supply, fits uint128
        ValidatorConditions storage vc = sValidatorConditions;
        vc.issueSize += uint128(msg.value);

        emit IssueSizeChanged(vc.issueSize);
    }

    ///--------------------------
    ///
    /// EXTERNAL FUNCTIONS
    ///
    ///--------------------------

    /// @notice Allows a holder to buy a bond by sending ETH. Creates an NFT representing bond ownership.
    /// Holder sends the bond value as msg.value. The function computes interest, deducts the protocol fee
    /// (holder bears the fee), stores net maturity value, and forwards (value - fee) to the validator.
    /// @param _duration Holder defines the duration, which must be within the validator's offered interval
    /// @param _version Version must match the current validator's version to prevent front-runs
    /// @return bondId The ID of the newly minted bond NFT
    // solhint-disable function-max-lines
    /// @notice Allows a holder to buy a bond by sending ETH. Creates an NFT representing bond ownership.
    /// Holder sends the bond value as msg.value. The function computes interest, deducts the protocol fee
    /// (holder bears the fee), stores net maturity value, and forwards (value - fee) to the validator.
    /// @param _duration Holder defines the duration, which must be within the validator's offered interval
    /// @param _version Version must match the current validator's version to prevent front-runs
    /// @return bondId The ID of the newly minted bond NFT
    /// #if_succeeds {:msg "outstandingBonds increments by 1 on buyBond"} sValidatorConditions.outstandingBonds ==
    ///     old(sValidatorConditions.outstandingBonds) + 1;
    /// #if_succeeds {:msg "issueSize decreases by at least bondMaturityValue"} sValidatorConditions.issueSize <=
    ///     old(sValidatorConditions.issueSize);
    function buyBond(uint32 _duration, uint32 _version) external payable returns (uint256 bondId) {
        ValidatorConditions storage vc = sValidatorConditions;

        require(vc.version == _version, ValidatorConditionsVersionMismatch());
        // solhint-disable-next-line gas-strict-inequalities
        require(msg.value >= vc.minimumValueToAccept, ValueTooSmallToAccept());
        require(vc.isActive, ValidatorIsNotActive());
        require(msg.sender != owner(), HolderCannotBeValidator());
        require(_duration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_duration >= vc.minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_duration <= vc.maximumDuration, InvalidDuration());

        uint256 interest = Interest.calculateInterest(msg.value, _duration, vc.interestRate);
        (uint256 feeBps, address feeRecipient) = IFeeCurve(FEE_CURVE).getFee();
        uint256 fee = (interest * feeBps) / BUFFER_DENOMINATOR; // BUFFER_DENOMINATOR == 10000 bps
        require(fee < msg.value + 1, FeeExceedsPrincipal());

        // holder bears the fee: payout is net of fee
        uint256 bondMaturityValue = msg.value + interest - fee;

        // solhint-disable-next-line gas-strict-inequalities
        require(bondMaturityValue <= vc.issueSize, ValidatorDoesntCoverTheValue());

        // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
        vc.issueSize -= uint128(bondMaturityValue);

        ++vc.outstandingBonds;

        // Mint NFT representing the bond
        bondId = ICofferBondNft(iCofferBondNftAddress()).mintCofferBond(msg.sender);

        // Store coffer conditions using bondId as key
        sHolderConditions[bondId] = HolderConditions({
            duration: _duration,
            startTimestamp: uint32(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
            bondMaturityValue: uint128(bondMaturityValue),
            consensusWithdrawClosed: false
        });

        emit IssueSizeChanged(vc.issueSize);
        if (fee > 0) {
            // forge-lint: disable-next-line(unsafe-typecast) fee <= msg.value fits uint128
            emit BondFeePaid(bondId, feeRecipient, uint128(fee), feeBps);
        }
        emit BondBought(
            msg.sender,
            bondId,
            // forge-lint: disable-next-line(unsafe-typecast) bondMaturityValue ≤ issueSize which is uint128
            uint128(bondMaturityValue),
            _duration,
            uint128(msg.value),
            vc.interestRate
        );

        if (fee > 0) {
            // Pull pattern: deposit the fee into the trusted shared FeeCurve (cannot revert), so a
            // hostile/non-payable feeRecipient can never brick buyBond. Recipient withdraws via claim().
            IFeeCurve(FEE_CURVE).collectFee{value: fee}();
        }
        Address.sendValue(payable(owner()), msg.value - fee);
    }

    // solhint-enable function-max-lines

    /// @notice Redeem bonds early by sending maturity values to CofferBondsRedeemedEarly
    /// @notice Only the validator can call this function
    /// @notice Holders claim their funds from CofferBondsRedeemedEarly (pull pattern)
    /// @notice If the contract doesn't have enough to repay, the validator can send additional funds via msg.value
    /// @notice msg.value should equal max(0, totalValue - address(this).balance), where totalValue is the sum of
    /// bondMaturityValue across the passed bondIds. Unlike the EIP-7002 and EIP-7251 fee-bearing functions, the
    /// shortfall here is a pure function of on-chain state at call time, so the validator or their frontend can size
    /// msg.value exactly without oracle or fee drift. Any surplus is NOT refunded and accrues to the contract
    /// balance. It is recoverable via validatorWithdrawFromExecution, bounded by issueSize while outstandingBonds > 0
    /// and freely withdrawable once all bonds settle.
    /// @param _bondIds Bond IDs of the bonds to be redeemed early
    /// @dev Slither flags reentrancy-no-eth (false positive): burnCofferBond calls a trusted immutable NFT contract
    /// whose _burn has no callbacks, and this function is onlyOwner
    function redeemBondsEarly(uint256[] calldata _bondIds) external payable onlyOwner {
        address[] memory holders = new address[](_bondIds.length);
        uint128[] memory amounts = new uint128[](_bondIds.length);
        uint256 totalValue = 0;

        for (uint256 i = 0; i < _bondIds.length; ++i) {
            uint256 bondId = _bondIds[i];
            HolderConditions storage holder = sHolderConditions[bondId];
            uint128 value = holder.bondMaturityValue;

            require(value != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());

            holders[i] = ICofferBondNft(iCofferBondNftAddress()).ownerOf(bondId);
            amounts[i] = value;
            totalValue += value;

            if (holder.consensusWithdrawClosed) {
                totalConsensusReserved -= value;
            }

            delete sHolderConditions[bondId];

            // slither-disable-next-line reentrancy-no-eth
            ICofferBondNft(iCofferBondNftAddress()).burnCofferBond(bondId);

            emit ValidatorsBondRedeem(holders[i], bondId);
        }

        emit TotalConsensusReservedChanged(totalConsensusReserved);

        ValidatorConditions storage vc = sValidatorConditions;
        vc.outstandingBonds -= uint32(_bondIds.length);

        // The contract must retain enough to cover BOTH the redeemed bonds AND the funds reserved
        // for any remaining consensus-closed holders. totalConsensusReserved has already been
        // decremented above for any consensus-closed bonds in this batch, so it is exactly the
        // reserve that must survive. This mirrors the validatorWithdrawFromExecution balance gate;
        // without it, early-redeeming a bond could spend a cover-in-place holder's reserved ETH
        // (which has no pending beacon withdrawal) and permanently strand them.
        // solhint-disable-next-line gas-strict-inequalities
        require(address(this).balance >= totalValue + totalConsensusReserved, ContractBalanceLessThanValue());

        ICofferBondsRedeemedEarly(iCofferBondsRedeemedEarly()).deposit{value: totalValue}(holders, amounts);
    }

    /// @notice Change the Coffer's activity
    /// @notice If the validator wants to stop issuing bonds, it can flip from active to inactive and vice versa
    function changeCofferActivity() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;
        bool newState = !vc.isActive;
        vc.isActive = newState;
        if (newState) emit CofferActivated();
        else emit CofferDeactivated();
    }

    /// @notice Validator can decrease the rate without affecting previous bonds
    /// @notice Version of validator conditions must be updated to avoid the validator front-running the holder
    /// @notice Validator must repay all outstanding bonds in order to increase the interest rate
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
        emit VersionChanged(vc.version);
        emit InterestRateChanged(oldRate, _rate);
    }

    /// @notice Validator can change the duration period without affecting previous bonds since the duration is
    /// defined when a bond is bought
    /// @notice Increasing maximumDuration is blocked while outstanding bonds exist because a longer maximum
    /// duration widens the window for consensus-layer events (penalties, leaks) that the issueSizeBufferBps
    /// conservatism parameter was provisioned against, which could undercollateralize existing bonds.
    /// Version is incremented on change.
    /// @notice The asymmetry between minimumDuration (no guard) and maximumDuration (guarded while outstanding bonds
    /// exist) is intentional. minimumDuration is read only inside buyBond at purchase, and each bond freezes its own
    /// duration in HolderConditions, so post-purchase changes cannot affect outstanding bonds. A raised
    /// minimumDuration only tightens the range for future purchases.
    /// @param _minimumDuration The new minimum duration in seconds
    /// @param _maximumDuration The new maximum duration in seconds
    function changeMinimumAndMaximumDuration(uint32 _minimumDuration, uint32 _maximumDuration) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable gas-strict-inequalities
        require(
            _maximumDuration <= vc.maximumDuration || vc.outstandingBonds == 0,
            ValidatorCannotIncreaseMaximumDurationWhileOutstandingBondExist()
        );
        // solhint-enable gas-strict-inequalities

        require(_minimumDuration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration >= _minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration <= MAX_DURATION, InvalidDuration());

        ++vc.version;
        emit VersionChanged(vc.version);
        vc.minimumDuration = _minimumDuration;
        vc.maximumDuration = _maximumDuration;
        emit DurationRangeChanged(_minimumDuration, _maximumDuration);
    }

    /// @notice Validator can change the minimum value to accept without affecting previous bonds
    /// @notice The minimum value the validator is willing to accept cannot affect the holder while buying, so the
    /// version doesn't have to be updated
    /// @param _value The new minimum value to accept
    function changeMinimumValueToAccept(uint128 _value) external onlyOwner {
        require(_value != 0, ZeroValue());
        sValidatorConditions.minimumValueToAccept = _value;
        emit MinimumValueChanged(_value);
    }

    /// @notice This function is called by the validator to change the issueSize
    /// @notice Validator should consider the conservatism buffer when setting issueSize. Must satisfy:
    /// consensus balance * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR >= issueSize
    /// for bonds to be considered collateralized.
    /// @notice Version of validator conditions must be updated to avoid the validator front-running the holder
    /// @notice Validator must repay all outstanding bonds in order to increase issueSize
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

        vc.issueSize = _issueSize;
        ++vc.version;
        emit VersionChanged(vc.version);
        emit IssueSizeChanged(vc.issueSize);
    }

    /// @notice This function is called by the validator to allow or forbid exits for the holder
    /// @notice Version of validator conditions must be updated to avoid the validator front-running the holder
    function changeExitAllowed() external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        require(!vc.exitAllowed || vc.outstandingBonds == 0, ValidatorCannotForbidExitsWhileOutstandingBondExists());

        vc.exitAllowed = !vc.exitAllowed;

        ++vc.version;
        emit VersionChanged(vc.version);

        if (vc.exitAllowed == true) emit CofferAllowsHolderToExit();
        else emit CofferForbidsHolderToExit();
    }

    /// @notice This function is called by the validator to update the issue size buffer
    /// @notice Version of validator conditions must be updated to avoid the validator front-running the holder
    /// @notice Validator can increase the buffer at will (more conservative)
    /// @notice Validator must repay all outstanding bonds in order to decrease the buffer
    /// @param _issueSizeBufferBps The new issue size buffer. 1% = 100
    function changeIssueSizeBufferBps(uint16 _issueSizeBufferBps) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        // solhint-disable-next-line gas-strict-inequalities
        require(
            _issueSizeBufferBps > vc.issueSizeBufferBps || vc.outstandingBonds == 0,
            ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist()
        );

        // solhint-disable-next-line gas-strict-inequalities
        require(_issueSizeBufferBps < BUFFER_DENOMINATOR, InvalidIssueSizeBufferBps());

        uint16 oldBuffer = vc.issueSizeBufferBps;
        vc.issueSizeBufferBps = _issueSizeBufferBps;

        ++vc.version;
        emit VersionChanged(vc.version);
        emit IssueSizeBufferBpsChanged(oldBuffer, _issueSizeBufferBps);
    }

    /// @notice Holder withdraws matured bond from execution layer
    /// @notice Should be called when the contract has enough balance to cover the holder's bond value
    /// @notice Validator or holder can trigger a consensus withdrawal to fill up the contract with ETH
    /// @notice If the validator allows holder exits, it can issue bonds for almost all the consensus amount.
    /// The issueSizeBufferBps conservatism parameter should be considered when defining issueSize.
    /// @notice If the validator does not allow holder exits, the holder can withdraw from consensus only the owed
    /// value after maturity
    /// @notice The BondNft owner can withdraw using their bondId
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromExecution(uint256 _bondId) external {
        HolderConditions storage holder = sHolderConditions[_bondId];

        require(holder.bondMaturityValue != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());

        require(msg.sender == ICofferBondNft(iCofferBondNftAddress()).ownerOf(_bondId), CallerIsNotHolder());

        // Has time passed so holder can withdraw
        // solhint-disable gas-strict-inequalities
        // forge-lint: disable-next-line
        require(holder.duration + holder.startTimestamp <= block.timestamp, HoldersTimeHasNotExpiredYet());
        // solhint-enable gas-strict-inequalities

        uint128 valueToWithdraw;
        uint128 reserved = (holder.consensusWithdrawClosed ? 0 : totalConsensusReserved);

        // solhint-disable-next-line gas-strict-inequalities
        if (address(this).balance >= holder.bondMaturityValue + reserved) {
            // Full withdrawal: existing behavior
            valueToWithdraw = holder.bondMaturityValue;

            ValidatorConditions storage vc = sValidatorConditions;
            --vc.outstandingBonds;
            totalConsensusReserved -= (holder.consensusWithdrawClosed ? valueToWithdraw : 0);
            emit TotalConsensusReservedChanged(totalConsensusReserved);
            delete sHolderConditions[_bondId];
            ICofferBondNft(iCofferBondNftAddress()).burnCofferBond(_bondId);

            emit HolderWithdrawFromExecutionSuccess(msg.sender, _bondId);
        } else {
            require(address(this).balance > reserved, ContractBalanceLessThanValue());

            // Partial withdrawal: withdraw whatever is available
            // forge-lint: disable-next-line(unsafe-typecast)
            // balance < holder.bondMaturityValue (uint128), so fits uint128
            valueToWithdraw = uint128(address(this).balance - reserved);

            holder.bondMaturityValue -= valueToWithdraw;
            totalConsensusReserved -= (holder.consensusWithdrawClosed ? valueToWithdraw : 0);
            emit TotalConsensusReservedChanged(totalConsensusReserved);

            emit HolderPartialWithdrawFromExecutionSuccess(
                msg.sender, _bondId, valueToWithdraw, holder.bondMaturityValue
            );

            ICofferBondNft(iCofferBondNftAddress()).emitMetadataUpdate(_bondId);
        }

        Address.sendValue(payable(msg.sender), valueToWithdraw);
    }

    /// @notice Holder initiates consensus layer withdrawal
    /// @notice If the validator allows exits, the holder will always exit the validator if possible since we cannot
    /// properly check the exact value vs. full exit
    /// @notice If the contract has enough ETH to settle the bond, this function performs a cover-in-place fallback:
    /// instead of issuing an EIP-7002 request it sets consensusWithdrawClosed and increments totalConsensusReserved
    /// to lock the matured value in for the holder, then returns. The holder then claims via
    /// holderWithdrawFromExecution.
    /// @notice Without the cover-in-place fallback a malicious validator could front-run the holder's call with a
    /// receive() top-up to push address(this).balance above the threshold and revert the holder's tx, then
    /// immediately extract the ETH via validatorWithdrawFromExecution (its gate is balance >= amount +
    /// totalConsensusReserved, which would still pass since totalConsensusReserved did not grow on the reverted
    /// path). The cover-in-place fallback neutralises this griefing vector: after the fallback fires,
    /// totalConsensusReserved is bumped, the validator's extraction reverts at its balance gate, and the holder can
    /// settle via holderWithdrawFromExecution.
    /// @notice msg.value must cover the EIP-7002 withdrawal fee read from WITHDRAWAL_CONTRACT via staticcall.
    /// Callers should pre-size msg.value off-chain as (fee + small_buffer) to tolerate cross-block fee drift. Any
    /// surplus (msg.value - fee) is NOT refunded and accrues to the contract balance; for the holder path this
    /// surplus is not recoverable by the holder and effectively flows to the validator via
    /// validatorWithdrawFromExecution once bonds settle. This matches the off-chain pre-sizing pattern prescribed in
    /// EIP-7002 §"Fee Overpayment".
    /// @notice The consensusWithdrawClosed flag is set once per bond. A second call for the same bond reverts with
    /// ConsensusWithdrawAlreadyClosed. This is intentional. The finding's concern (partial withdrawal
    /// under-delivering) can only arise when exitAllowed = false and consensus balance - MIN_ACTIVATION_BALANCE <
    /// bondMaturityValue, a configuration the README's "Undercollateralized Scenarios" bucket explicitly forbids.
    /// Allowing retrigger would let a holder sweep the validator's post-rewards balance back down to
    /// MIN_ACTIVATION_BALANCE on every subsequent call,
    /// which would break the trust model. Any remaining bond value, if any, is recovered via
    /// holderWithdrawFromExecution, which can be called repeatedly as funds arrive.
    /// @dev Holder's bond value is in wei, so we must convert it to gwei
    /// @param _bondId The ID of the bond NFT to withdraw
    function holderWithdrawFromConsensus(uint256 _bondId) external payable {
        HolderConditions storage holder = sHolderConditions[_bondId];

        require(holder.bondMaturityValue != 0, HolderDoesNotExistOrAlreadyWithdrawnValue());
        require(msg.sender == ICofferBondNft(iCofferBondNftAddress()).ownerOf(_bondId), CallerIsNotHolder());
        require(!holder.consensusWithdrawClosed, ConsensusWithdrawAlreadyClosed());

        // solhint-disable gas-strict-inequalities
        // forge-lint: disable-next-line
        require(holder.duration + holder.startTimestamp <= block.timestamp, HoldersTimeHasNotExpiredYet());

        // solhint-disable-next-line gas-strict-inequalities
        if (address(this).balance - msg.value > holder.bondMaturityValue + totalConsensusReserved - 1) {
            holder.consensusWithdrawClosed = true;
            totalConsensusReserved += holder.bondMaturityValue;
            emit TotalConsensusReservedChanged(totalConsensusReserved);
            emit HolderWithdrawFromConsensusClosed(msg.sender, _bondId, holder.bondMaturityValue, false);
            return;
        }

        uint64 valueToWithdrawInGwei = 0;
        // If the contract allows exits, 0 should be sent in data; if not, the value should be converted to gwei
        if (!sValidatorConditions.exitAllowed) {
            // The EIP-7002 amount field is a uint64 gwei value. Guard the post-division quotient against
            // truncation, independent of any consensus parameter (e.g. MAX_EFFECTIVE_BALANCE, which can change
            // across forks).
            require(
                // solhint-disable-next-line gas-strict-inequalities
                holder.bondMaturityValue <= uint256(type(uint64).max) * GWEI_RATE,
                WithdrawalAmountExceedsUint64Gwei()
            );
            // forge-lint: disable-next-line(unsafe-typecast) guarded: ceil(bondMaturityValue / GWEI_RATE) fits uint64
            valueToWithdrawInGwei = uint64((holder.bondMaturityValue + GWEI_RATE - 1) / GWEI_RATE);
        }

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        require(readOk, WithdrawalContractCallFailed());
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));
        require(fee <= msg.value, InsufficientFee());

        // EIP-7002: 48-byte BLS public key + 8-byte withdrawal amount = 56 bytes
        bytes memory data = abi.encodePacked(iPublicKeyPart1(), iPublicKeyPart2(), valueToWithdrawInGwei);
        bool isFullExit = (valueToWithdrawInGwei == 0);
        holder.consensusWithdrawClosed = true;
        totalConsensusReserved += holder.bondMaturityValue;
        emit TotalConsensusReservedChanged(totalConsensusReserved);
        emit HolderWithdrawFromConsensusClosed(msg.sender, _bondId, holder.bondMaturityValue, isFullExit);

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        require(writeOk, WithdrawalContractCallFailed());
    }

    /// @notice Validator withdraws from execution layer
    /// @notice When outstanding bonds exist, withdrawal is bounded: the validator can only withdraw up to issueSize
    /// (unbonded capacity) and must leave at least totalConsensusReserved in the contract. When no bonds exist, the
    /// validator can withdraw freely.
    /// @notice Version of validator conditions must be updated to avoid the validator front-running the holder
    /// @param _amount The amount to withdraw
    function validatorWithdrawFromExecution(uint128 _amount) external onlyOwner {
        ValidatorConditions storage vc = sValidatorConditions;

        if (vc.outstandingBonds > 0) {
            // solhint-disable-next-line gas-strict-inequalities
            require(_amount <= vc.issueSize, ValidatorDoesntCoverTheValue());
            // solhint-disable-next-line gas-strict-inequalities
            require(address(this).balance >= uint256(_amount) + totalConsensusReserved, ContractBalanceLessThanValue());
            vc.issueSize -= _amount;
        } else {
            // solhint-disable-next-line gas-strict-inequalities
            require(_amount <= address(this).balance, ContractBalanceLessThanValue());
        }

        ++vc.version;
        emit VersionChanged(vc.version);
        emit IssueSizeChanged(vc.issueSize);
        emit ValidatorWithdrawFromExecution(_amount);

        Address.sendValue(payable(msg.sender), _amount);
    }

    /// @notice Validator can withdraw from consensus as much as it wants, even perform an exit, and contract must be
    /// designed so exits from consensus do not change state since exit can be done bypassing contract, interacting
    /// directly with beacon chain
    /// @notice msg.value must cover the EIP-7002 withdrawal fee read from WITHDRAWAL_CONTRACT via staticcall. The
    /// validator should pre-size msg.value off-chain as (fee + small_buffer). Any surplus (msg.value - fee) is NOT
    /// refunded and accrues to the contract balance; it is recoverable via validatorWithdrawFromExecution, bounded
    /// by issueSize while outstandingBonds > 0 and freely withdrawable once all bonds settle.
    /// @dev If _amount == 0, a full exit is initiated; otherwise a partial withdrawal is initiated. When the
    /// validator exits, there shouldn't be any state changes in the contract since the validator can bypass the
    /// contract and exit through the beacon chain directly. The contract must be designed so it works whenever the
    /// validator chooses to exit.
    /// @dev If _amount != 0, a partial withdrawal will be initiated. The validator should be aware it cannot
    /// withdraw from the Coffer while there are outstanding bonds.
    /// @dev If we try to partially withdraw an amount that would lower the consensus balance below
    /// MIN_ACTIVATION_BALANCE, WITHDRAWAL_CONTRACT won't revert; the beacon chain would withdraw a smaller amount
    /// to keep the balance at MIN_ACTIVATION_BALANCE.
    /// @dev This function is called using gwei, not wei, since the beacon chain operates in gwei
    /// @param _amount The amount to withdraw in gwei
    function validatorWithdrawFromConsensus(uint64 _amount) external payable onlyOwner {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        require(readOk, WithdrawalContractCallFailed());
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check that the fee is not too high.
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= msg.value, InsufficientFee());

        // Construct the 56-byte payload:
        // [public_key (48 bytes), amountToWithdraw (8 bytes)]
        // EIP-7002 format: 48-byte BLS public key + 8-byte withdrawal amount
        // Use abi.encodePacked for tight packing: 32 + 16 + 8 = 56 bytes
        bytes memory data = abi.encodePacked(iPublicKeyPart1(), iPublicKeyPart2(), _amount);

        // forge-lint: disable-next-line(unsafe-typecast) _amount is uint64, fits uint128 after gwei→wei conversion
        emit ValidatorWithdrawFromConsensus(uint128(_amount) * uint128(GWEI_RATE));

        (bool writeOk,) = WITHDRAWAL_CONTRACT.call{value: fee}(data);
        require(writeOk, WithdrawalContractCallFailed());
    }

    /// @notice Validator can add funds at will
    /// @param _depositDataRoot Validator must create the deposit data root off-chain using JavaScript with the
    function validatorAddFundsToConsensus(bytes32 _depositDataRoot) external payable onlyOwner {
        // solhint-disable-next-line gas-strict-inequalities
        require(msg.value >= 1 ether, ValidatorDepositValueTooLow());
        require(msg.value % GWEI_RATE == 0, ValidatorDepositValueNotMultipleOfGwei());

        IDepositContract(DEPOSIT_CONTRACT).deposit{value: msg.value}(
            abi.encodePacked(iPublicKeyPart1(), iPublicKeyPart2()),
            new bytes(32), // withdrawal credentials can be all 0
            new bytes(96), // signature can be all 0
            _depositDataRoot
        );

        ValidatorConditions storage vc = sValidatorConditions;

        // forge-lint: disable-next-line(unsafe-typecast) buffer-scaled msg.value (<= msg.value) fits uint128
        vc.issueSize += uint128(msg.value * (BUFFER_DENOMINATOR - vc.issueSizeBufferBps) / BUFFER_DENOMINATOR);

        emit IssueSizeChanged(vc.issueSize);
        // forge-lint: disable-next-line(unsafe-typecast) msg.value checked ≥ 1 ether and is gwei-aligned, fits uint128
        emit ValidatorFundsAdded(uint128(msg.value));
    }

    /// @notice Converts validator from 0x01 to 0x02 (compounding) credentials via EIP-7251 self-consolidation
    /// @notice msg.value must cover the EIP-7251 consolidation fee read from CONSOLIDATION_CONTRACT via staticcall.
    /// The validator should pre-size msg.value off-chain as (fee + small_buffer). Any surplus (msg.value - fee) is
    /// NOT refunded and accrues to the contract balance; it is recoverable via validatorWithdrawFromExecution under
    /// the same bounds as above (issueSize cap while outstandingBonds > 0).
    /// @dev Only needed for validators using the legacy 0x00 → 0x01 setup flow. Validators deposited with 0x02
    /// credentials directly can skip this.
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
            iPublicKeyPart1(),
            iPublicKeyPart2(),
            //target
            iPublicKeyPart1(),
            iPublicKeyPart2()
        );

        (bool success,) = CONSOLIDATION_CONTRACT.call{value: fee}(data);
        require(success, ConsolidationContractCallFailed());

        emit ValidatorConvertedToCompounding();
    }
}
