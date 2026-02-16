//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title CofferBondNft
 * @notice ERC-721 contract representing transferable ownership of Coffer Accepted Offer
 * @notice When a holder accepts Coffer offer, they receive an NFT representing a bond
 */
contract CofferBondNft is ERC721 {
    error TokenDoesNotExist();
    error UnauthorizedMinter();

    uint256 private s_holderIdCounter;

    event CofferBondTokenMinted(uint256 indexed holderId, address indexed holder);
    event CofferBondTokenBurned(uint256 indexed holderId);

    constructor() ERC721("Coffer Bond", "CB") {}

    function mintCofferBond(address _holderAddress) external returns (uint256) {
        uint256 holderId = ++s_holderIdCounter;
        _mint(_holderAddress, holderId);
        emit CofferBondTokenMinted(holderId, _holderAddress);
        return holderId;
    }

    function burnCofferBond(uint256 _holderId) external {
        _burn(_holderId);
        emit CofferBondTokenBurned(_holderId);
    }

    ///@notice Get the address of the holder for a given token ID
    function getHolderAddress(uint256 _holderId) external view virtual returns (address) {
        return ownerOf(_holderId);
    }
}
