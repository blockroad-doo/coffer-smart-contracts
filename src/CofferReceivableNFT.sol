//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title CofferReceivableNFT
 * @notice ERC-721 contract representing transferable ownership of coffer receivables
 * @notice When a user accepts Coffer offer, they receive an NFT representing ownership rights to repayments
 * @notice The NFT can be transferred to sell the receivables to another party
 */
abstract contract CofferReceivableNFT is ERC721 {

    error ZeroAddress();
    error TokenDoesNotExist();
    error UnauthorizedMinter();

    uint256 private s_userIdCounter;

    event CofferReceivableTokenMinted(uint256 indexed userId, address indexed user);
    event CofferReceivableTokenBurned(uint256 indexed userId);

    constructor() ERC721("Coffer Receivable", "CR") {}

    function mintCofferReceivable(address _userAddress) internal returns (uint256) {
        uint256 userId = s_userIdCounter++;
        _mint(_userAddress, userId);
        emit CofferReceivableTokenMinted(userId, _userAddress);
        return userId;
    }

    function burnCofferReceivable(uint256 _userId) internal {
        if (_ownerOf(_userId) == address(0)) revert TokenDoesNotExist();
        _burn(_userId);
        emit CofferReceivableTokenBurned(_userId);
    }

    // @notice Get the address of the user for a given token ID
    function getUserAddress(uint256 _userId) external view virtual returns (address) {
        return ownerOf(_userId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}