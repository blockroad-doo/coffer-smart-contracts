//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";
import {CofferBondNftHandler} from "./CofferBondNftHandler.sol";

contract CofferBondNftInvariantTest is Test {
    CofferBondNft public nft;
    CofferBondNftHandler public handler;

    function setUp() public virtual {
        nft = new CofferBondNft(address(this));
        handler = new CofferBondNftHandler(nft);
        nft.registerCoffer(address(handler));
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

    /// @dev Gap row G-10: the returned id is read from the chain, not from a ghost the handler bumps itself
    function invariant_MintedIdsAreDense() public view {
        assertFalse(handler.ghostIdViolation(), "the n-th successful mint must return n");
    }

    /// @dev Gap row G-10: over every id ever minted, a burned id stays burned with cofferOf cleared and a live
    /// id carries its minter. The handler is the only registered minter, so the minter is the handler.
    function invariant_EveryMintedIdIsLiveOrBurnedConsistently() public {
        uint256 minted = handler.ghostTotalMinted();
        for (uint256 id = 1; id <= minted; id++) {
            if (handler.ghostIsActive(id)) {
                assertEq(nft.ownerOf(id), handler.ghostOwner(id), "live id must be owned by the ghost owner");
                assertEq(nft.cofferOf(id), address(handler), "live id must map to its minter");
            } else {
                try nft.ownerOf(id) {
                    fail("ownerOf must revert for a burned id");
                } catch {}
                assertEq(nft.cofferOf(id), address(0), "burned id must have cofferOf cleared");
            }
        }
    }
}
