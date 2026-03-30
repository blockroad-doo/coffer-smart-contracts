//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

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
    // SETUP — standalone NFT with test as factory
    // ========================================

    function setUp() public override {
        super.setUp();
        // Create a standalone CofferBondNft with this test as the factory,
        // so we can call mintCofferBond directly in unit tests.
        bondNft = new CofferBondNft(address(this));
        bondNft.registerCoffer(address(this));
    }

    // ========================================
    // DRY HELPERS
    // ========================================

    /// @dev Mints a token to the given address, asserts ownership, returns bondId
    function _mintAndAssert(address to) internal returns (uint256 bondId) {
        bondId = bondNft.mintCofferBond(to);
        assertEq(bondNft.ownerOf(bondId), to, "Owner should match minted address");
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

    function test_Mint_Success_ReturnsBondId() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);
        assertEq(bondId, 1, "First minted token should have bondId = 1");
        assertEq(bondNft.ownerOf(bondId), holder1);
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
        uint256 bondId = bondNft.mintCofferBond(holder1);
        bondNft.burnCofferBond(bondId);

        // ownerOf (called by ownerOf) should revert for nonexistent token
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, bondId));
        bondNft.ownerOf(bondId);
    }

    function test_Burn_Success_EmitsEvent() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        vm.expectEmit(true, false, false, false);
        emit CofferBondNftEvents.CofferBondTokenBurned(bondId);
        bondNft.burnCofferBond(bondId);
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
        uint256 bondId = bondNft.mintCofferBond(holder1);
        assertEq(bondNft.ownerOf(bondId), holder1);
    }

    function test_ownerOf_ReflectsTransfer() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        // Transfer from holder1 to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        assertEq(bondNft.ownerOf(bondId), holder2, "Should reflect new owner after transfer");
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
        vm.expectRevert(CofferBondNft.OnlyCofferCanBurn.selector);
        bondNft.burnCofferBond(999);
    }

    function test_ownerOf_Revert_NonExistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        bondNft.ownerOf(999);
    }

    // ========================================
    // EIP-4906 — emitMetadataUpdate & supportsInterface
    // ========================================

    function test_EmitMetadataUpdate_Success_EmitsEvent() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        vm.expectEmit(false, false, false, true, address(bondNft));
        emit CofferBondNftEvents.MetadataUpdate(bondId);
        bondNft.emitMetadataUpdate(bondId);
    }

    function test_EmitMetadataUpdate_Revert_OnlyCofferCanEmit() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        vm.prank(holder1);
        vm.expectRevert(CofferBondNft.OnlyCofferCanEmit.selector);
        bondNft.emitMetadataUpdate(bondId);
    }

    function test_SupportsInterface_EIP4906() public view {
        assertTrue(bondNft.supportsInterface(bytes4(0x49064906)));
    }

    function test_SupportsInterface_ERC721() public view {
        assertTrue(bondNft.supportsInterface(bytes4(0x80ac58cd)));
    }

    // ========================================
    // ERC721 INTEGRATION (EDGE CASES)
    // ========================================

    function test_ERC721_TransferFrom() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, bondId);

        assertEq(bondNft.ownerOf(bondId), holder2);
        assertEq(bondNft.balanceOf(holder1), 0);
        assertEq(bondNft.balanceOf(holder2), 1);
    }

    function test_ERC721_Approve_And_TransferFrom() public {
        uint256 bondId = bondNft.mintCofferBond(holder1);

        // holder1 approves holder2
        vm.prank(holder1);
        bondNft.approve(holder2, bondId);

        // holder2 transfers using approval
        vm.prank(holder2);
        bondNft.transferFrom(holder1, holder3, bondId);

        assertEq(bondNft.ownerOf(bondId), holder3);
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

    // ========================================
    // ACCESS CONTROL — registerCoffer & mintCofferBond
    // ========================================

    function test_Mint_Revert_UnregisteredCaller() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(CofferBondNft.OnlyRegisteredCoffer.selector);
        bondNft.mintCofferBond(holder1);
    }

    function test_RegisterCoffer_Revert_OnlyFactory() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(CofferBondNft.OnlyFactory.selector);
        bondNft.registerCoffer(unauthorizedUser);
    }

    function test_RegisterCoffer_Success_AllowsMinting() public {
        address newCoffer = makeAddr("newCoffer");
        bondNft.registerCoffer(newCoffer);
        assertTrue(bondNft.isRegisteredCoffer(newCoffer));

        vm.prank(newCoffer);
        uint256 bondId = bondNft.mintCofferBond(holder1);
        assertEq(bondNft.ownerOf(bondId), holder1);
    }
}
