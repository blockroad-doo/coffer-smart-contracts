//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";

contract CofferBondNftHandler is Test {
    CofferBondNft public nft;
    address[] public actors;

    // Ghost state
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;
    uint256 public ghost_nextExpectedId;
    uint256[] public ghost_activeIds;
    mapping(uint256 => bool) public ghost_isActive;
    mapping(uint256 => address) public ghost_owner;
    uint256 public ghost_lastBurnedId;

    constructor(CofferBondNft _nft) {
        nft = _nft;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(makeAddr("actor4"));
    }

    function handler_mint(uint256 actorSeed) external {
        address recipient = actors[actorSeed % actors.length];

        uint256 holderId = nft.mintCofferBond(recipient);

        ++ghost_totalMinted;
        ++ghost_nextExpectedId;
        ghost_activeIds.push(holderId);
        ghost_isActive[holderId] = true;
        ghost_owner[holderId] = recipient;
    }

    function handler_burn(uint256 idSeed) external {
        uint256 len = ghost_activeIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 tokenId = ghost_activeIds[idx];

        nft.burnCofferBond(tokenId);

        // Swap-and-pop
        ghost_activeIds[idx] = ghost_activeIds[len - 1];
        ghost_activeIds.pop();

        ghost_isActive[tokenId] = false;
        delete ghost_owner[tokenId];
        ++ghost_totalBurned;
        ghost_lastBurnedId = tokenId;
    }

    function handler_burnInvalid(uint256 rawId) external {
        if (ghost_isActive[rawId]) return;
        // Will revert — absorbed by fail_on_revert = false
        nft.burnCofferBond(rawId);
    }

    function handler_transfer(uint256 idSeed, uint256 actorSeed) external {
        uint256 len = ghost_activeIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 tokenId = ghost_activeIds[idx];
        address currentOwner = ghost_owner[tokenId];
        address newOwner = actors[actorSeed % actors.length];

        vm.prank(currentOwner);
        nft.transferFrom(currentOwner, newOwner, tokenId);

        ghost_owner[tokenId] = newOwner;
    }

    // Helper views
    function getActiveIdsLength() external view returns (uint256) {
        return ghost_activeIds.length;
    }

    function getActiveIdAt(uint256 index) external view returns (uint256) {
        return ghost_activeIds[index];
    }
}
