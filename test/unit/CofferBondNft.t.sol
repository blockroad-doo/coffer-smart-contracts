//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest, CofferBondNftEvents} from "./BaseTest.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/**
 * @title CofferBondNftTest
 * @notice Comprehensive unit tests for CofferBondNft contract
 * @dev Tests follow logical progression: happy cases, require triggers, modifiers, edge cases
 */
contract CofferBondNftTest is BaseTest {
    CofferBondNft public nft;
    address public authorizedMinter;

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();

        // Deploy a standalone NFT for testing
        nft = new CofferBondNft();

        // For testing purposes, we'll use a coffer as the authorized minter
        authorizedMinter = createDefaultCoffer();
    }

    // ========================================
    // HAPPY CASES
    // ========================================

    function test_MintCofferBond_Success() public {
        // Act
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Assert
        assertEq(holderId, 1, "First token ID should be 1");
        assertEq(nft.ownerOf(holderId), holder1, "Token should be owned by holder1");
        assertEq(nft.balanceOf(holder1), 1, "Holder1 should have 1 token");
    }

    function test_MintMultipleBonds_DifferentHolders() public {
        // Act
        vm.startPrank(authorizedMinter);
        uint256 holderId1 = nft.mintCofferBond(holder1);
        uint256 holderId2 = nft.mintCofferBond(holder2);
        uint256 holderId3 = nft.mintCofferBond(holder3);
        vm.stopPrank();

        // Assert
        assertEq(holderId1, 1, "First token ID should be 1");
        assertEq(holderId2, 2, "Second token ID should be 2");
        assertEq(holderId3, 3, "Third token ID should be 3");

        assertEq(nft.ownerOf(holderId1), holder1, "Token 1 should be owned by holder1");
        assertEq(nft.ownerOf(holderId2), holder2, "Token 2 should be owned by holder2");
        assertEq(nft.ownerOf(holderId3), holder3, "Token 3 should be owned by holder3");

        assertEq(nft.balanceOf(holder1), 1, "Holder1 should have 1 token");
        assertEq(nft.balanceOf(holder2), 1, "Holder2 should have 1 token");
        assertEq(nft.balanceOf(holder3), 1, "Holder3 should have 1 token");
    }

    function test_MintMultipleBonds_SameHolder() public {
        // Act
        vm.startPrank(authorizedMinter);
        uint256 holderId1 = nft.mintCofferBond(holder1);
        uint256 holderId2 = nft.mintCofferBond(holder1);
        uint256 holderId3 = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Assert
        assertEq(nft.balanceOf(holder1), 3, "Holder1 should have 3 tokens");
        assertEq(nft.ownerOf(holderId1), holder1, "All tokens should be owned by holder1");
        assertEq(nft.ownerOf(holderId2), holder1, "All tokens should be owned by holder1");
        assertEq(nft.ownerOf(holderId3), holder1, "All tokens should be owned by holder1");
    }

    function test_GetHolderAddress_Success() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act
        address holderAddress = nft.getHolderAddress(holderId);

        // Assert
        assertEq(holderAddress, holder1, "Should return correct holder address");
    }

    // ========================================
    // REQUIRE TRIGGERS - TOKEN EXISTENCE
    // ========================================

    function test_GetHolderAddress_RevertIf_TokenDoesNotExist() public {
        // Act & Assert
        vm.expectRevert();
        nft.getHolderAddress(999);
    }

    function test_OwnerOf_RevertIf_TokenDoesNotExist() public {
        // Act & Assert
        vm.expectRevert();
        nft.ownerOf(999);
    }

    // ========================================
    // ERC721 STANDARD COMPLIANCE
    // ========================================

    function test_TokenMetadata() public {
        // Assert
        assertEq(nft.name(), "Coffer Bond", "Token name should be Coffer Bond");
        assertEq(nft.symbol(), "CB", "Token symbol should be CB");
    }

    function test_TransferToken_Success() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act
        vm.startPrank(holder1);
        nft.transferFrom(holder1, holder2, holderId);
        vm.stopPrank();

        // Assert
        assertEq(nft.ownerOf(holderId), holder2, "Token should be transferred to holder2");
        assertEq(nft.balanceOf(holder1), 0, "Holder1 should have 0 tokens");
        assertEq(nft.balanceOf(holder2), 1, "Holder2 should have 1 token");
        assertEq(nft.getHolderAddress(holderId), holder2, "getHolderAddress should return holder2");
    }

    function test_ApproveAndTransferFrom_Success() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act - Approve holder2
        vm.startPrank(holder1);
        nft.approve(holder2, holderId);
        vm.stopPrank();

        // Act - Transfer from holder2
        vm.startPrank(holder2);
        nft.transferFrom(holder1, holder3, holderId);
        vm.stopPrank();

        // Assert
        assertEq(nft.ownerOf(holderId), holder3, "Token should be transferred to holder3");
        assertEq(nft.getHolderAddress(holderId), holder3, "getHolderAddress should return holder3");
    }

    function test_SetApprovalForAll_Success() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId1 = nft.mintCofferBond(holder1);
        uint256 holderId2 = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act - Set approval for all
        vm.startPrank(holder1);
        nft.setApprovalForAll(holder2, true);
        vm.stopPrank();

        // Act - Transfer both tokens
        vm.startPrank(holder2);
        nft.transferFrom(holder1, holder3, holderId1);
        nft.transferFrom(holder1, holder3, holderId2);
        vm.stopPrank();

        // Assert
        assertEq(nft.ownerOf(holderId1), holder3, "Token 1 should be transferred to holder3");
        assertEq(nft.ownerOf(holderId2), holder3, "Token 2 should be transferred to holder3");
        assertEq(nft.balanceOf(holder3), 2, "Holder3 should have 2 tokens");
    }

    function test_SafeTransferFrom_Success() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act
        vm.startPrank(holder1);
        nft.safeTransferFrom(holder1, holder2, holderId);
        vm.stopPrank();

        // Assert
        assertEq(nft.ownerOf(holderId), holder2, "Token should be transferred to holder2");
    }

    // ========================================
    // EVENT EMISSIONS
    // ========================================

    function test_MintCofferBond_EmitsEvent() public {
        // Arrange & Act
        vm.startPrank(authorizedMinter);

        vm.expectEmit(true, true, false, false);
        emit CofferBondNftEvents.CofferBondTokenMinted(1, holder1);

        nft.mintCofferBond(holder1);
        vm.stopPrank();
    }

    function test_Transfer_EmitsEvent() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(holder1);

        vm.expectEmit(true, true, true, false);
        emit IERC721.Transfer(holder1, holder2, holderId);

        nft.transferFrom(holder1, holder2, holderId);
        vm.stopPrank();
    }

    // ========================================
    // EDGE CASES
    // ========================================

    /// @notice there is no security concenrns if one can mint with zero address
    function test_MintToZeroAddress_Reverts() public {
        // Act & Assert
        vm.startPrank(authorizedMinter);
        vm.expectRevert();
        nft.mintCofferBond(address(0));
        vm.stopPrank();
    }

    function test_TransferToZeroAddress_Reverts() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(holder1);
        vm.expectRevert();
        nft.transferFrom(holder1, address(0), holderId);
        vm.stopPrank();
    }

    function test_UnauthorizedTransfer_Reverts() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(holder2);
        vm.expectRevert();
        nft.transferFrom(holder1, holder3, holderId);
        vm.stopPrank();
    }

    // ========================================
    // TOKEN ID INCREMENT TESTS
    // ========================================

    function test_TokenIdIncrement_Sequential() public {
        // Arrange
        uint256[] memory tokenIds = new uint256[](10);

        // Act
        vm.startPrank(authorizedMinter);
        for (uint256 i = 0; i < 10; i++) {
            tokenIds[i] = nft.mintCofferBond(holder1);
        }
        vm.stopPrank();

        // Assert
        for (uint256 i = 0; i < 10; i++) {
            assertEq(tokenIds[i], i + 1, "Token IDs should be sequential starting from 1");
        }
    }

    function test_TokenIdIncrement_AfterTransfers() public {
        // Arrange
        vm.startPrank(authorizedMinter);
        uint256 holderId1 = nft.mintCofferBond(holder1);
        uint256 holderId2 = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Transfer tokens around
        vm.startPrank(holder1);
        nft.transferFrom(holder1, holder2, holderId1);
        nft.transferFrom(holder1, holder3, holderId2);
        vm.stopPrank();

        // Mint new token
        vm.startPrank(authorizedMinter);
        uint256 holderId3 = nft.mintCofferBond(holder1);
        vm.stopPrank();

        // Assert
        assertEq(holderId3, 3, "Token ID should continue incrementing despite transfers");
    }

    // ========================================
    // SUPPORTS INTERFACE TESTS
    // ========================================

    function test_SupportsInterface_ERC721() public {
        // Assert
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId), "Should support ERC721 interface");
    }

    function test_SupportsInterface_ERC721Metadata() public {
        // Assert
        assertTrue(
            nft.supportsInterface(type(IERC721Metadata).interfaceId), "Should support ERC721Metadata interface"
        );
    }

    function test_SupportsInterface_ERC165() public {
        // Assert
        assertTrue(nft.supportsInterface(0x01ffc9a7), "Should support ERC165 interface");
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    function test_MintGasUsage() public {
        // Measure gas for minting
        vm.startPrank(authorizedMinter);

        uint256 gasBefore = gasleft();
        nft.mintCofferBond(holder1);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        // Log gas usage
        emit log_named_uint("Gas used for minting NFT", gasUsed);

        // Assert reasonable gas usage
        assertTrue(gasUsed < 150_000, "Minting gas usage exceeds expected threshold");
    }
}