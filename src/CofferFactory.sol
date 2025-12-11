//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/**
 * @title CofferFactory
 * @notice Factory contract for creating validator offers aka Coffers
 * @notice Deploys shared NFT contract CofferReceivableNFT
 * @author Coffer Team
 * @dev This contract manages the deployment of individual Coffer contracts and shared NFT management
 */
import {Coffer} from "./Coffer.sol";
import {CofferReceivableNFT} from "./CofferReceivableNFT.sol";

contract CofferFactory {
    error InvalidDuration();
    error InvalidInterestRate();
    error InvalidSlashingPenalty();
    error MinimumAmountToAcceptGreaterThanAvailableAmount();
    error UnauthorizedCoffer();
    error InvalidConsensusPublicKeyLength();

    uint256 private constant MAX_RATE = 1e18; // Rate divisor for 100% interest rate

    // Consider to deploy contract separately and then just use constant address at each Coffer?
    CofferReceivableNFT immutable i_CofferReceivableNFT;

    mapping(address => address) s_coffersAddresses;

    event CofferCreated(address indexed validator, uint256 availableAmount, uint256 interestRate);

    constructor() {
        i_CofferReceivableNFT = new CofferReceivableNFT();
    }

    function createCoffer(
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
    ) external {
        if ((_maximumDuration <= _minimumDuration) || _minimumDuration == 0) revert InvalidDuration();
        if (_interestRate == 0 || _interestRate > MAX_RATE) revert InvalidInterestRate();
        if (_availableAmount < _minimumAmountToAccept) revert MinimumAmountToAcceptGreaterThanAvailableAmount();
        if (_public_key_part1 == bytes32(0) || _public_key_part2 == bytes16(0)) {
            revert InvalidConsensusPublicKeyLength();
        }

        // Should we use CREATE2 for creating Coffers?
        // If yes, what are benefits?

        Coffer newCoffer = new Coffer(
            msg.sender,
            _public_key_part1,
            _public_key_part2,
            _cofferReceivableNFTAddress,
            _maximumSlashingPenalty,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _availableAmount,
            _minimumAmountToAccept //,
                //_returnAmonutRate,
                //_exitAllowed
        );

        s_coffersAddresses[msg.sender] = address(newCoffer);
        emit CofferCreated(msg.sender, _availableAmount, _interestRate);
    }

    ///
    /// VIEW FUNCTIONS
    ///

    /// @notice Get the coffer address for a given validator
    /// @param _validator The validator address
    /// @return The coffer address, or address(0) if no coffer exists
    function getCofferAddress(address _validator) external view returns (address) {
        return s_coffersAddresses[_validator];
    }

    /// @notice Get the shared CofferReceivableNFT contract address
    /// @return The address of the NFT contract deployed by this factory
    function getCofferReceivableNFTAddress() external view returns (address) {
        return address(i_CofferReceivableNFT);
    }
}
