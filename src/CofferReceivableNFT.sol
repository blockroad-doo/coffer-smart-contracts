//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title CofferReceivableNFT
 * @notice ERC-721 contract representing transferable ownership of coffer receivables
 * @notice When a holder accepts Coffer offer, they receive an NFT representing ownership rights to repayments
 * @notice The NFT can be transferred to sell the receivables to another party
 */
abstract contract CofferReceivableNFT is ERC721 {
    error ZeroAddress();
    error TokenDoesNotExist();
    error UnauthorizedMinter();

    uint256 private s_holderIdCounter;

    event CofferReceivableTokenMinted(uint256 indexed holderId, address indexed holder);
    event CofferReceivableTokenBurned(uint256 indexed holderId);

    constructor() ERC721("Coffer Receivable", "CR") {}

    function mintCofferReceivable(address _holderAddress) internal returns (uint256) {
        uint256 holderId = s_holderIdCounter++;
        _mint(_holderAddress, holderId);
        emit CofferReceivableTokenMinted(holderId, _holderAddress);
        return holderId;
    }

    function burnCofferReceivable(uint256 _holderId) internal {
        if (_ownerOf(_holderId) == address(0)) revert TokenDoesNotExist();
        _burn(_holderId);
        emit CofferReceivableTokenBurned(_holderId);
    }

    // @notice Get the address of the holder for a given token ID
    function getHolderAddress(uint256 _holderId) external view virtual returns (address) {
        return ownerOf(_holderId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
