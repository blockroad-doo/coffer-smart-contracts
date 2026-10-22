//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {CofferFactory} from "../src/CofferFactory.sol";
import {FeeCurve} from "../src/FeeCurve.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DeployCofferFactory
 * @author Blockroad d.o.o.
 * @notice Deployment script for CofferFactory contract
 * @dev CofferFactory constructor automatically deploys CofferBondNft internally
 * @dev Automatically updates .env file with deployed contract addresses
 * @dev The broadcaster becomes the owner of the shared FeeCurve, because the CofferFactory constructor creates it
 * with msg.sender as owner, and that owner can change the fee recipient. Set PROTOCOL_ADMIN to the protocol admin
 * Safe and the same broadcast calls transferOwnership on the new FeeCurve, which leaves the role pending for the
 * Safe. The Safe then calls acceptOwnership() before the first bond purchase. Leave PROTOCOL_ADMIN unset for a
 * testnet deployment, which has no Safe, and the broadcaster keeps the role
 * @dev Launch check, both reads must hold before the first bond purchase:
 *      cast call <FEE_CURVE> "owner()(address)" --rpc-url <RPC_URL>          the Safe
 *      cast call <FEE_CURVE> "pendingOwner()(address)" --rpc-url <RPC_URL>   the zero address
 *
 * Usage:
 *      forge script script/DeployCofferFactory.s.sol --rpc-url <RPC_URL> --broadcast --verify
 *      PROTOCOL_ADMIN=<SAFE> forge script script/DeployCofferFactory.s.sol --rpc-url <RPC_URL> --broadcast --verify
 *
 * For local testing:
 *      forge script script/DeployCofferFactory.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Note: Requires ffi = true in foundry.toml
 */
contract DeployCofferFactory is Script {
    /// @notice Path to .env file relative to script directory
    string private constant ENV_FILE_PATH = "../.env";

    /// @notice PROTOCOL_ADMIN must be a contract, a Safe, never a plain key
    error ProtocolAdminHasNoCode();

    // solhint-disable function-max-lines
    /// @notice Deploys CofferFactory and updates .env with deployed addresses
    /// @return The deployed CofferFactory instance
    function run() external returns (CofferFactory) {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        // Optional, see the header. Zero means no handover, the broadcaster keeps the FeeCurve
        address protocolAdmin = vm.envOr("PROTOCOL_ADMIN", address(0));
        require(protocolAdmin == address(0) || protocolAdmin.code.length > 0, ProtocolAdminHasNoCode());

        vm.startBroadcast();

        CofferFactory cofferFactory = new CofferFactory(feeRecipient);
        if (protocolAdmin != address(0)) {
            // The broadcaster owns the new FeeCurve at this point, so the transfer is allowed. Ownable2Step
            // leaves the role pending until the Safe calls acceptOwnership()
            FeeCurve(cofferFactory.I_FEE_CURVE_ADDRESS()).transferOwnership(protocolAdmin);
        }

        vm.stopBroadcast();

        address factoryAddress = address(cofferFactory);

        // Log the deployed addresses
        console.log("CofferFactory deployed at:", factoryAddress);

        // Update .env file with deployed addresses
        console.log("\nUpdating .env file...");
        updateEnvVariable("HOODI_COFFER_FACTORY_ADDRESS", addressToString(factoryAddress));

        address nftAddress = cofferFactory.I_COFFER_BOND_NFT_ADDRESS();
        console.log("CofferBondNft deployed at:", nftAddress);
        // solhint-disable-next-line gas-small-strings
        updateEnvVariable("HOODI_COFFER_BOND_NFT_ADDRESS", addressToString(nftAddress));

        address implAddress = cofferFactory.I_COFFER_IMPLEMENTATION();
        // solhint-disable-next-line gas-small-strings
        console.log("Coffer implementation deployed at:", implAddress);
        // solhint-disable-next-line gas-small-strings
        updateEnvVariable("HOODI_COFFER_IMPLEMENTATION_ADDRESS", addressToString(implAddress));

        address redemptionEscrowAddress = cofferFactory.I_COFFER_REDEMPTION_ESCROW_ADDRESS();
        // solhint-disable-next-line gas-small-strings
        console.log("CofferRedemptionEscrow deployed at:", redemptionEscrowAddress);
        // solhint-disable-next-line gas-small-strings
        updateEnvVariable("HOODI_COFFER_REDEMPTION_ESCROW_ADDRESS", addressToString(redemptionEscrowAddress));

        address feeCurveAddress = cofferFactory.I_FEE_CURVE_ADDRESS();
        // solhint-disable-next-line gas-small-strings
        console.log("FeeCurve deployed at:", feeCurveAddress);
        // solhint-disable-next-line gas-small-strings
        updateEnvVariable("HOODI_FEE_CURVE_ADDRESS", addressToString(feeCurveAddress));

        if (protocolAdmin != address(0)) {
            console.log("FeeCurve pending owner:", protocolAdmin);
            // solhint-disable-next-line gas-small-strings
            console.log("Call acceptOwnership() from it before the first bond purchase");
        } else {
            // solhint-disable-next-line gas-small-strings
            console.log("FeeCurve owner is the broadcaster, hand the role over before the first bond purchase");
        }

        return cofferFactory;
    }

    // solhint-enable function-max-lines

    /// @notice Update an environment variable in the .env file using sed
    /// @param key The environment variable name
    /// @param value The new value to set
    function updateEnvVariable(string memory key, string memory value) internal {
        string[] memory inputs = new string[](4);
        inputs[0] = "sed";
        inputs[1] = "-i";
        inputs[2] = string(abi.encodePacked("s/^", key, "=.*$/", key, "=", value, "/"));
        inputs[3] = ENV_FILE_PATH;

        // Execute sed command via FFI
        // forge-lint: disable-next-line(unsafe-cheatcode) ffi needed to update .env file
        vm.ffi(inputs);
    }

    /// @notice Convert address to string (without 0x prefix for sed compatibility)
    /// @param addr The address to convert
    /// @return The address as a checksummed string with 0x prefix
    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(2 + data.length * 2);

        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < data.length; ++i) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }

        return string(str);
    }
}
