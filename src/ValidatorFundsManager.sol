// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/**
 * @title ValidatorsFundsManager
 * @notice Smart contract for withdrawing and adding funds to validator on consensus layer
 * @notice Withdraws funds to Coffer contract
 */
abstract contract ValidatorsFundsManager {
    error ZeroAmount();
    error ZeroAddress();
    error PrecompileFailed();
    error InvalidPublicKeyLength();
    error IncorrectPrecompileValue();

    address private constant WITHDRAWAL_PRECOMPILE = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    address private constant ADD_FUNDS_PRECOMPILE = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    
    address public immutable i_withdrawCredential;
    bytes32 public immutable i_validatorsPublicKeyFirst32Bytes;
    bytes16 public immutable i_validatorsPublicKeySecond16Bytes;

    event FundsAdded(uint256 amount, uint256 newTotal);
    event FundsWithdrawn(uint256 amount);
    event ValidatorExited(uint256 finalBalance);

    constructor(address _withdrawCredential, bytes memory _validatorsPublicKey) {
        if (_withdrawCredential == address(0)) revert ZeroAddress();
        if (_validatorsPublicKey.length != 48) revert InvalidPublicKeyLength();

        i_withdrawCredential = _withdrawCredential;

        bytes32 p1;
        bytes16 p2;
        
        assembly {
            p1 := mload(add(_validatorsPublicKey, 32))      // Load first 32 bytes
            p2 := mload(add(_validatorsPublicKey, 48))      // Load last 16 bytes
        }

        i_validatorsPublicKeyFirst32Bytes = p1;
        i_validatorsPublicKeySecond16Bytes = p2;
    }
    
    function addMoreFunds(uint256 amount) external payable virtual {}
    
    function withdrawFunds(uint256 amount) public payable virtual {
        if (amount == 0) revert ZeroAmount();
        if (msg.value != 1) revert IncorrectPrecompileValue();

        bytes memory data = new bytes(56);

        bytes32 pk1 = i_validatorsPublicKeyFirst32Bytes;
        bytes16 pk2 = i_validatorsPublicKeySecond16Bytes;

        assembly {
            mstore(add(data, 0x20), pk1)              // Copy first 32 bytes
            mstore(add(data, 0x40), pk2)              // Copy remaining 16 bytes
            mstore(add(data, 0x50), shl(192, amount)) // Add amount (shift left 192 bits = 24 bytes)
        }
        
        emit FundsWithdrawn(amount);

        (bool success,) = WITHDRAWAL_PRECOMPILE.call{value: 1}(data);
        if (!success) {
            revert PrecompileFailed();
        }
    }
    
    function exit() external virtual {
        withdrawFunds(0);
    }
}