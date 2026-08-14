//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";

contract CofferBondNftHandler is Test {
    CofferBondNft public nft;
    address[] public actors;

    // Ghost state
    uint256 public ghostTotalMinted;
    uint256 public ghostTotalBurned;
    uint256 public ghostNextExpectedId;
    uint256[] public ghostActiveIds;
    mapping(uint256 => bool) public ghostIsActive;
    mapping(uint256 => address) public ghostOwner;
    uint256 public ghostLastBurnedId;

    constructor(CofferBondNft _nft) {
        nft = _nft;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(makeAddr("actor4"));
    }

    function handlerMint(uint256 actorSeed) external {
        address recipient = actors[actorSeed % actors.length];

        uint256 bondId = nft.mintCofferBond(recipient);

        ++ghostTotalMinted;
        ++ghostNextExpectedId;
        ghostActiveIds.push(bondId);
        ghostIsActive[bondId] = true;
        ghostOwner[bondId] = recipient;
    }

    function handlerBurn(uint256 idSeed) external {
        uint256 len = ghostActiveIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 tokenId = ghostActiveIds[idx];

        nft.burnCofferBond(tokenId);

        // Swap-and-pop
        ghostActiveIds[idx] = ghostActiveIds[len - 1];
        ghostActiveIds.pop();

        ghostIsActive[tokenId] = false;
        delete ghostOwner[tokenId];
        ++ghostTotalBurned;
        ghostLastBurnedId = tokenId;
    }

    function handlerBurnInvalid(uint256 rawId) external {
        if (ghostIsActive[rawId]) return;
        // Absorb the expected OnlyCofferCanBurn() revert so the strict
        // profile (fail_on_revert = true) stays green
        try nft.burnCofferBond(rawId) {
        // Unexpected success: nothing to record
        }
            catch {}
    }

    function handlerTransfer(uint256 idSeed, uint256 actorSeed) external {
        uint256 len = ghostActiveIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 tokenId = ghostActiveIds[idx];
        address currentOwner = ghostOwner[tokenId];
        address newOwner = actors[actorSeed % actors.length];

        vm.prank(currentOwner);
        nft.transferFrom(currentOwner, newOwner, tokenId);

        ghostOwner[tokenId] = newOwner;
    }

    // Helper views
    function getActiveIdsLength() external view returns (uint256) {
        return ghostActiveIds.length;
    }

    function getActiveIdAt(uint256 index) external view returns (uint256) {
        return ghostActiveIds[index];
    }
}
