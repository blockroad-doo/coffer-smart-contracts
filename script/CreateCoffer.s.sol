//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {CofferFactory} from "../src/CofferFactory.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title CreateCoffer
 * @author Blockroad d.o.o.
 * @notice Script to call createCoffer on existing CofferFactory using .env parameters
 * @dev Reads validator offer parameters from .env, creates a Coffer, and saves the address back to .env
 *
 * Usage:
 *    cd coffer-smart-contracts
 *    set -a && source ../.env && set +a
 *    forge script script/CreateCoffer.s.sol --rpc-url $HOODI_RPC_URL --broadcast --private-key $HOODI_V1_PK
 *
 * Note: Requires ffi = true in foundry.toml
 *     `set -a` exports all vars so forge's vm.env*() cheatcodes can read them.
 */
contract CreateCoffer is Script {
    error InvalidPublicKeyLength();
    error CofferIssuedEventNotFound();

    /// @notice Path to .env file relative to script directory
    string private constant ENV_FILE_PATH = "../.env";

    /// @notice Creates a new Coffer via CofferFactory using parameters from .env
    function run() external {
        // Load factory address
        address factoryAddr = vm.envAddress("HOODI_COFFER_FACTORY_ADDRESS");
        CofferFactory factory = CofferFactory(factoryAddr);

        (bytes32 publicKeyPart1, bytes16 publicKeyPart2) = _loadValidatorPublicKey();

        // Predict the deterministic address before deployment
        address predicted = factory.predictCofferAddress(msg.sender, publicKeyPart1, publicKeyPart2);
        console.log("Predicted Coffer address:", predicted);

        // Create the coffer
        address cofferAddress = _createCoffer(factory, publicKeyPart1, publicKeyPart2);
        if (cofferAddress == address(0)) revert CofferIssuedEventNotFound();
        assert(cofferAddress == predicted);

        console.log("Coffer created at:", cofferAddress);

        address redemptionEscrowAddress = factory.I_COFFER_REDEMPTION_ESCROW_ADDRESS();
        console.log("CofferRedemptionEscrow at:", redemptionEscrowAddress);

        // Update .env file with the new Coffer address
        //console.log("\nUpdating .env file...");
        //updateEnvVariable("HOODI_COFFER_ADDRESS", addressToString(cofferAddress));
        //console.log("COFFER_ADDRESS saved to .env");
    }

    /// @notice Loads env parameters, broadcasts the createCoffer tx, and returns the new Coffer address
    /// @param factory The CofferFactory contract instance
    /// @param publicKeyPart1 First 32 bytes of the BLS public key
    /// @param publicKeyPart2 Remaining 16 bytes of the BLS public key
    /// @return The address of the newly created Coffer
    function _createCoffer(CofferFactory factory, bytes32 publicKeyPart1, bytes16 publicKeyPart2)
        private
        returns (address)
    {
        uint32 interestRate = uint32(vm.envUint("INTEREST_RATE"));
        uint32 minimumDuration = uint32(vm.envUint("MIN_DURATION"));
        uint32 maximumDuration = uint32(vm.envUint("MAX_DURATION"));
        uint128 minimumAmountToAccept = uint128(vm.envUint("MINIMUM_VALUE_TO_ACCEPT"));
        uint16 issueSizeBufferBps = uint16(vm.envUint("ISSUE_SIZE_BUFFER_BPS"));
        uint128 startingBalance = uint128(vm.envUint("STARTING_BALANCE"));

        vm.recordLogs();
        vm.startBroadcast();

        factory.createCoffer(
            publicKeyPart1,
            publicKeyPart2,
            interestRate,
            minimumDuration,
            maximumDuration,
            minimumAmountToAccept,
            issueSizeBufferBps,
            startingBalance
        );

        vm.stopBroadcast();

        return _extractCofferAddress(vm.getRecordedLogs());
    }

    /// @notice Loads and splits the 48-byte BLS public key from env into bytes32 + bytes16
    /// @return publicKeyPart1 First 32 bytes of the BLS public key
    /// @return publicKeyPart2 Remaining 16 bytes of the BLS public key
    function _loadValidatorPublicKey() private returns (bytes32 publicKeyPart1, bytes16 publicKeyPart2) {
        bytes memory pubKey = vm.envBytes("VALIDATOR_PUBLIC_KEY");
        if (pubKey.length != 48) revert InvalidPublicKeyLength();
        assembly {
            publicKeyPart1 := mload(add(pubKey, 32))
            publicKeyPart2 := mload(add(pubKey, 64))
        }
    }

    /// @notice Extracts the Coffer address from CofferIssued event logs
    /// @param logs The recorded VM logs to search
    /// @return cofferAddress The address of the newly created Coffer
    function _extractCofferAddress(Vm.Log[] memory logs) private pure returns (address cofferAddress) {
        bytes32 cofferIssuedTopic =
        // solhint-disable-next-line gas-small-strings
        keccak256("CofferIssued(address,address,bytes32,bytes16,uint32,uint32,uint32,uint128,uint16,uint128)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == cofferIssuedTopic) {
                cofferAddress = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
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
