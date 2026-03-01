//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title CofferBondNft
 * @notice ERC-721 contract representing transferable ownership of Coffer Accepted Offer
 * @notice When a holder accepts Coffer offer, they receive an NFT representing a bond
 */
contract CofferBondNft is ERC721 {
    error OnlyDelegateCanBurn();

    uint256 private sHolderIdCounter;
    mapping(uint256 => address) private burnDelegates;

    event CofferBondTokenMinted(
        uint256 indexed holderId,
        address indexed holder
    );
    event CofferBondTokenBurned(uint256 indexed holderId);

    constructor() ERC721("Coffer Bond", "CB") {}

    /// @notice we set msg.sender for delegate to burn tokens so all calls coming from Coffer contract will set that exact Coffer contract as the only delegator which would be allowed to burn
    function mintCofferBond(address _holderAddress) external returns (uint256) {
        uint256 holderId = ++sHolderIdCounter;
        burnDelegates[holderId] = msg.sender;
        _mint(_holderAddress, holderId);
        emit CofferBondTokenMinted(holderId, _holderAddress);
        return holderId;
    }

    /// @notice simple function for burning NFTs which checks only if the original minter is caller
    function burnCofferBond(uint256 _holderId) external {
        if (msg.sender != burnDelegates[_holderId]) revert OnlyDelegateCanBurn();
        _burn(_holderId);
        emit CofferBondTokenBurned(_holderId);
    }
}
