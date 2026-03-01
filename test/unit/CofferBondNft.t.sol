//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest, CofferBondNftEvents} from "./BaseTest.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @title CofferBondNftTest
 * @notice Unit tests for CofferBondNft contract
 * @dev Tests follow logical progression: constructor → mint → burn → ownerOf → reverts → ERC721 edge cases
 */
contract CofferBondNftTest is BaseTest {
    // ========================================
    // DRY HELPERS
    // ========================================

    /// @dev Mints a token to the given address, asserts ownership, returns holderId
    function _mintAndAssert(address to) internal returns (uint256 holderId) {
        holderId = bondNft.mintCofferBond(to);
        assertEq(bondNft.ownerOf(holderId), to, "Owner should match minted address");
    }

    // ========================================
    // CONSTRUCTOR TESTS
    // ========================================

    function test_Constructor_NameAndSymbol() public view {
        assertEq(bondNft.name(), "Coffer Bond");
        assertEq(bondNft.symbol(), "CB");
    }

    // ========================================
    // HAPPY CASES — mintCofferBond
    // ========================================

    function test_Mint_Success_ReturnsHolderId() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);
        assertEq(holderId, 1, "First minted token should have holderId = 1");
        assertEq(bondNft.ownerOf(holderId), holder1);
    }

    function test_Mint_Success_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit CofferBondNftEvents.CofferBondTokenMinted(1, holder1);
        bondNft.mintCofferBond(holder1);
    }

    function test_Mint_Success_IncrementsCounter() public {
        uint256 id1 = bondNft.mintCofferBond(holder1);
        uint256 id2 = bondNft.mintCofferBond(holder2);
        uint256 id3 = bondNft.mintCofferBond(holder3);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_Mint_Success_DifferentHolders() public {
        uint256 id1 = _mintAndAssert(holder1);
        uint256 id2 = _mintAndAssert(holder2);

        assertEq(bondNft.ownerOf(id1), holder1);
        assertEq(bondNft.ownerOf(id2), holder2);
        assertTrue(id1 != id2);
    }

    // ========================================
    // HAPPY CASES — burnCofferBond
    // ========================================

    function test_Burn_Success_RemovesToken() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);
        bondNft.burnCofferBond(holderId);

        // ownerOf (called by ownerOf) should revert for nonexistent token
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, holderId));
        bondNft.ownerOf(holderId);
    }

    function test_Burn_Success_EmitsEvent() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);

        vm.expectEmit(true, false, false, false);
        emit CofferBondNftEvents.CofferBondTokenBurned(holderId);
        bondNft.burnCofferBond(holderId);
    }

    function test_Burn_Success_UpdatesBalanceOf() public {
        bondNft.mintCofferBond(holder1);
        assertEq(bondNft.balanceOf(holder1), 1);

        uint256 id2 = bondNft.mintCofferBond(holder1);
        assertEq(bondNft.balanceOf(holder1), 2);

        bondNft.burnCofferBond(id2);
        assertEq(bondNft.balanceOf(holder1), 1);
    }

    // ========================================
    // HAPPY CASES — ownerOf
    // ========================================

    function test_ownerOf_ReturnsCorrectOwner() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);
        assertEq(bondNft.ownerOf(holderId), holder1);
    }

    function test_ownerOf_ReflectsTransfer() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);

        // Transfer from holder1 to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, holderId);

        assertEq(bondNft.ownerOf(holderId), holder2, "Should reflect new owner after transfer");
    }

    // ========================================
    // TRIGGER EVERY REVERT
    // ========================================

    function test_Mint_Revert_ZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        bondNft.mintCofferBond(address(0));
    }

    function test_Burn_Revert_NonExistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        vm.prank(address(0));
        bondNft.burnCofferBond(999);
    }

    function test_Burn_Revert_NonDelegateCallBurn() public {
        vm.expectRevert(CofferBondNft.OnlyDelegateCanBurn.selector);
        bondNft.burnCofferBond(999);
    }

    function test_ownerOf_Revert_NonExistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        bondNft.ownerOf(999);
    }

    // ========================================
    // ERC721 INTEGRATION (EDGE CASES)
    // ========================================

    function test_ERC721_TransferFrom() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);

        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, holderId);

        assertEq(bondNft.ownerOf(holderId), holder2);
        assertEq(bondNft.balanceOf(holder1), 0);
        assertEq(bondNft.balanceOf(holder2), 1);
    }

    function test_ERC721_Approve_And_TransferFrom() public {
        uint256 holderId = bondNft.mintCofferBond(holder1);

        // holder1 approves holder2
        vm.prank(holder1);
        bondNft.approve(holder2, holderId);

        // holder2 transfers using approval
        vm.prank(holder2);
        bondNft.transferFrom(holder1, holder3, holderId);

        assertEq(bondNft.ownerOf(holderId), holder3);
    }

    function test_ERC721_BalanceOf() public {
        assertEq(bondNft.balanceOf(holder1), 0);

        uint256 id1 = bondNft.mintCofferBond(holder1);
        assertEq(bondNft.balanceOf(holder1), 1);

        bondNft.mintCofferBond(holder1);
        assertEq(bondNft.balanceOf(holder1), 2);

        bondNft.burnCofferBond(id1);
        assertEq(bondNft.balanceOf(holder1), 1);
    }
}
