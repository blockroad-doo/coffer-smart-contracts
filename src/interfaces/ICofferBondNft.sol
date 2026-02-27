//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/**
 * @title ICofferBondNft
 * @notice Interface for factory-based NFT management in Coffer smart contract
 * @notice Coffer contracts use this interface to interact with the shared NFT contract
 */
interface ICofferBondNft {
    function mintCofferBond(address holderAddress) external returns (uint256 holderId);
    function burnCofferBond(uint256 holderId) external;
    function ownerOf(uint256 holderId) external view returns (address);
}
