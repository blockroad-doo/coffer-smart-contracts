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
    error MinimumAmountToAcceptGreaterThanAvailableAmount();

    uint256 private constant MAX_RATE = 1e18; // Rate divisor for 100% interest rate

    CofferReceivableNFT immutable i_CofferReceivableNFT;

    /// @notice one validators EOA can be used for multiple validators as a withdrawl credential address
    mapping(address validatorOwner => address[] cofferAddress) public s_coffersAddresses;

    event CofferCreated(address indexed validator, address indexed cofferAddress);

    constructor() {
        i_CofferReceivableNFT = new CofferReceivableNFT();
    }

    function createCoffer(
        bytes32 _public_key_part1,
        bytes16 _public_key_part2,
        uint256 _interestRate,
        uint256 _minimumDuration,
        uint256 _maximumDuration,
        uint256 _availableAmount,
        uint256 _minimumAmountToAccept,
        bool _exitAllowed
    ) external {
        if ((_maximumDuration <= _minimumDuration) || _minimumDuration == 0) {
            revert InvalidDuration();
        }
        if (_interestRate == 0 || _interestRate > MAX_RATE) revert InvalidInterestRate();
        if (_availableAmount < _minimumAmountToAccept) revert MinimumAmountToAcceptGreaterThanAvailableAmount();

        Coffer newCoffer = new Coffer(
            msg.sender,
            address(i_CofferReceivableNFT),
            _public_key_part1,
            _public_key_part2,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _availableAmount,
            _minimumAmountToAccept,
            _exitAllowed
        );

        s_coffersAddresses[msg.sender].push(address(newCoffer));
        i_CofferReceivableNFT.authorizeCofferContract(address(newCoffer));

        emit CofferCreated(msg.sender, address(newCoffer));
    }

    function getCofferReceivableNFTAddress() external view returns (address) {
        return address(i_CofferReceivableNFT);
    }
}
