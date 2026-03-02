//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CofferFactory} from "../../../src/CofferFactory.sol";

contract CofferFactoryHoodi is Test {
    address constant FACTORY = 0x10b10d376602201bede732DD0990790E68B33DaA;
    address constant NFT = 0x0D7d1DE981283D4E92ceAa6015c83B24eD13a222;
    address constant DEPLOYED_COFFER = 0x826A8AC2BDa39c19f5827230Ba6e82E401A94577;

    CofferFactory factory;

    modifier skipIfNoRpc() {
        string memory rpc = vm.envOr("HOODI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        vm.createSelectFork(rpc);
        factory = CofferFactory(FACTORY);
        _;
    }

    function test_FactoryDeployed() public skipIfNoRpc {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(FACTORY)
        }
        assertGt(codeSize, 0, "CofferFactory should be deployed");
    }

    function test_NftAddressNonZero() public skipIfNoRpc {
        assertEq(factory.I_COFFER_BOND_NFT_ADDRESS(), NFT, "NFT address should match expected");
    }

    function test_DeployedCofferExists() public skipIfNoRpc {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(DEPLOYED_COFFER)
        }
        assertGt(codeSize, 0, "Deployed Coffer should exist");
    }

    function test_CofferHasCorrectFactory() public skipIfNoRpc {
        // Deployed Coffer uses old naming convention: i_cofferBondNftAddress()
        (bool ok, bytes memory data) = DEPLOYED_COFFER.staticcall(abi.encodeWithSignature("i_cofferBondNftAddress()"));
        require(ok, "i_cofferBondNftAddress() call failed on deployed Coffer");
        address cofferNft = abi.decode(data, (address));
        assertEq(cofferNft, factory.I_COFFER_BOND_NFT_ADDRESS(), "Coffer NFT address should match factory NFT address");
    }

    function test_CofferOwnerIsValidator() public skipIfNoRpc {
        (bool ok, bytes memory data) = DEPLOYED_COFFER.staticcall(abi.encodeWithSignature("owner()"));
        require(ok, "owner() call failed on deployed Coffer");
        address cofferOwner = abi.decode(data, (address));
        assertNotEq(cofferOwner, address(0), "Coffer owner should not be zero");
    }

    function test_CreateCofferOnFork() public skipIfNoRpc {
        address testUser = makeAddr("testUser");

        vm.prank(testUser);
        vm.expectEmit(true, false, false, false, FACTORY);
        emit CofferFactory.CofferIssued(testUser, address(0));
        factory.createCoffer(
            bytes32(uint256(1)),
            bytes16(uint128(2)),
            1e6, // 1% interest
            30 days,
            365 days,
            1 ether,
            20_000_000,
            true
        );
    }
}
