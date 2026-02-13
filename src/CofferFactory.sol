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
import {CofferBondNft} from "./CofferBondNft.sol";

contract CofferFactory {
    error InvalidDuration();
    error InvalidInterestRate();
    error MinimumAmountToAcceptIsZero();
    error MinimumAmountToAcceptGreaterThanAvailableAmount();

    uint64 private constant MAX_RATE = 1e8; // Rate divisor for 100% interest rate

    address public immutable I_COFFER_BOND_NFT_ADDRESS;

    event CofferIssued(address indexed owner, address indexed cofferAddress);

    constructor() {
        CofferBondNft iCofferBondNft = new CofferBondNft();
        I_COFFER_BOND_NFT_ADDRESS = address(iCofferBondNft);
    }

    function createCoffer(
        bytes32 _publicKeyPart1,
        bytes16 _publicKeyPart2,
        uint64 _interestRate,
        uint32 _minimumDuration,
        uint32 _maximumDuration,
        uint128 _availableAmount,
        uint128 _minimumAmountToAccept,
        bool _exitAllowed
    ) external {
        if ((_maximumDuration < _minimumDuration) || _minimumDuration == 0) {
            revert InvalidDuration();
        }
        if (_minimumAmountToAccept == 0) revert MinimumAmountToAcceptIsZero();
        if (_interestRate == 0 || _interestRate > MAX_RATE) revert InvalidInterestRate();
        if (_availableAmount < _minimumAmountToAccept) revert MinimumAmountToAcceptGreaterThanAvailableAmount();

        Coffer newCoffer = new Coffer(
            msg.sender,
            I_COFFER_BOND_NFT_ADDRESS,
            _publicKeyPart1,
            _publicKeyPart2,
            _interestRate,
            _minimumDuration,
            _maximumDuration,
            _availableAmount,
            _minimumAmountToAccept,
            _exitAllowed
        );

        emit CofferIssued(msg.sender, address(newCoffer));
    }
}
