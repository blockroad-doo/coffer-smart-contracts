//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {CofferFactory} from "../src/CofferFactory.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DeployCofferFactory
 * @notice Deployment script for CofferFactory contract
 * @dev CofferFactory constructor automatically deploys CofferReceivableNFT internally
 * @dev Automatically updates .env file with deployed contract addresses
 *
 * Usage:
 *      forge script script/DeployCofferFactory.s.sol --rpc-url <RPC_URL> --broadcast --verify
 *
 * For local testing:
 *      forge script script/DeployCofferFactory.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Note: Requires ffi = true in foundry.toml
 */
contract DeployCofferFactory is Script {
    /// @dev Path to .env file relative to script directory
    string constant ENV_FILE_PATH = "../.env";

    function run() external returns (CofferFactory) {
        vm.startBroadcast();

        CofferFactory cofferFactory = new CofferFactory();

        vm.stopBroadcast();

        address factoryAddress = address(cofferFactory);

        // Log the deployed addresses
        console.log("CofferFactory deployed at:", factoryAddress);

        // Update .env file with deployed addresses
        console.log("\nUpdating .env file...");
        updateEnvVariable("HOODI_COFFER_FACTORY_ADDRESS", addressToString(factoryAddress));
        console.log(".update nft address manually!");

        return cofferFactory;
    }

    /// @dev Update an environment variable in the .env file using sed
    /// @param key The environment variable name
    /// @param value The new value to set
    function updateEnvVariable(string memory key, string memory value) internal {
        string[] memory inputs = new string[](4);
        inputs[0] = "sed";
        inputs[1] = "-i";
        inputs[2] = string(abi.encodePacked("s/^", key, "=.*$/", key, "=", value, "/"));
        inputs[3] = ENV_FILE_PATH;

        // Execute sed command via FFI
        vm.ffi(inputs);
    }

    /// @dev Convert address to string (without 0x prefix for sed compatibility)
    /// @param addr The address to convert
    /// @return The address as a checksummed string with 0x prefix
    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(2 + data.length * 2);

        str[0] = "0";
        str[1] = "x";

        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }

        return string(str);
    }
}
