//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";
import {CofferBondNftHandler} from "./CofferBondNftHandler.sol";

contract CofferBondNftInvariantTest is Test {
    CofferBondNft public nft;
    CofferBondNftHandler public handler;

    function setUp() public virtual {
        nft = new CofferBondNft();
        handler = new CofferBondNftHandler(nft);
        targetContract(address(handler));
    }

    function invariant_CounterMonotonicallyIncreases() public view {
        assertEq(handler.ghostNextExpectedId(), handler.ghostTotalMinted(), "Counter must equal total minted");
    }

    function invariant_ActiveSupplyEqualsMintsMinusBurns() public view {
        assertEq(
            handler.getActiveIdsLength(),
            handler.ghostTotalMinted() - handler.ghostTotalBurned(),
            "Active supply must equal mints minus burns"
        );
    }

    function invariant_EveryActiveTokenHasValidOwner() public view {
        uint256 len = handler.getActiveIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.getActiveIdAt(i);
            address owner = nft.ownerOf(tokenId);
            assertTrue(owner != address(0), "Active token must have non-zero owner");
        }
    }

    function invariant_OwnerMappingConsistency() public view {
        uint256 len = handler.getActiveIdsLength();
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = handler.getActiveIdAt(i);
            assertEq(nft.ownerOf(tokenId), handler.ghostOwner(tokenId), "On-chain owner must match ghost owner");
        }
    }

    function invariant_BurnedTokenHasNoOwner() public {
        uint256 lastBurned = handler.ghostLastBurnedId();
        if (lastBurned == 0) return; // No burns yet
        if (handler.ghostIsActive(lastBurned)) return; // Re-minted (won't happen with incrementing IDs, but safe)

        // ownerOf should revert for burned tokens
        try nft.ownerOf(lastBurned) {
            fail("ownerOf should revert for burned token");
        } catch {}
    }

    function invariant_TotalBurnedNeverExceedsTotalMinted() public view {
        assertLe(handler.ghostTotalBurned(), handler.ghostTotalMinted(), "Total burned must never exceed total minted");
    }
}
