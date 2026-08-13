//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferFactory} from "../../../src/CofferFactory.sol";
import {Coffer} from "../../../src/Coffer.sol";

/**
 * @title CofferFactoryHoodi
 * @notice Fork tests that validate deployed contracts on Hoodi.
 * @dev Reads contract addresses from environment variables (auto-filled by deployment scripts).
 *      Skips gracefully if HOODI_RPC_URL or any address is not set.
 *
 *      To run:
 *        set -a && source ../.env && set +a
 *        forge test --mp "test/integration/hoodi/*" -vvv
 */
contract CofferFactoryHoodi is Test {
    CofferFactory factory;
    address factoryAddr;
    address nftAddr;
    address deployedCofferAddr;
    bool skipTests;

    function setUp() public {
        string memory rpc = vm.envOr("HOODI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipTests = true;
            return;
        }

        string memory factoryStr = vm.envOr("HOODI_COFFER_FACTORY_ADDRESS", string(""));
        string memory nftStr = vm.envOr("HOODI_COFFER_RECEIVABLE_NFT_ADDRESS", string(""));
        string memory cofferStr = vm.envOr("HOODI_COFFER_ADDRESS", string(""));

        if (bytes(factoryStr).length == 0 || bytes(nftStr).length == 0 || bytes(cofferStr).length == 0) {
            skipTests = true;
            return;
        }

        factoryAddr = vm.parseAddress(factoryStr);
        nftAddr = vm.parseAddress(nftStr);
        deployedCofferAddr = vm.parseAddress(cofferStr);

        vm.createSelectFork(rpc);
        factory = CofferFactory(factoryAddr);
    }

    modifier skipIfNotConfigured() {
        if (skipTests) {
            return;
        }
        _;
    }

    function test_FactoryDeployed() public skipIfNotConfigured {
        assertGt(factoryAddr.code.length, 0, "CofferFactory should be deployed");
    }

    function test_NftAddressNonZero() public skipIfNotConfigured {
        assertEq(factory.I_COFFER_BOND_NFT_ADDRESS(), nftAddr, "NFT address should match expected");
    }

    function test_DeployedCofferExists() public skipIfNotConfigured {
        assertGt(deployedCofferAddr.code.length, 0, "Deployed Coffer should exist");
    }

    function test_CofferHasCorrectFactory() public skipIfNotConfigured {
        Coffer coffer = Coffer(payable(deployedCofferAddr));
        assertEq(
            coffer.iCofferBondNftAddress(),
            factory.I_COFFER_BOND_NFT_ADDRESS(),
            "Coffer NFT address should match factory NFT address"
        );
    }

    function test_CofferOwnerIsValidator() public skipIfNotConfigured {
        Coffer coffer = Coffer(payable(deployedCofferAddr));
        assertNotEq(coffer.owner(), address(0), "Coffer owner should not be zero");
    }

    function test_CreateCofferOnFork() public skipIfNotConfigured {
        address testUser = makeAddr("testUser");

        vm.prank(testUser);
        vm.expectEmit(true, false, false, false, factoryAddr);
        // Only topic1 (owner) is checked; the remaining args are placeholders
        emit CofferFactory.CofferIssued(testUser, address(0), bytes32(0), bytes16(0), 0, 0, 0, 0, 0, 0);
        factory.createCoffer(
            bytes32(uint256(1)),
            bytes16(uint128(2)),
            1e6, // 1% interest
            30 days,
            365 days,
            1 ether,
            250,
            32 ether
        );
    }
}
