//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {CofferFactory} from "../src/CofferFactory.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DeployCofferFactory
 * @author Blockroad Ltd
 * @notice Deployment script for CofferFactory contract
 * @dev CofferFactory constructor automatically deploys CofferBondNft internally
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
    /// @notice Path to .env file relative to script directory
    string private constant ENV_FILE_PATH = "../.env";

    /// @notice Deploys CofferFactory and updates .env with deployed addresses
    /// @return The deployed CofferFactory instance
    function run() external returns (CofferFactory) {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast();

        CofferFactory cofferFactory = new CofferFactory(feeRecipient);

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

        return cofferFactory;
    }

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
