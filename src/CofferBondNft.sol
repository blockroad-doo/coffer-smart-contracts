//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";

/**
 * @title CofferBondNft
 * @author Coffer Team
 * @notice ERC-721 contract representing transferable ownership of Coffer Accepted Offer
 * @notice When a holder accepts Coffer offer, they receive an NFT representing a bond
 */
contract CofferBondNft is ERC721, ICofferBondNft {
    error OnlyDelegateCanBurn();

    /// @notice Counter for generating unique bond IDs
    uint256 private sBondIdCounter;
    /// @notice Mapping from bond ID to the address allowed to burn it
    mapping(uint256 => address) private burnDelegates;

    /// @notice Emitted when a new bond NFT is minted
    /// @param bondId The ID of the newly minted bond
    /// @param holder The address that received the bond NFT
    event CofferBondTokenMinted(uint256 indexed bondId, address indexed holder);
    /// @notice Emitted when a bond NFT is burned
    /// @param bondId The ID of the burned bond
    event CofferBondTokenBurned(uint256 indexed bondId);

    constructor() ERC721("Coffer Bond", "CB") {}

    /// @notice Mints a bond NFT and sets msg.sender as burn delegate
    /// @notice We set msg.sender as the delegate to burn tokens, so all calls
    /// coming from a Coffer contract will set that exact Coffer contract
    /// as the only delegate allowed to burn
    /// @param _holderAddress The address to receive the bond NFT
    /// @return bondId The ID of the newly minted bond
    function mintCofferBond(address _holderAddress) external returns (uint256) {
        uint256 bondId = ++sBondIdCounter;
        burnDelegates[bondId] = msg.sender;
        _mint(_holderAddress, bondId);
        emit CofferBondTokenMinted(bondId, _holderAddress);
        return bondId;
    }

    /// @notice Burns a bond NFT, only callable by the original minter
    /// @param _bondId The ID of the bond NFT to burn
    function burnCofferBond(uint256 _bondId) external {
        require(msg.sender == burnDelegates[_bondId], OnlyDelegateCanBurn());
        _burn(_bondId);
        emit CofferBondTokenBurned(_bondId);
    }

    /// @notice This override must be implemented because CofferBondNft
    /// now inherits both ICofferBondNft and ERC721, and both define ownerOf
    /// @param _bondId The ID of the bond for which the ownerOf function is overridden
    /// @return The address of the NFT owner with _bondId
    function ownerOf(uint256 _bondId) public view override(ERC721, ICofferBondNft) returns (address) {
        return super.ownerOf(_bondId);
    }
}
