//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICoffer} from "./interfaces/ICoffer.sol";

/**
 * @title CofferBondNft
 * @author Blockroad Ltd
 * @notice ERC-721 contract representing transferable ownership of Coffer Accepted Offer
 * @notice When a holder accepts Coffer offer, they receive an NFT representing a bond
 */
contract CofferBondNft is ERC721, IERC4906, ICofferBondNft {
    error OnlyCofferCanBurn();
    error OnlyCofferCanEmit();

    /// @notice Counter for generating unique bond IDs
    uint256 private sBondIdCounter;
    /// @notice Mapping from bond ID to the Coffer contract that issued it
    mapping(uint256 => address) public cofferOf;

    /// @notice Emitted when a new bond NFT is minted
    /// @param bondId The ID of the newly minted bond
    /// @param holder The address that received the bond NFT
    event CofferBondTokenMinted(uint256 indexed bondId, address indexed holder);
    /// @notice Emitted when a bond NFT is burned
    /// @param bondId The ID of the burned bond
    event CofferBondTokenBurned(uint256 indexed bondId);

    constructor() ERC721("Coffer Bond", "CB") {}

    /// @notice Mints a bond NFT and records msg.sender as the issuing Coffer contract
    /// @notice Only the Coffer contract that minted a bond is authorized to burn it
    /// @param _holderAddress The address to receive the bond NFT
    /// @return bondId The ID of the newly minted bond
    function mintCofferBond(address _holderAddress) external returns (uint256) {
        uint256 bondId = ++sBondIdCounter;
        cofferOf[bondId] = msg.sender;
        _mint(_holderAddress, bondId);
        emit CofferBondTokenMinted(bondId, _holderAddress);
        return bondId;
    }

    /// @notice Burns a bond NFT, only callable by the original minter
    /// @param _bondId The ID of the bond NFT to burn
    function burnCofferBond(uint256 _bondId) external {
        require(msg.sender == cofferOf[_bondId], OnlyCofferCanBurn());
        _burn(_bondId);
        emit CofferBondTokenBurned(_bondId);
    }

    /// @notice Returns on-chain JSON metadata for wallet display
    /// @param _bondId The ID of the bond NFT
    /// @return data URI with base64-encoded JSON
    function tokenURI(uint256 _bondId) public view override returns (string memory) {
        _requireOwned(_bondId);

        address _cofferAddress = cofferOf[_bondId];
        ICoffer cofferContract = ICoffer(_cofferAddress);

        (uint128 bondMaturityValue, uint32 duration, uint32 startTimestamp, bool consensusWithdrawTriggered) =
            cofferContract.sHolderConditions(_bondId);

        string memory validatorPubKey =
            Strings.toHexString(abi.encodePacked(cofferContract.iPublicKeyPart1(), cofferContract.iPublicKeyPart2()));

        uint256 maturesAt = uint256(startTimestamp) + uint256(duration);

        // solhint-disable-next-line gas-small-strings
        string memory json = string.concat(
            "{\"name\":\"Coffer Bond #",
            Strings.toString(_bondId),
            "\",\"description\":\"Coffer bond - a transferable fixed-income"
            " instrument backed by an Ethereum validator.\"",
            ",\"validatorPublicKey\":\"",
            validatorPubKey,
            "\",\"cofferAddress\":\"",
            Strings.toHexString(_cofferAddress),
            "\",\"maturesAt\":",
            Strings.toString(maturesAt),
            ",\"maturityValue\":\"",
            Strings.toString(uint256(bondMaturityValue)),
            "\",\"consensusWithdrawTriggered\":",
            consensusWithdrawTriggered ? "true" : "false",
            "}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice This override must be implemented because CofferBondNft
    /// now inherits both ICofferBondNft and ERC721, and both define ownerOf
    /// @param _bondId The ID of the bond for which the ownerOf function is overridden
    /// @return The address of the NFT owner with _bondId
    function ownerOf(uint256 _bondId) public view override(ERC721, IERC721, ICofferBondNft) returns (address) {
        return super.ownerOf(_bondId);
    }

    /// @notice Returns true if the contract supports the given interface (ERC-165)
    /// @param interfaceId The interface identifier to check
    /// @return True if the interface is supported
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    /// @notice Emits EIP-4906 MetadataUpdate event, callable only by the bond's issuing Coffer
    /// @param _bondId The ID of the bond NFT whose metadata changed
    function emitMetadataUpdate(uint256 _bondId) external {
        require(msg.sender == cofferOf[_bondId], OnlyCofferCanEmit());
        emit MetadataUpdate(_bondId);
    }
}
