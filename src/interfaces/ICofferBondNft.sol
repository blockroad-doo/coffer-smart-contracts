//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/**
 * @title ICofferBondNft
 * @author Coffer Team
 * @notice Interface for factory-based NFT management in Coffer smart contract
 * @notice Coffer contracts use this interface to interact with the shared NFT contract
 */
interface ICofferBondNft {
    /// @notice Mints a new Coffer bond NFT to the holder
    /// @param holderAddress The address of the bond holder
    /// @return bondId The ID of the newly minted bond NFT
    function mintCofferBond(address holderAddress) external returns (uint256 bondId);

    /// @notice Burns a Coffer bond NFT
    /// @param bondId The ID of the bond NFT to burn
    function burnCofferBond(uint256 bondId) external;

    /// @notice Returns the owner of the specified bond NFT
    /// @param bondId The ID of the bond NFT
    /// @return The address of the bond NFT owner
    function ownerOf(uint256 bondId) external view returns (address);
}
