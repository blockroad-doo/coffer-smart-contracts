//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {CofferBondNft} from "../../src/CofferBondNft.sol";

contract VerifyVersionPhantomTest is BaseTest {
    address public cofferAddr;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        coffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // V-5: changeMinimumValueToAccept missing version bump
    // ========================================

    function test_V5_MinimumValueToAccept_MissingVersionBump_AllowsFrontrun() public {
        // Setup: validator sets issueSize so bonds can be bought
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);
        // changeIssueSize bumps version to 2

        // Holder reads version, sends tx buying a bond for 1 ether
        // But validator front-runs: increases minimumValueToAccept to 2 ether
        // (no version bump)
        vm.prank(validator);
        coffer.changeMinimumValueToAccept(2 ether);

        // Holder's tx arrives with old version=2, but msg.value=1 ether < 2 ether minimum
        vm.startPrank(holder1);
        bytes memory err = abi.encodeWithSelector(Coffer.ValueTooSmallToAccept.selector);
        vm.expectRevert(err);
        coffer.buyBond{value: 1 ether}(ONE_MONTH, 2);
        vm.stopPrank();

        // Verify version is STILL 2 (changeMinimumValueToAccept didn't bump it)
        (,,,,, uint32 version,,,,) = coffer.sValidatorConditions();
        assertEq(version, 2, "Version should still be 2 -- no bump occurred");
    }

    function test_V5_MinimumValueToAccept_NormalBuyBondWorks() public {
        // Set up issueSize to allow bonds
        vm.prank(validator);
        coffer.changeIssueSize(100 ether);

        // MinimumValueToAccept defaults to 1 ether
        // Holder buys a bond with 1 ether -- should succeed
        vm.startPrank(holder1);
        uint256 bondId = coffer.buyBond{value: 1 ether}(ONE_MONTH, 2);
        vm.stopPrank();

        assertEq(bondId, 1);
        (uint128 bondMaturityValue,,,) = coffer.sHolderConditions(bondId);
        assertGt(bondMaturityValue, 0, "Bond should have non-zero maturity value");
    }

    // ========================================
    // V-6: Phantom bonds via direct mintCofferBond
    // ========================================

    function test_V6_RegisteredCoffer_CanMintPhantomBond() public {
        // The Coffer contract at cofferAddr was created via the factory,
        // which calls bondNft.registerCoffer(cofferAddr).
        // So the Coffer is a registered minter.
        assertTrue(bondNft.isRegisteredCoffer(cofferAddr), "Coffer should be registered");

        // The Coffer itself calls mintCofferBond directly, bypassing buyBond
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);
        assertEq(phantomBondId, 1, "Phantom bond should be minted with ID 1");

        // NFT exists and is owned by holder1
        assertEq(bondNft.ownerOf(phantomBondId), holder1);
        assertEq(bondNft.cofferOf(phantomBondId), cofferAddr);

        // But sHolderConditions is all zeros (no entry was created in buyBond)
        (uint128 bondMaturityValue, uint32 duration, uint32 startTimestamp, bool consensusClosed) =
            coffer.sHolderConditions(phantomBondId);
        assertEq(bondMaturityValue, 0, "Phantom bond maturity value should be 0");
        assertEq(duration, 0, "Phantom bond duration should be 0");
        assertEq(startTimestamp, 0, "Phantom bond startTimestamp should be 0");
        assertEq(consensusClosed, false);
    }

    function test_V6_PhantomBond_HolderWithdrawFromExecutionReverts() public {
        // Create phantom bond
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);

        // Advance time past any possible maturity
        vm.warp(block.timestamp + ONE_YEAR);

        // Holder tries to withdraw from execution -- should revert because bondMaturityValue == 0
        vm.startPrank(holder1);
        bytes memory err = abi.encodeWithSelector(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        vm.expectRevert(err);
        coffer.holderWithdrawFromExecution(phantomBondId);
        vm.stopPrank();
    }

    function test_V6_PhantomBond_HolderWithdrawFromConsensusReverts() public {
        // Create phantom bond
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);

        // Advance time
        vm.warp(block.timestamp + ONE_YEAR);

        // Holder tries to withdraw from consensus -- should revert
        vm.startPrank(holder1);
        bytes memory err = abi.encodeWithSelector(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        vm.expectRevert(err);
        coffer.holderWithdrawFromConsensus{value: 1 ether}(phantomBondId);
        vm.stopPrank();
    }

    function test_V6_PhantomBond_RedeemBondsEarlyReverts() public {
        // Create phantom bond
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);

        // Validator tries to redeem early -- should revert
        vm.startPrank(validator);
        uint256[] memory ids = new uint256[](1);
        ids[0] = phantomBondId;
        bytes memory err = abi.encodeWithSelector(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        vm.expectRevert(err);
        coffer.redeemBondsEarly(ids);
        vm.stopPrank();
    }

    function test_V6_PhantomBond_CanBeTransferred_ToSecondaryBuyer() public {
        // Create phantom bond for holder1
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);

        // holder1 transfers phantom bond to holder2
        vm.prank(holder1);
        bondNft.transferFrom(holder1, holder2, phantomBondId);

        assertEq(bondNft.ownerOf(phantomBondId), holder2, "Phantom bond should be transferable");

        // holder2 can't withdraw either
        vm.warp(block.timestamp + ONE_YEAR);
        vm.startPrank(holder2);
        bytes memory err = abi.encodeWithSelector(Coffer.HolderDoesNotExistOrAlreadyWithdrawnValue.selector);
        vm.expectRevert(err);
        coffer.holderWithdrawFromExecution(phantomBondId);
        vm.stopPrank();
    }

    function test_V6_PhantomBond_OnlyMintingCofferCanBurn() public {
        // Create phantom bond
        vm.prank(cofferAddr);
        uint256 phantomBondId = bondNft.mintCofferBond(holder1);

        // holder1 cannot burn it
        vm.prank(holder1);
        vm.expectRevert(CofferBondNft.OnlyCofferCanBurn.selector);
        bondNft.burnCofferBond(phantomBondId);

        // The Coffer contract that minted it can burn it
        vm.prank(cofferAddr);
        bondNft.burnCofferBond(phantomBondId);

        // Verify token no longer exists
        vm.expectRevert();
        bondNft.ownerOf(phantomBondId);
    }
}
