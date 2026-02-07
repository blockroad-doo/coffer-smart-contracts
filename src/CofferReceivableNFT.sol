//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CofferReceivableNFT
 * @notice ERC-721 contract representing transferable ownership of coffer receivables
 * @notice When a holder accepts Coffer offer, they receive an NFT representing ownership rights to repayments
 * @notice The NFT can be transferred to another party
 */
contract CofferReceivableNFT is ERC721, Ownable {
    error TokenDoesNotExist();
    error UnauthorizedMinter();

    uint256 private s_holderIdCounter;
    mapping(address => bool) public s_authorizedCoffers;

    event CofferReceivableTokenMinted(uint256 indexed holderId, address indexed holder);
    event CofferReceivableTokenBurned(uint256 indexed holderId);

    modifier onlyAuthorizedCoffer() {
        if (!s_authorizedCoffers[msg.sender]) revert UnauthorizedMinter();
        _;
    }

    /// @notice Owner must be CofferFactory contract
    constructor() ERC721("Coffer Receivable", "CR") Ownable(msg.sender) {}

    function authorizeCofferContract(address _coffer) external onlyOwner {
        s_authorizedCoffers[_coffer] = true;
    }

    function mintCofferReceivable(address _holderAddress) external onlyAuthorizedCoffer returns (uint256) {
        uint256 holderId = ++s_holderIdCounter;
        _mint(_holderAddress, holderId);
        emit CofferReceivableTokenMinted(holderId, _holderAddress);
        return holderId;
    }

    function burnCofferReceivable(uint256 _holderId) external onlyAuthorizedCoffer {
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
