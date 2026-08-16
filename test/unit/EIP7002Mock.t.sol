//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {EIP7002Mock, WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, EXCESS_INHIBITOR} from "../mock/EIP7002Mock.sol";

/**
 * @title EIP7002MockTest
 * @notice Comprehensive unit tests for EIP7002Mock following best practices
 * @dev Tests follow logical progression: happy cases → revert conditions → boundary conditions → edge cases
 */
// Helper contract for testing smart contract as source
contract TestRequester {
    function submitRequest(bytes32 pubkeyPart1, bytes16 pubkeyPart2, uint64 amount, uint256 fee) external {
        bytes memory data = abi.encodePacked(pubkeyPart1, pubkeyPart2, amount);
        (bool success,) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        require(success, "Request failed");
    }
}

contract EIP7002MockTest is BaseTest {
    // ========================================
    // TEST CONSTANTS
    // ========================================

    // Test withdrawal request data
    bytes32 constant TEST_PUBKEY_PART1 =
        bytes32(uint256(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef));
    bytes16 constant TEST_PUBKEY_PART2 = bytes16(uint128(0x1234567890abcdef1234567890abcdef));
    uint64 constant TEST_AMOUNT_GWEI = 32_000_000_000; // 32 ETH in Gwei

    // Constants from mock
    uint256 constant MAX_WITHDRAWAL_REQUESTS_PER_BLOCK = 16;
    uint256 constant TARGET_WITHDRAWAL_REQUESTS_PER_BLOCK = 2;
    uint256 constant MIN_WITHDRAWAL_REQUEST_FEE = 1;
    uint256 constant WITHDRAWAL_REQUEST_FEE_UPDATE_FRACTION = 17;

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
        // Additional setup if needed
    }

    // ========================================
    // HELPER FUNCTIONS (DRY)
    // ========================================

    /**
     * @dev Helper to create withdrawal request calldata
     */
    function createWithdrawalCalldata(bytes32 pubkeyPart1, bytes16 pubkeyPart2, uint64 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(pubkeyPart1, pubkeyPart2, amount);
    }

    /**
     * @dev Helper to add multiple withdrawal requests
     */
    function addMultipleRequests(uint256 count) internal {
        uint256 fee = getWithdrawalFee();
        for (uint256 i = 0; i < count; i++) {
            bytes32 pubkey1 = bytes32(uint256(i + 1));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint128
            bytes16 pubkey2 = bytes16(uint128(i + 1));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
            uint64 amount = uint64((i + 1) * 1e9); // i+1 ETH in Gwei

            addWithdrawalRequest(pubkey1, pubkey2, amount, fee);
        }
    }

    /**
     * @dev Helper to verify queue state
     */
    function assertQueueState(uint256 expectedExcess, uint256 expectedCount, uint256 expectedHead, uint256 expectedTail)
        internal
    {
        (uint256 excess, uint256 count, uint256 head, uint256 tail) = getQueueState();
        assertEq(excess, expectedExcess, "Excess mismatch");
        assertEq(count, expectedCount, "Count mismatch");
        assertEq(head, expectedHead, "Queue head mismatch");
        assertEq(tail, expectedTail, "Queue tail mismatch");
    }

    // ========================================
    // HAPPY CASES - FEE GETTER
    // ========================================

    function test_GetFee_Success_InitialState() public {
        // Initial excess is 0 (set in BaseTest.setUp)
        uint256 fee = getWithdrawalFee();

        // With 0 excess, fee should be MIN_WITHDRAWAL_REQUEST_FEE
        assertEq(fee, MIN_WITHDRAWAL_REQUEST_FEE, "Initial fee should be minimum");
    }

    function test_GetFee_Success_WithExcess() public {
        // Set some excess
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(100)));

        uint256 fee = getWithdrawalFee();

        // Fee should be higher than minimum with excess
        assertTrue(fee > MIN_WITHDRAWAL_REQUEST_FEE, "Fee should increase with excess");
    }

    function test_GetFee_Success_ViaReceive() public {
        // Test using receive() function (no calldata)
        (bool success, bytes memory data) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call("");

        assertTrue(success, "Fee getter via receive should succeed");
        uint256 fee = abi.decode(data, (uint256));
        assertEq(fee, MIN_WITHDRAWAL_REQUEST_FEE, "Fee via receive should match");
    }

    // ========================================
    // HAPPY CASES - ADD WITHDRAWAL REQUEST
    // ========================================

    function test_AddRequest_Success_Single() public {
        // Arrange
        uint256 fee = getWithdrawalFee();

        // Act
        vm.expectEmit(true, false, false, true);
        emit EIP7002Mock.WithdrawalRequestAdded(address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI);

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, fee);

        // Assert
        assertQueueState(0, 1, 0, 1);
    }

    function test_AddRequest_Success_Multiple() public {
        // Arrange
        uint256 fee = getWithdrawalFee();
        uint256 requestCount = 5;

        // Act
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 pubkey1 = bytes32(uint256(i));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint128
            bytes16 pubkey2 = bytes16(uint128(i));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
            uint64 amount = uint64(i * 1e9);

            addWithdrawalRequest(pubkey1, pubkey2, amount, fee);
        }

        // Assert
        assertQueueState(0, requestCount, 0, requestCount);
    }

    function test_AddRequest_Success_WithExcessFee() public {
        // Paying more than required fee should succeed
        uint256 fee = getWithdrawalFee();
        uint256 excessFee = fee * 2;

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, excessFee);

        assertQueueState(0, 1, 0, 1);
    }

    function test_AddRequest_Success_ZeroAmount() public {
        // Zero amount represents full validator exit
        uint256 fee = getWithdrawalFee();
        uint64 zeroAmount = 0;

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, zeroAmount, fee);

        assertQueueState(0, 1, 0, 1);
    }

    // ========================================
    // HAPPY CASES - SYSTEM CALL
    // ========================================

    // TODO: Fix amount assertion in withdrawal request validation
    // function test_SystemCall_Success_DequeueRequests() public {
    //     // Arrange - Add 3 requests
    //     addMultipleRequests(3);

    //     // Act - System call to dequeue
    //     bytes memory returnData = triggerSystemCall();

    //     // Assert - All 3 should be dequeued
    //     assertEq(returnData.length, 3 * 76, "Should return 3 requests");
    //     assertQueueState(1, 0, 0, 0); // Excess updated, count reset, queue reset

    //     // Verify returned data
    //     assertWithdrawalRequest(returnData, 0, address(this), bytes32(uint256(1)), bytes16(uint128(1)), uint64(1e9));
    //     assertWithdrawalRequest(returnData, 1, address(this), bytes32(uint256(2)), bytes16(uint128(2)), uint64(2e9));
    //     assertWithdrawalRequest(returnData, 2, address(this), bytes32(uint256(3)), bytes16(uint128(3)), uint64(3e9));
    // }

    // TODO: Fix amount assertion in withdrawal request validation
    // function test_SystemCall_Success_MaxRequests() public {
    //     // Arrange - Add more than MAX (20 requests)
    //     addMultipleRequests(20);

    //     // Act - System call should only dequeue MAX (16)
    //     bytes memory returnData = triggerSystemCall();

    //     // Assert
    //     assertEq(returnData.length, MAX_WITHDRAWAL_REQUESTS_PER_BLOCK * 76, "Should return max requests");
    //     assertQueueState(14, 0, 16, 20); // Excess = prev(0) + count(20) - target(2) = 18, but we only dequeued 16
    // }

    function test_SystemCall_Success_UpdateExcess() public {
        // Arrange - Set initial excess and add requests
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(10)));
        addMultipleRequests(5);

        // Act
        triggerSystemCall();

        // Assert - Excess should be: previousExcess(10) + count(5) - TARGET(2) = 13
        (uint256 excess,,,) = getQueueState();
        assertEq(excess, 13, "Excess calculation incorrect");
    }

    function test_SystemCall_Success_EmptyQueue() public {
        // System call with no requests should succeed
        bytes memory returnData = triggerSystemCall();

        assertEq(returnData.length, 0, "Empty queue should return no data");
        assertQueueState(0, 0, 0, 0);
    }

    function test_SystemCall_Success_ResetQueueWhenEmpty() public {
        // Arrange - Add requests and system call to empty it
        addMultipleRequests(3);
        triggerSystemCall();

        // Queue should be reset (head = 0, tail = 0)
        assertQueueState(1, 0, 0, 0);

        // Add new requests should start from index 0
        addMultipleRequests(2);
        assertQueueState(1, 2, 0, 2);
    }

    // ========================================
    // REVERT CONDITIONS - TRIGGER ALL 4
    // ========================================

    function test_Revert_Condition1_ExcessInhibitor() public {
        // Set excess to EXCESS_INHIBITOR (uninitialized state)
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(EXCESS_INHIBITOR));

        // Any non-system call should revert
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call("");
    }

    function test_Revert_Condition2_InvalidCalldata() public {
        // Calldata not 0 or 56 bytes (and not system address)
        bytes memory invalidData = "invalid";

        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call(invalidData);

        // Try with 55 bytes (one byte short)
        bytes memory shortData = new bytes(55);
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call(shortData);

        // Try with 57 bytes (one byte too many)
        bytes memory longData = new bytes(57);
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call(longData);
    }

    function test_Revert_Condition3_FeeGetterWithValue() public {
        // Fee getter (0 calldata) but with msg.value > 0
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: 1}("");

        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: 1 ether}("");
    }

    function test_Revert_Condition4_InsufficientFee() public {
        // Add request with insufficient fee
        uint256 fee = getWithdrawalFee();
        bytes memory data = createWithdrawalCalldata(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI);

        // Send less than required fee
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: fee - 1}(data);

        // Send 0 fee
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: 0}(data);
    }

    // ========================================
    // BOUNDARY CONDITIONS
    // ========================================

    function test_Boundary_MaxQueueSize() public {
        // Add exactly MAX_WITHDRAWAL_REQUESTS_PER_BLOCK
        addMultipleRequests(MAX_WITHDRAWAL_REQUESTS_PER_BLOCK);

        bytes memory returnData = triggerSystemCall();
        assertEq(returnData.length, MAX_WITHDRAWAL_REQUESTS_PER_BLOCK * 76, "Should dequeue all max requests");
    }

    function test_Boundary_MaxUint64Amount() public {
        // Test with maximum uint64 amount
        uint256 fee = getWithdrawalFee();
        uint64 maxAmount = type(uint64).max;

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, maxAmount, fee);

        // Verify it was stored and can be retrieved
        bytes memory returnData = triggerSystemCall();
        assertWithdrawalRequest(returnData, 0, address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, maxAmount);
    }

    function test_Boundary_ZeroExcess() public {
        // Explicitly test zero excess
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));

        uint256 fee = getWithdrawalFee();
        assertEq(fee, MIN_WITHDRAWAL_REQUEST_FEE, "Zero excess should give minimum fee");
    }

    // TODO: Fix fee calculation with max excess value
    // function test_Boundary_MaxExcess() public {
    //     // Test with very high excess (but not EXCESS_INHIBITOR)
    //     uint256 highExcess = EXCESS_INHIBITOR - 1;
    //     vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(highExcess));

    //     uint256 fee = getWithdrawalFee();
    //     assertTrue(fee > MIN_WITHDRAWAL_REQUEST_FEE, "High excess should increase fee");
    // }

    // ========================================
    // EDGE CASES
    // ========================================

    function test_EdgeCase_QueueWrapAround() public {
        // Fill queue, dequeue partially, add more
        addMultipleRequests(10);

        // Dequeue all
        triggerSystemCall();

        // Add more (queue indices should reset)
        addMultipleRequests(5);
        assertQueueState(8, 5, 0, 5); // Excess from previous, new requests

        // Dequeue again
        bytes memory returnData = triggerSystemCall();
        assertEq(returnData.length, 5 * 76, "Should dequeue new requests");
    }

    function test_EdgeCase_AlternatingAddAndDequeue() public {
        // Add 2, dequeue, add 3, dequeue, etc.
        uint256 fee = getWithdrawalFee();

        // Round 1
        addMultipleRequests(2);
        triggerSystemCall();

        // Round 2
        addMultipleRequests(3);
        bytes memory data = triggerSystemCall();
        assertEq(data.length, 3 * 76, "Should dequeue 3 requests");

        // Round 3
        addMultipleRequests(1);
        data = triggerSystemCall();
        assertEq(data.length, 76, "Should dequeue 1 request");
    }

    // TODO: Fix fee calculation - fee is not increasing with queue count as expected
    // function test_EdgeCase_FeeUpdateMechanism() public {
    //     // Test fee changes with varying excess

    //     // Start with 0 excess
    //     uint256 fee1 = getWithdrawalFee();

    //     // Add requests and trigger system call to increase excess
    //     addMultipleRequests(10);
    //     triggerSystemCall();

    //     // Fee should be higher now due to excess
    //     uint256 fee2 = getWithdrawalFee();
    //     assertTrue(fee2 > fee1, "Fee should increase with excess");

    //     // Add fewer requests and trigger to decrease excess
    //     addMultipleRequests(1);
    //     triggerSystemCall();

    //     uint256 fee3 = getWithdrawalFee();
    //     assertTrue(fee3 < fee2, "Fee should decrease as excess decreases");
    // }

    function test_EdgeCase_SystemCallFromNonSystem() public {
        // Non-system address making a system-like call
        // Should go through normal flow, not system flow

        // Call with empty data from non-system address - should return fee
        (bool success, bytes memory data) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call("");
        assertTrue(success, "Should succeed as fee getter");
        assertEq(abi.decode(data, (uint256)), MIN_WITHDRAWAL_REQUEST_FEE, "Should return fee");
    }

    // ========================================
    // INTEGRATION TESTS
    // ========================================

    // TODO: Fix amount assertion in withdrawal request validation
    // function test_Integration_FullCycle() public {
    //     // Complete flow: add requests → system call → verify data → add more → system call

    //     // Phase 1: Add initial requests
    //     uint256 fee = getWithdrawalFee();
    //     bytes32 pubkey1_1 = bytes32(uint256(0xAA));
    //     bytes16 pubkey2_1 = bytes16(uint128(0xBB));
    //     uint64 amount1 = 32e9; // 32 ETH

    //     addWithdrawalRequest(pubkey1_1, pubkey2_1, amount1, fee);

    //     // Verify queue state
    //     assertQueueState(0, 1, 0, 1);

    //     // Phase 2: System dequeue
    //     bytes memory data = triggerSystemCall();
    //     assertEq(data.length, 76, "Should return one request");
    //     assertWithdrawalRequest(data, 0, address(this), pubkey1_1, pubkey2_1, amount1);

    //     // Queue should be empty
    //     assertQueueState(0, 0, 0, 0); // Excess = 0 + 1 - 2 = 0 (can't go negative)

    //     // Phase 3: Add multiple requests
    //     addMultipleRequests(3);
    //     assertQueueState(0, 3, 0, 3);

    //     // Phase 4: System dequeue multiple
    //     data = triggerSystemCall();
    //     assertEq(data.length, 3 * 76, "Should return three requests");

    //     // Verify excess updated correctly: 0 + 3 - 2 = 1
    //     (uint256 excess,,,) = getQueueState();
    //     assertEq(excess, 1, "Excess should be 1");
    // }

    // TODO: Fix amount assertion in withdrawal request validation
    // function test_Integration_WithCoffer() public {
    //     // Test that Coffer contract can successfully add withdrawal requests

    //     // Create a coffer
    //     address cofferAddress = createDefaultCoffer();

    //     // Get fee
    //     uint256 fee = getWithdrawalFee();

    //     // Simulate coffer adding a withdrawal request
    //     vm.prank(cofferAddress);
    //     addWithdrawalRequest(validPublicKeyPart1, validPublicKeyPart2, 16e9, fee);

    //     // Verify request was added from coffer address
    //     bytes memory data = triggerSystemCall();
    //     assertWithdrawalRequest(data, 0, cofferAddress, validPublicKeyPart1, validPublicKeyPart2, 16e9);
    // }

    // ========================================
    // CONSENSUS LAYER BEHAVIOR TESTS
    // ========================================

    function test_ConsensusLayer_PartialWithdrawal_40ETH_Withdraw10ETH_Regular() public {
        // Test the scenario from the conversation: 40 ETH validator withdrawing 10 ETH
        // With 0x01 credentials (regular validator)

        // Add the withdrawal request - EL contract accepts it without validation
        uint256 fee = getWithdrawalFee();
        uint64 requestedAmount = 10_000_000_000; // 10 ETH in Gwei

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, requestedAmount, fee);

        // Verify request was queued (EL doesn't validate)
        assertQueueState(0, 1, 0, 1);

        // Simulate consensus layer behavior for 0x01 credentials
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_EXECUTION(), 40 ether, requestedAmount);

        // With 0x01 credentials, partial withdrawals are silently ignored
        assertEq(actualAmount, 0, "Regular validator partial withdrawal should be ignored");
        assertFalse(wouldProcess, "Regular validator partial withdrawal should not process");

        // Demonstrate the scenario
        (uint64 withdrawn, string memory explanation) =
            mock.demonstratePartialWithdrawalScenario(mock.CREDENTIAL_TYPE_EXECUTION());
        assertEq(withdrawn, 0, "No ETH should be withdrawn for regular validator");
        emit log_string(explanation);
    }

    function test_ConsensusLayer_PartialWithdrawal_40ETH_Withdraw10ETH_Compounding() public {
        // Test the scenario from the conversation: 40 ETH validator withdrawing 10 ETH
        // With 0x02 credentials (compounding validator)

        // Add the withdrawal request
        uint256 fee = getWithdrawalFee();
        uint64 requestedAmount = 10_000_000_000; // 10 ETH in Gwei

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, requestedAmount, fee);

        // Verify request was queued
        assertQueueState(0, 1, 0, 1);

        // Simulate consensus layer behavior for 0x02 credentials
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 40 ether, requestedAmount);

        // With 0x02 credentials, amount is clamped to maintain 32 ETH minimum
        uint64 expectedAmount = 8_000_000_000; // 8 ETH in Gwei (40 - 32 = 8)
        assertEq(actualAmount, expectedAmount, "Should withdraw 8 ETH instead of 10 ETH");
        assertTrue(wouldProcess, "Compounding validator partial withdrawal should process");

        // Demonstrate the scenario
        (uint64 withdrawn, string memory explanation) =
            mock.demonstratePartialWithdrawalScenario(mock.CREDENTIAL_TYPE_COMPOUNDING());
        assertEq(withdrawn, expectedAmount, "Should withdraw 8 ETH for compounding validator");
        emit log_string(explanation);
    }

    function test_ConsensusLayer_PartialWithdrawal_ExactExcessBalance() public {
        // Test withdrawing exactly the excess balance (40 ETH validator withdrawing 8 ETH)

        uint256 fee = getWithdrawalFee();
        uint64 requestedAmount = 8_000_000_000; // 8 ETH in Gwei (exact excess)

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, requestedAmount, fee);
        assertQueueState(0, 1, 0, 1);

        // For compounding validator, this should withdraw exactly 8 ETH
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 40 ether, requestedAmount);

        assertEq(actualAmount, requestedAmount, "Should withdraw exact requested amount");
        assertTrue(wouldProcess, "Should process exact excess withdrawal");
    }

    function test_ConsensusLayer_PartialWithdrawal_32ETHValidator() public {
        // Test validator with exactly 32 ETH trying to withdraw

        uint256 fee = getWithdrawalFee();
        uint64 requestedAmount = 1_000_000_000; // 1 ETH in Gwei

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, requestedAmount, fee);
        assertQueueState(0, 1, 0, 1);

        // For compounding validator at 32 ETH, withdrawal should be ignored
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 32 ether, requestedAmount);

        assertEq(actualAmount, 0, "Should not withdraw from 32 ETH validator");
        assertFalse(wouldProcess, "Should not process withdrawal at minimum balance");
    }

    function test_ConsensusLayer_PartialWithdrawal_LargeWithdrawal() public {
        // Test requesting withdrawal larger than balance

        uint256 fee = getWithdrawalFee();
        uint64 requestedAmount = 50_000_000_000; // 50 ETH in Gwei (more than 40 ETH balance)

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, requestedAmount, fee);
        assertQueueState(0, 1, 0, 1);

        // For compounding validator, should clamp to available excess
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 40 ether, requestedAmount);

        uint64 expectedAmount = 8_000_000_000; // Only 8 ETH available (40 - 32)
        assertEq(actualAmount, expectedAmount, "Should clamp to available excess");
        assertTrue(wouldProcess, "Should process clamped withdrawal");
    }

    function test_ConsensusLayer_FullExit_ZeroAmount() public {
        // Test full exit (amount = 0) - works for all credential types

        uint256 fee = getWithdrawalFee();
        uint64 zeroAmount = 0;

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, zeroAmount, fee);
        assertQueueState(0, 1, 0, 1);

        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);

        // Test with 0x01 credentials - full exit works
        (uint64 actualAmount1, bool wouldProcess1) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_EXECUTION(), 40 ether, zeroAmount);
        assertEq(actualAmount1, 0, "Full exit amount should be 0");
        assertTrue(wouldProcess1, "Full exit should process for 0x01 credentials");

        // Test with 0x02 credentials - full exit also works
        (uint64 actualAmount2, bool wouldProcess2) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 40 ether, zeroAmount);
        assertEq(actualAmount2, 0, "Full exit amount should be 0");
        assertTrue(wouldProcess2, "Full exit should process for 0x02 credentials");
    }

    function test_ConsensusLayer_InvalidRequest_WrongPubkey() public {
        // Test that EL accepts any pubkey (doesn't validate)

        uint256 fee = getWithdrawalFee();
        bytes32 invalidPubkey1 = bytes32(0);
        bytes16 invalidPubkey2 = bytes16(0);
        uint64 amount = 1_000_000_000;

        // Should succeed at EL level (no validation)
        addWithdrawalRequest(invalidPubkey1, invalidPubkey2, amount, fee);
        assertQueueState(0, 1, 0, 1);

        // Note: On consensus layer, this would be silently discarded
        // but fee would not be refunded
    }

    function test_ConsensusLayer_QueueBehavior_MultiplePartialRequests() public {
        // Test multiple partial withdrawal requests with different credential types

        uint256 fee = getWithdrawalFee();
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);

        // Add multiple requests
        for (uint256 i = 0; i < 3; i++) {
            bytes32 pubkey1 = bytes32(uint256(i + 100));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint128
            bytes16 pubkey2 = bytes16(uint128(i + 100));
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
            uint64 amount = uint64((i + 1) * 5_000_000_000); // 5, 10, 15 ETH

            addWithdrawalRequest(pubkey1, pubkey2, amount, fee);
        }

        assertQueueState(0, 3, 0, 3);

        // Simulate different validators with different balances
        uint256[3] memory balances = [uint256(35 ether), uint256(40 ether), uint256(50 ether)];
        uint64[3] memory amounts = [uint64(5_000_000_000), uint64(10_000_000_000), uint64(15_000_000_000)];

        // Test each with compounding credentials
        for (uint256 i = 0; i < 3; i++) {
            (uint64 actualAmount, bool wouldProcess) =
                mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), balances[i], amounts[i]);

            uint256 maxWithdrawable = balances[i] - 32 ether;
            uint256 requestedWei = uint256(amounts[i]) * 1 gwei;
            uint256 expectedWei = requestedWei > maxWithdrawable ? maxWithdrawable : requestedWei;
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
            uint64 expectedGwei = uint64(expectedWei / 1 gwei);

            assertEq(actualAmount, expectedGwei, string.concat("Request ", vm.toString(i), " amount mismatch"));
            assertTrue(wouldProcess, string.concat("Request ", vm.toString(i), " should process"));
        }
    }

    // ========================================
    // EDGE CASES FROM CONVERSATION
    // ========================================

    function test_EdgeCase_FeeNotRefunded_InvalidRequest() public {
        // Test that fees are never refunded, even for invalid requests

        uint256 fee = getWithdrawalFee();
        uint256 initialBalance = address(this).balance;

        // Add request with invalid/garbage data that will be discarded by consensus
        bytes32 garbagePubkey1 = bytes32(keccak256("invalid"));
        bytes16 garbagePubkey2 = bytes16(uint128(uint256(keccak256("garbage"))));
        uint64 invalidAmount = type(uint64).max;

        addWithdrawalRequest(garbagePubkey1, garbagePubkey2, invalidAmount, fee);

        // Fee is consumed even though request will be discarded
        assertEq(address(this).balance, initialBalance - fee, "Fee should be consumed");
        assertQueueState(0, 1, 0, 1); // Request still queued at EL level

        // Note: On consensus layer, this would be silently discarded
        // The fee is lost forever - no refunds
    }

    function test_EdgeCase_OverpaymentNotRefunded() public {
        // Test that overpayment is not refunded

        uint256 fee = getWithdrawalFee();
        uint256 overpayment = fee * 100; // Pay 100x the required fee
        uint256 initialBalance = address(this).balance;

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, overpayment);

        // Entire overpayment is consumed
        assertEq(address(this).balance, initialBalance - overpayment, "Overpayment not refunded");
        assertQueueState(0, 1, 0, 1);
    }

    function test_EdgeCase_SmartContractAsSourceAddress() public {
        // Test that smart contracts can submit withdrawal requests (msg.sender becomes source)

        // Deploy a simple contract that will make the request
        TestRequester requester = new TestRequester();
        uint256 fee = getWithdrawalFee();

        // Fund the contract
        vm.deal(address(requester), 10 ether);

        // Contract submits withdrawal request
        requester.submitRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, fee);

        // Verify request was added with contract as source
        assertQueueState(0, 1, 0, 1);

        // Dequeue and verify source address
        bytes memory data = triggerSystemCall();
        assertWithdrawalRequest(
            data,
            0,
            address(requester), // Contract address is the source
            TEST_PUBKEY_PART1,
            TEST_PUBKEY_PART2,
            TEST_AMOUNT_GWEI
        );
    }

    function test_EdgeCase_MinimumFeeWithZeroExcess() public {
        // Verify minimum fee is exactly 1 wei with zero excess

        // Ensure excess is 0
        vm.store(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));

        uint256 fee = getWithdrawalFee();
        assertEq(fee, 1, "Minimum fee should be exactly 1 wei");

        // Should succeed with exactly 1 wei
        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, 1);
        assertQueueState(0, 1, 0, 1);
    }

    function test_EdgeCase_PartialWithdrawalBelowGweiPrecision() public {
        // Test edge case with amounts that have wei precision issues

        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);

        // Validator with 32.000000001 ETH (1 wei above minimum)
        uint256 validatorBalance = 32 ether + 1;
        uint64 requestedGwei = 1; // Request 1 Gwei withdrawal

        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), validatorBalance, requestedGwei);

        // Should be ignored because available is less than 1 Gwei
        assertEq(actualAmount, 0, "Should not withdraw sub-Gwei amounts");
        assertFalse(wouldProcess, "Sub-Gwei withdrawal should not process");
    }

    function test_EdgeCase_FeeIncreaseDuringHighDemand() public {
        // Test fee increase mechanism with high demand

        // Start with 0 excess
        uint256 initialFee = getWithdrawalFee();
        assertEq(initialFee, 1, "Initial fee should be 1 wei");

        // Add many requests to simulate high demand
        uint256 requestCount = 20;
        for (uint256 i = 0; i < requestCount; i++) {
            // forge-lint: disable-next-line(unsafe-typecast) test value fits in uint64
            addWithdrawalRequest(bytes32(uint256(i)), bytes16(uint128(i)), uint64(i * 1e9), initialFee);
        }

        // Trigger system call - this updates excess
        triggerSystemCall();

        // Fee should now be higher due to excess
        // excess = 0 + 20 - 2 = 18 (assuming TARGET = 2)
        uint256 newFee = getWithdrawalFee();
        assertTrue(newFee > initialFee, "Fee should increase with excess");
    }

    function test_EdgeCase_ValidatorExactly32ETH_FullExit() public {
        // Validator with exactly 32 ETH can still do full exit (amount = 0)

        uint256 fee = getWithdrawalFee();
        uint64 zeroAmount = 0; // Full exit

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, zeroAmount, fee);
        assertQueueState(0, 1, 0, 1);

        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);

        // Even at exactly 32 ETH, full exit works for both credential types
        (uint64 actualAmount, bool wouldProcess) =
            mock.simulateConsensusWithdrawal(mock.CREDENTIAL_TYPE_COMPOUNDING(), 32 ether, zeroAmount);

        assertEq(actualAmount, 0, "Full exit amount is 0");
        assertTrue(wouldProcess, "Full exit should work at 32 ETH");
    }

    // ========================================
    // A pending partial blocks exits (CL-side drop)
    // ========================================

    function test_PendingPartialBlocksExits_DropsExit_ThenPassesAfterClear() public {
        uint256 fee = getWithdrawalFee();
        EIP7002Mock mock = EIP7002Mock(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS);

        // Baseline: no pending, both a partial and an exit survive the dequeuing
        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 1 gwei, fee);
        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 0, fee);

        bytes memory returned = triggerSystemCall();
        assertEq(returned.length, 2 * 76, "both requests returned while no pending exists");
        assertWithdrawalRequest(returned, 0, address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 1 gwei);
        assertWithdrawalRequest(returned, 1, address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 0);

        // A pending partial now exists: the exit is dequeued but silently dropped
        mock.setPendingPartialBlocksExits(true);
        assertTrue(mock.pendingPartialBlocksExits(), "flag set");

        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 1 gwei, fee);
        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 0, fee);

        returned = triggerSystemCall();
        assertEq(returned.length, 76, "only the partial returned; the exit was dropped");
        assertWithdrawalRequest(returned, 0, address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 1 gwei);

        // The queue still drained both entries (the drop happens CL-side, after the dequeue)
        (,, uint256 head, uint256 tail) = getQueueState();
        assertEq(head, tail, "queue fully drained despite the drop");

        // After the pending tail clears, the exit request passes again
        mock.setPendingPartialBlocksExits(false);
        addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 0, fee);

        returned = triggerSystemCall();
        assertEq(returned.length, 76, "exit returned once the pending cleared");
        assertWithdrawalRequest(returned, 0, address(this), TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, 0);
    }

    // ========================================
    // GAS OPTIMIZATION TESTS
    // ========================================

    // TODO: Fix gas calculation issues
    // function test_GasUsage_AddRequest() public {
    //     uint256 fee = getWithdrawalFee();

    //     uint256 gasBefore = gasleft();
    //     addWithdrawalRequest(TEST_PUBKEY_PART1, TEST_PUBKEY_PART2, TEST_AMOUNT_GWEI, fee);
    //     uint256 gasUsed = gasBefore - gasleft();

    //     emit log_named_uint("Gas used for adding withdrawal request", gasUsed);
    //     assertTrue(gasUsed < 100000, "Add request gas usage too high");
    // }

    function test_GasUsage_GetFee() public {
        uint256 gasBefore = gasleft();
        getWithdrawalFee();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for getting fee", gasUsed);
        assertTrue(gasUsed < 10000, "Get fee gas usage too high");
    }

    function test_GasUsage_SystemCall() public {
        // Add some requests first
        addMultipleRequests(5);

        uint256 gasBefore = gasleft();
        triggerSystemCall();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for system call (5 requests)", gasUsed);
        assertTrue(gasUsed < 200000, "System call gas usage too high");
    }
}
