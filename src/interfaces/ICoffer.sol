//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * @title ICoffer
 * @author Blockroad d.o.o.
 * @notice Minimal interface for reading bond data from a Coffer contract
 */
interface ICoffer {
    /// @notice Returns the bond conditions for a given bond ID
    /// @param bondId The ID of the bond to query
    /// @return bondMaturityValue The value the bond pays at maturity
    /// @return duration The duration of the bond in seconds
    /// @return startTimestamp The timestamp when the bond was created
    function sHolderConditions(uint256 bondId)
        external
        view
        returns (uint128 bondMaturityValue, uint32 duration, uint32 startTimestamp);

    /// @notice Returns the first part of the validator public key
    /// @return The first 32 bytes of the validator public key
    function iPublicKeyPart1() external view returns (bytes32);

    /// @notice Returns the second part of the validator public key
    /// @return The remaining 16 bytes of the validator public key
    function iPublicKeyPart2() external view returns (bytes16);
}
