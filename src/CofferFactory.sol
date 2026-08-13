//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Coffer} from "./Coffer.sol";
import {CofferBondNft} from "./CofferBondNft.sol";
import {CofferBondsRedeemedEarly} from "./CofferBondsRedeemedEarly.sol";
import {FeeCurve} from "./FeeCurve.sol";
import {LibClone} from "solady/utils/LibClone.sol";

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
    error InvalidIssueSizeBufferBps();
    error InvalidMinimumValueToAccept();
    error InvalidStartingBalance();

    uint256 private constant MAX_RATE = 1e8; // Represents 100% interest rate, so 1e6 is 1%
    uint256 private constant MAX_DURATION = 1_576_800_000; // 50 years
    uint256 private constant BUFFER_DENOMINATOR = 10000; // basis points: 1% = 100

    /// @notice Address of the shared CofferBondNft contract
    address public immutable I_COFFER_BOND_NFT_ADDRESS;
    /// @notice Address of the shared CofferBondsRedeemedEarly contract
    address public immutable I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS;
    /// @notice Address of the Coffer implementation contract (used for CWIA cloning)
    address public immutable I_COFFER_IMPLEMENTATION;
    /// @notice Address of the shared FeeCurve contract
    address public immutable I_FEE_CURVE_ADDRESS;

    /// @notice Emitted when a new Coffer contract is created
    /// @param owner The address of the validator who created the Coffer
    /// @param cofferAddress The address of the newly deployed Coffer contract
    /// @param publicKeyPart1 First 32 bytes of the validator BLS public key (indexed, so creations are
    /// filterable by pubkey)
    /// @param publicKeyPart2 Last 16 bytes of the validator BLS public key
    /// @param interestRate Yearly interest rate offered to bond holders
    /// @param minimumDuration Minimum bond duration in seconds
    /// @param maximumDuration Maximum bond duration in seconds
    /// @param minimumValueToAccept Minimum value a holder must deposit
    /// @param issueSizeBufferBps Conservatism buffer applied to the starting balance. 1% = 100
    /// @param exitAllowed Whether holders can initiate validator exits
    /// @param issueSize The initial issueSize derived by initialize (buffer-scaled starting balance)
    event CofferIssued(
        address indexed owner,
        address indexed cofferAddress,
        bytes32 indexed publicKeyPart1,
        bytes16 publicKeyPart2,
        uint32 interestRate,
        uint32 minimumDuration,
        uint32 maximumDuration,
        uint128 minimumValueToAccept,
        uint16 issueSizeBufferBps,
        bool exitAllowed,
        uint128 issueSize
    );

    /// @notice Deploys shared contracts and the Coffer implementation for CWIA cloning
    /// @param _feeRecipient Initial protocol fee recipient address
    constructor(address _feeRecipient) {
        CofferBondNft iCofferBondNft = new CofferBondNft(address(this));
        I_COFFER_BOND_NFT_ADDRESS = address(iCofferBondNft);

        CofferBondsRedeemedEarly iBondsRedeemedEarly = new CofferBondsRedeemedEarly();
        I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS = address(iBondsRedeemedEarly);

        FeeCurve feeCurve = new FeeCurve(msg.sender, _feeRecipient);
        I_FEE_CURVE_ADDRESS = address(feeCurve);

        I_COFFER_IMPLEMENTATION = address(new Coffer(address(feeCurve)));
    }

    // solhint-disable function-max-lines
    /// @notice Creates a new Coffer contract for a validator using CREATE2 deterministic deployment
    /// @dev Address is deterministic: predictCofferAddress() returns the same address before deployment.
    ///      Reverts if a Coffer with the same (msg.sender, pubkey) pair already exists.
    /// @param _publicKeyPart1 First 32 bytes of the validator BLS public key
    /// @param _publicKeyPart2 Last 16 bytes of the validator BLS public key
    /// @param _interestRate Yearly interest rate offered to bond holders
    /// @param _minimumDuration Minimum bond duration in seconds
    /// @param _maximumDuration Maximum bond duration in seconds
    /// @param _minimumValueToAccept Minimum value a holder must deposit
    /// @param _issueSizeBufferBps Conservatism buffer: the validator's consensus balance is scaled down by
    /// (BUFFER_DENOMINATOR - _issueSizeBufferBps) / BUFFER_DENOMINATOR to derive issueSize. 1% = 100.
    /// A higher value means more conservative provisioning (smaller issueSize). Holders must assess whether
    /// the chosen buffer is adequate for the bond durations offered.
    /// @param _exitAllowed Whether holders can initiate validator exits
    /// @param _startingBalance Validator's starting balance used to seed the initial issueSize
    /// @return The address of the newly deployed Coffer contract
    function createCoffer(
        bytes32 _publicKeyPart1,
        bytes16 _publicKeyPart2,
        uint32 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _minimumValueToAccept,
        uint16 _issueSizeBufferBps,
        bool _exitAllowed,
        uint128 _startingBalance
    ) external returns (address) {
        require(_minimumDuration != 0, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration >= _minimumDuration, InvalidDuration());
        // solhint-disable-next-line gas-strict-inequalities
        require(_maximumDuration <= MAX_DURATION, InvalidDuration());
        require(_interestRate != 0, InvalidInterestRate());
        // solhint-disable-next-line gas-strict-inequalities
        require(_interestRate <= MAX_RATE, InvalidInterestRate());
        // solhint-disable-next-line gas-strict-inequalities
        require(_issueSizeBufferBps < BUFFER_DENOMINATOR, InvalidIssueSizeBufferBps());
        require(_startingBalance != 0, InvalidStartingBalance());

        require(_minimumValueToAccept != 0, InvalidMinimumValueToAccept());
        // minimumValueToAccept must not exceed the buffer-scaled starting balance (the initial issueSize).
        // Inlined rather than held in a local: the 11-argument CofferIssued emit below needs the stack room.
        require(
            // solhint-disable-next-line gas-strict-inequalities
            _minimumValueToAccept
                <= uint256(_startingBalance) * (BUFFER_DENOMINATOR - _issueSizeBufferBps) / BUFFER_DENOMINATOR,
            InvalidMinimumValueToAccept()
        );

        // Deploy deterministic clone with immutable args (CREATE2). Scoped so the CWIA
        // data and salt are released before the emit — legacy codegen holds locals to
        // function end, and the 11-argument event would otherwise go stack-too-deep.
        address clone;
        {
            bytes memory data = _packCwiaData(_publicKeyPart1, _publicKeyPart2);
            bytes32 salt = _computeSalt(msg.sender, _publicKeyPart1, _publicKeyPart2);
            clone = LibClone.cloneDeterministic(I_COFFER_IMPLEMENTATION, data, salt);
        }

        // Initialize the clone's storage
        uint128 issueSize = Coffer(payable(clone))
            .initialize(
                msg.sender,
                _interestRate,
                _minimumDuration,
                _maximumDuration,
                _minimumValueToAccept,
                _issueSizeBufferBps,
                _exitAllowed,
                _startingBalance
            );

        CofferBondNft(I_COFFER_BOND_NFT_ADDRESS).registerCoffer(clone);

        emit CofferIssued(
            msg.sender,
            clone,
            _publicKeyPart1,
            _publicKeyPart2,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _minimumValueToAccept,
            _issueSizeBufferBps,
            _exitAllowed,
            issueSize
        );

        return clone;
    }

    // solhint-enable function-max-lines

    /// @notice Predicts the deterministic address of a Coffer clone before deployment
    /// @param _owner The address that will call createCoffer (msg.sender at deploy time)
    /// @param _publicKeyPart1 First 32 bytes of the validator BLS public key
    /// @param _publicKeyPart2 Last 16 bytes of the validator BLS public key
    /// @return The predicted address of the Coffer clone
    function predictCofferAddress(address _owner, bytes32 _publicKeyPart1, bytes16 _publicKeyPart2)
        external
        view
        returns (address)
    {
        bytes memory data = _packCwiaData(_publicKeyPart1, _publicKeyPart2);
        bytes32 salt = _computeSalt(_owner, _publicKeyPart1, _publicKeyPart2);
        return LibClone.predictDeterministicAddress(I_COFFER_IMPLEMENTATION, data, salt, address(this));
    }

    /// @dev Packs CWIA immutable args: 88 bytes (NFT addr + BondsRedeemed addr + BLS pubkey)
    function _packCwiaData(bytes32 _pk1, bytes16 _pk2) private view returns (bytes memory) {
        return abi.encodePacked(
            I_COFFER_BOND_NFT_ADDRESS, // 20 bytes, offset 0
            I_COFFER_BONDS_REDEEMED_EARLY_ADDRESS, // 20 bytes, offset 20
            _pk1, // 32 bytes, offset 40
            _pk2 // 16 bytes, offset 72
        );
    }

    /// @dev Computes CREATE2 salt from owner + BLS pubkey. One Coffer per (owner, pubkey) pair.
    function _computeSalt(address _owner, bytes32 _pk1, bytes16 _pk2) private pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, shl(96, _owner))
            mstore(add(ptr, 20), _pk1)
            mstore(add(ptr, 52), _pk2)
            result := keccak256(ptr, 68)
        }
    }
}
