// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {CofferReceivableNFT} from "../../src/CofferReceivableNFT.sol";

contract CofferReceivableNFTTest is Test {
    CofferReceivableNFT public nft;

    address public minter = makeAddr("minter");
    address public holder = makeAddr("holder");

    function setUp() public {
        nft = new CofferReceivableNFT();
    }

    function test_SupportsInterface_ERC721() public view {
        // ERC721 interface ID: 0x80ac58cd
        bytes4 erc721InterfaceId = 0x80ac58cd;
        assertTrue(nft.supportsInterface(erc721InterfaceId), "Should support ERC721 interface");
    }

    function test_Burn_SuccessfullyBurnsExistingToken() public {
        vm.prank(minter);
        uint256 tokenId = nft.mintCofferReceivable(holder);

        vm.prank(minter);
        nft.burnCofferReceivable(tokenId);

        vm.expectRevert(); // ERC721: invalid token ID
        nft.ownerOf(tokenId);
    }

    function test_Burn_RevertsWhenBurningNonExistentToken() public {
        vm.prank(minter);
        vm.expectRevert(CofferReceivableNFT.TokenDoesNotExist.selector);
        nft.burnCofferReceivable(999);
    }

    function test_GetHolderAddress_ReturnsOwnerOfValidToken() public {
        vm.prank(minter);
        uint256 tokenId = nft.mintCofferReceivable(holder);

        address owner = nft.getHolderAddress(tokenId);
        assertEq(owner, holder, "Should return holder as owner");
    }
}
