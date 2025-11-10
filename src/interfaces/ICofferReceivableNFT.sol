//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ICofferReceivableNFT
 * @notice Interface for factory-based NFT management in Coffer smart contract
 * @notice Coffer contracts use this interface to interact with the shared NFT contract
 */
interface ICofferReceivableNFT {

    function mintNFTForCoffer(address user) external returns (uint256 tokenId);
    function burnNFTForCoffer(uint256 tokenId) external;
    function getNFTContract() external view returns (address);
    function getUserAddress(uint256 tokenId) external view returns (address);

}