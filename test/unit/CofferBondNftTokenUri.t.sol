//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {Coffer} from "../../src/Coffer.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CofferBondNftTokenUriTest is BaseTest {
    address public cofferAddr;
    Coffer public testCoffer;

    function setUp() public override {
        super.setUp();
        cofferAddr = createDefaultCoffer();
        testCoffer = Coffer(payable(cofferAddr));
    }

    // ========================================
    // HELPERS
    // ========================================

    /// @dev Sets issueSize on a coffer so bonds can be bought. Returns new version.
    function _enableBonding(address cofferAddress, address cofferValidator, uint128 available)
        internal
        returns (uint32 version)
    {
        vm.prank(cofferValidator);
        Coffer(payable(cofferAddress)).changeIssueSize(available);
        version = 2;
    }

    function _decodeTokenUri(string memory uri) internal pure returns (string memory) {
        // Strip "data:application/json;base64," prefix (29 chars)
        bytes memory uriBytes = bytes(uri);
        uint256 prefixLen = 29;
        bytes memory encoded = new bytes(uriBytes.length - prefixLen);
        for (uint256 i = 0; i < encoded.length; i++) {
            encoded[i] = uriBytes[i + prefixLen];
        }
        return string(Base64.decode(string(encoded)));
    }

    // ========================================
    // HAPPY PATH
    // ========================================

    function test_tokenURI_HappyPath() public {
        uint32 version = _enableBonding(cofferAddr, validator, 10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        string memory uri = bondNft.tokenURI(bondId);

        // Verify prefix
        bytes memory uriBytes = bytes(uri);
        // starts with data:application/json;base64,
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes1(uriBytes[0]), bytes1("d"));

        // Decode and verify JSON content
        string memory json = _decodeTokenUri(uri);
        bytes memory jsonBytes = bytes(json);

        // Verify it starts with {"name":"Coffer Bond #
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(jsonBytes[0], bytes1("{"));

        // Verify bond ID is present
        assertTrue(_contains(json, '"name":"Coffer Bond #1"'));

        // Verify coffer address is present (lowercase hex)
        assertTrue(_contains(json, Strings.toHexString(cofferAddr)));

        // Verify validator public key
        string memory expectedPubKey = Strings.toHexString(abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2));
        assertTrue(_contains(json, expectedPubKey));

        // Verify maturesAt (startTimestamp + duration)
        (, uint32 duration, uint32 startTimestamp) = testCoffer.sHolderConditions(bondId);
        uint256 maturesAt = uint256(startTimestamp) + uint256(duration);
        assertTrue(_contains(json, string.concat('"maturesAt":', Strings.toString(maturesAt))));

        // Verify maturityValue
        (uint128 bondMaturityValue,,) = testCoffer.sHolderConditions(bondId);
        assertTrue(
            _contains(json, string.concat('"maturityValue":"', Strings.toString(uint256(bondMaturityValue)), '"'))
        );
    }

    // ========================================
    // REVERT CASES
    // ========================================

    function test_tokenURI_RevertsForNonExistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        bondNft.tokenURI(999);
    }

    function test_tokenURI_RevertsForBurnedToken() public {
        uint32 version = _enableBonding(cofferAddr, validator, 10 ether);
        uint256 bondId = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version);

        // Warp past maturity and fund coffer so holder can redeem (which burns the NFT)
        advanceTime(ONE_MONTH + 1);
        vm.deal(cofferAddr, 2 ether);

        vm.prank(holder1);
        testCoffer.holderRedeemBondOrDefault(bondId);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, bondId));
        bondNft.tokenURI(bondId);
    }

    // ========================================
    // MULTIPLE BONDS / DIFFERENT COFFERS
    // ========================================

    function test_tokenURI_MultipleBondsDifferentCoffers() public {
        // Create a second coffer with different pubkey
        bytes32 pubKey2Part1 = bytes32(uint256(42));
        bytes16 pubKey2Part2 = bytes16(uint128(43));
        address cofferAddr2 = createCoffer(
            holder3, // different validator
            pubKey2Part1,
            pubKey2Part2,
            defaultInterestRate,
            defaultMinDuration,
            defaultMaxDuration,
            defaultMinimumAmount,
            defaultIssueSizeBufferBps
        );

        uint32 version1 = _enableBonding(cofferAddr, validator, 10 ether);
        uint32 version2 = _enableBonding(cofferAddr2, holder3, 10 ether);
        uint256 bondId1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, version1);
        uint256 bondId2 = buyBond(cofferAddr2, holder2, 2 ether, ONE_MONTH, version2);

        string memory json1 = _decodeTokenUri(bondNft.tokenURI(bondId1));
        string memory json2 = _decodeTokenUri(bondNft.tokenURI(bondId2));

        // Bond 1 should reference first coffer
        assertTrue(_contains(json1, Strings.toHexString(cofferAddr)));
        string memory pubKey1 = Strings.toHexString(abi.encodePacked(validPublicKeyPart1, validPublicKeyPart2));
        assertTrue(_contains(json1, pubKey1));

        // Bond 2 should reference second coffer
        assertTrue(_contains(json2, Strings.toHexString(cofferAddr2)));
        string memory pubKey2 = Strings.toHexString(abi.encodePacked(pubKey2Part1, pubKey2Part2));
        assertTrue(_contains(json2, pubKey2));

        // They should have different bond IDs in the name
        assertTrue(_contains(json1, string.concat('"name":"Coffer Bond #', Strings.toString(bondId1), '"')));
        assertTrue(_contains(json2, string.concat('"name":"Coffer Bond #', Strings.toString(bondId2), '"')));
    }

    // ========================================
    // STRING SEARCH HELPER
    // ========================================

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
