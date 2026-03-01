//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {BaseTest} from "../../unit/BaseTest.sol";
import {CofferFactory} from "../../../src/CofferFactory.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {CofferFactoryHandler} from "./CofferFactoryHandler.sol";

contract CofferFactoryInvariantTest is BaseTest {
    CofferFactoryHandler public handler;
    address public storedNftAddress;

    function setUp() public virtual override {
        // Deploy mocks at canonical addresses (required by Coffer constructor)
        deployEip7002Mock();
        deployEip7251Mock();
        deployDepositContractMock();

        // Deploy factory (which deploys the shared NFT)
        factory = new CofferFactory();
        bondNft = CofferBondNft(factory.I_COFFER_BOND_NFT_ADDRESS());
        storedNftAddress = address(bondNft);

        handler = new CofferFactoryHandler(factory);
        targetContract(address(handler));
    }

    function invariant_DeploymentCountMatchesGhost() public view {
        assertEq(
            handler.getDeployedCoffersLength(),
            handler.ghostDeploymentCount(),
            "Deployed array length must match deployment count"
        );
    }

    function invariant_AllCoffersHaveCorrectNftAddress() public view {
        uint256 len = handler.getDeployedCoffersLength();
        for (uint256 i = 0; i < len; i++) {
            address cofferAddr = handler.getDeployedCofferAt(i);
            assertEq(
                Coffer(payable(cofferAddr)).I_COFFER_BOND_NFT_ADDRESS(),
                factory.I_COFFER_BOND_NFT_ADDRESS(),
                "Coffer NFT address must match factory NFT address"
            );
        }
    }

    function invariant_FactoryNftAddressIsImmutable() public view {
        assertTrue(
            factory.I_COFFER_BOND_NFT_ADDRESS() != address(0),
            "Factory NFT address must not be zero"
        );
        assertEq(
            factory.I_COFFER_BOND_NFT_ADDRESS(),
            storedNftAddress,
            "Factory NFT address must remain immutable"
        );
    }

    function invariant_EveryDeployedCofferIsValidContract() public view {
        uint256 len = handler.getDeployedCoffersLength();
        for (uint256 i = 0; i < len; i++) {
            address cofferAddr = handler.getDeployedCofferAt(i);
            assertTrue(
                cofferAddr.code.length > 0,
                "Deployed coffer must have code"
            );
        }
    }

    function invariant_DeployedCoffersAreActive() public view {
        uint256 len = handler.getDeployedCoffersLength();
        for (uint256 i = 0; i < len; i++) {
            address cofferAddr = handler.getDeployedCofferAt(i);
            (,,,,,,,,bool isActive,) = Coffer(payable(cofferAddr)).sValidatorConditions();
            assertTrue(isActive, "Newly deployed coffer must be active");
        }
    }
}
