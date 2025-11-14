//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ICofferReceivableNFT
 * @notice Interface for factory-based NFT management in Coffer smart contract
 * @notice Coffer contracts use this interface to interact with the shared NFT contract
 */
interface ICofferReceivableNFT {
    function mintCofferReceivable(address holderAddress) external returns (uint256 holderId);
    function burnCofferReceivable(uint256 holderId) external;
    function getHolderAddress(uint256 holderId) external view returns (address);
}
