// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS,
    EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT,
    CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT,
    CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT,
    MIN_CONSOLIDATION_REQUEST_FEE,
    CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION
} from "../../mock/EIP7251Mock.sol";

/**
 * @title EIP7251ForkValidation
 * @notice Fork validation tests comparing the real EIP-7251 predeploy against mock behavior.
 * @dev All tests are skipped if MAINNET_RPC_URL is not set.
 *      Run with: MAINNET_RPC_URL=... forge test --match-path test/integration/EIP7251ForkValidation.t.sol -vvv
 */
contract EIP7251ForkValidation is Test {
    address payable constant PREDEPLOY = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS;

    /// @dev Pinned post-Pectra block for determinism
    uint256 constant FORK_BLOCK = 22_400_000;

    uint256 fork;
    bool skipTests;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            skipTests = true;
            return;
        }
        fork = vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    modifier skipIfNoRpc() {
        if (skipTests) {
            return;
        }
        _;
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    function _fakeExponential(uint256 factor, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 i = 1;
        uint256 output = 0;
        uint256 numeratorAccum = factor * denominator;
        while (numeratorAccum > 0) {
            output += numeratorAccum;
            numeratorAccum = (numeratorAccum * numerator) / (denominator * i);
            i += 1;
        }
        return output / denominator;
    }

    function _setExcess(uint256 excess) internal {
        vm.store(PREDEPLOY, bytes32(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT), bytes32(excess));
    }

    function _getFee() internal view returns (uint256) {
        (bool success, bytes memory ret) = PREDEPLOY.staticcall("");
        require(success, "getFee staticcall failed");
        return abi.decode(ret, (uint256));
    }

    // ========================================================================
    // FEE MATCHING TESTS
    // ========================================================================

    function test_FeeMatchesAtZeroExcess() public skipIfNoRpc {
        _setExcess(0);
        uint256 realFee = _getFee();
        uint256 expectedFee =
            _fakeExponential(MIN_CONSOLIDATION_REQUEST_FEE, 0, CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION);
        assertEq(realFee, expectedFee, "Fee mismatch at excess=0");
        assertEq(realFee, 1, "Fee at excess=0 should be 1 wei");
    }

    function test_FeeMatchesAtVariousExcess() public skipIfNoRpc {
        uint256[5] memory excessValues = [uint256(1), 10, 17, 50, 100];

        for (uint256 i = 0; i < excessValues.length; i++) {
            _setExcess(excessValues[i]);
            uint256 realFee = _getFee();
            uint256 expectedFee = _fakeExponential(
                MIN_CONSOLIDATION_REQUEST_FEE, excessValues[i], CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION
            );
            assertEq(realFee, expectedFee, string.concat("Fee mismatch at excess=", vm.toString(excessValues[i])));
        }
    }

    function test_FeeMatchesAtActualExcess() public skipIfNoRpc {
        uint256 actualExcess = uint256(vm.load(PREDEPLOY, bytes32(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT)));
        // Skip if excess is the inhibitor (contract not initialized at this block)
        vm.assume(actualExcess != type(uint256).max);

        uint256 expectedFee =
            _fakeExponential(MIN_CONSOLIDATION_REQUEST_FEE, actualExcess, CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION);
        uint256 realFee = _getFee();
        assertEq(realFee, expectedFee, "Fee mismatch at actual excess value");
    }

    // ========================================================================
    // ADD REQUEST TEST
    // ========================================================================

    function test_AddRequestSucceeds() public skipIfNoRpc {
        _setExcess(0);
        uint256 fee = _getFee();

        // Read state before
        uint256 countBefore = uint256(vm.load(PREDEPLOY, bytes32(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT)));
        uint256 tailBefore = uint256(vm.load(PREDEPLOY, bytes32(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT)));

        // 96-byte calldata: source pubkey (48 bytes) + target pubkey (48 bytes)
        bytes memory requestData = abi.encodePacked(
            bytes32(uint256(0xaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd)),
            bytes16(uint128(0xeeff00112233445566778899aabbccdd)),
            bytes16(uint128(0x11223344556677881122334455667788)),
            bytes32(uint256(0x33445566778899aa33445566778899aa33445566778899aa33445566778899aa))
        );

        vm.deal(address(this), fee);
        (bool success,) = PREDEPLOY.call{value: fee}(requestData);
        assertTrue(success, "Add request should succeed");

        // Verify queue state
        uint256 countAfter = uint256(vm.load(PREDEPLOY, bytes32(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT)));
        uint256 tailAfter = uint256(vm.load(PREDEPLOY, bytes32(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT)));
        assertEq(countAfter, countBefore + 1, "Count should increment by 1");
        assertEq(tailAfter, tailBefore + 1, "Tail should increment by 1");
    }

    // ========================================================================
    // REVERT TESTS
    // ========================================================================

    function test_RevertFeeGetterWithValue() public skipIfNoRpc {
        _setExcess(0);
        vm.deal(address(this), 1 ether);
        (bool success,) = PREDEPLOY.call{value: 1}("");
        assertFalse(success, "Fee getter with nonzero value should revert");
    }

    function test_RevertInvalidCalldataLength() public skipIfNoRpc {
        _setExcess(0);
        uint256[4] memory lengths = [uint256(1), 32, 95, 97];

        for (uint256 i = 0; i < lengths.length; i++) {
            bytes memory data = new bytes(lengths[i]);
            (bool success,) = PREDEPLOY.call(data);
            assertFalse(success, string.concat("Should revert for calldata length ", vm.toString(lengths[i])));
        }
    }

    function test_RevertInsufficientFee() public skipIfNoRpc {
        _setExcess(0);

        // 96-byte calldata with value=0
        bytes memory requestData = new bytes(96);
        (bool success,) = PREDEPLOY.call{value: 0}(requestData);
        assertFalse(success, "Should revert when fee is insufficient");
    }

    function test_RevertExcessInhibitor() public skipIfNoRpc {
        _setExcess(type(uint256).max);

        // Any call should revert
        (bool success,) = PREDEPLOY.staticcall("");
        assertFalse(success, "Should revert when excess is EXCESS_INHIBITOR");
    }
}
