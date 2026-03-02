// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.33;

/// @title IDepositContract
/// @author Ethereum Foundation
/// @notice This is the Ethereum 2.0 deposit contract interface.
/// For more information see the Phase 0 specification under https://github.com/ethereum/eth2.0-specs
interface IDepositContract {
    /// @notice Submit a Phase 0 DepositData object.
    /// @param pubkey A BLS12-381 public key.
    /// @param withdrawalCredentials Commitment to a public key for withdrawals.
    /// @param signature A BLS12-381 signature.
    /// @param depositDataRoot The SHA-256 hash of the SSZ-encoded DepositData object.
    /// Used as a protection against malformed input.
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawalCredentials,
        bytes calldata signature,
        bytes32 depositDataRoot
    ) external payable;
}
