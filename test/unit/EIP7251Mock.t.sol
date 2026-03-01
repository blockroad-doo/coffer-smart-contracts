//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseTest} from "./BaseTest.sol";
import {
    EIP7251Mock,
    CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS,
    CONSOLIDATION_EXCESS_INHIBITOR,
    MAX_CONSOLIDATION_REQUESTS_PER_BLOCK,
    MIN_CONSOLIDATION_REQUEST_FEE,
    CONSOLIDATION_QUEUE_ENTRY_SIZE
} from "../mock/EIP7251Mock.sol";
import {SYSTEM_ADDRESS} from "../mock/EIP7002Mock.sol";

/**
 * @title EIP7251MockTest
 * @notice Comprehensive unit tests for EIP7251Mock following the same structure as EIP7002MockTest
 * @dev Tests follow logical progression: happy cases → revert conditions → boundary conditions → edge cases
 */
// Helper contract for testing smart contract as source
contract ConsolidationRequester {
    function submitRequest(bytes memory sourcePubkey, bytes memory targetPubkey, uint256 fee) external {
        bytes memory data = abi.encodePacked(sourcePubkey, targetPubkey);
        (bool success,) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        require(success, "Request failed");
    }
}

contract EIP7251MockTest is BaseTest {
    // ========================================
    // TEST CONSTANTS
    // ========================================

    // Test consolidation request data (two 48-byte pubkeys)
    bytes constant TEST_SOURCE_PUBKEY =
        hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    bytes constant TEST_TARGET_PUBKEY =
        hex"abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";

    // ========================================
    // SETUP
    // ========================================

    function setUp() public override {
        super.setUp();
    }

    // ========================================
    // HELPER FUNCTIONS (DRY)
    // ========================================

    /**
     * @dev Helper to add a consolidation request (96-byte calldata: two 48-byte pubkeys)
     */
    function addConsolidationRequest(bytes memory sourcePubkey, bytes memory targetPubkey, uint256 fee) internal {
        bytes memory data = abi.encodePacked(sourcePubkey, targetPubkey);
        (bool success,) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        require(success, "Failed to add consolidation request");
    }

    /**
     * @dev Helper to trigger system call for consolidation dequeue
     */
    function triggerConsolidationSystemCall() internal returns (bytes memory) {
        vm.prank(SYSTEM_ADDRESS);
        (bool success, bytes memory data) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call("");
        require(success, "Consolidation system call failed");
        return data;
    }

    /**
     * @dev Helper to get consolidation queue state
     */
    function getConsolidationQueueState()
        internal
        view
        returns (uint256 excess, uint256 count, uint256 queueHead, uint256 queueTail)
    {
        excess = EIP7251Mock(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS).getExcess();
        count = EIP7251Mock(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS).getCount();
        queueHead = EIP7251Mock(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS).getQueueHead();
        queueTail = EIP7251Mock(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS).getQueueTail();
    }

    /**
     * @dev Helper to verify queue state
     */
    function assertConsolidationQueueState(
        uint256 expectedExcess,
        uint256 expectedCount,
        uint256 expectedHead,
        uint256 expectedTail
    ) internal {
        (uint256 excess, uint256 count, uint256 head, uint256 tail) = getConsolidationQueueState();
        assertEq(excess, expectedExcess, "Excess mismatch");
        assertEq(count, expectedCount, "Count mismatch");
        assertEq(head, expectedHead, "Queue head mismatch");
        assertEq(tail, expectedTail, "Queue tail mismatch");
    }

    /**
     * @dev Helper to generate a unique 48-byte pubkey from an index
     */
    function makePubkey(uint256 index) internal pure returns (bytes memory) {
        bytes memory pubkey = new bytes(48);
        bytes32 hash = keccak256(abi.encodePacked(index));
        assembly {
            mstore(add(pubkey, 32), hash)
        }
        // Fill remaining 16 bytes
        bytes32 hash2 = keccak256(abi.encodePacked(index, uint256(1)));
        assembly {
            // Write 16 bytes at offset 32+32=64 in memory (pubkey data starts at 32)
            let ptr := add(pubkey, 64)
            mstore8(ptr, byte(0, hash2))
            mstore8(add(ptr, 1), byte(1, hash2))
            mstore8(add(ptr, 2), byte(2, hash2))
            mstore8(add(ptr, 3), byte(3, hash2))
            mstore8(add(ptr, 4), byte(4, hash2))
            mstore8(add(ptr, 5), byte(5, hash2))
            mstore8(add(ptr, 6), byte(6, hash2))
            mstore8(add(ptr, 7), byte(7, hash2))
            mstore8(add(ptr, 8), byte(8, hash2))
            mstore8(add(ptr, 9), byte(9, hash2))
            mstore8(add(ptr, 10), byte(10, hash2))
            mstore8(add(ptr, 11), byte(11, hash2))
            mstore8(add(ptr, 12), byte(12, hash2))
            mstore8(add(ptr, 13), byte(13, hash2))
            mstore8(add(ptr, 14), byte(14, hash2))
            mstore8(add(ptr, 15), byte(15, hash2))
        }
        return pubkey;
    }

    /**
     * @dev Helper to add multiple consolidation requests
     */
    function addMultipleConsolidationRequests(uint256 count) internal {
        uint256 fee = getConsolidationFee();
        for (uint256 i = 0; i < count; i++) {
            bytes memory srcPubkey = makePubkey(i * 2);
            bytes memory tgtPubkey = makePubkey(i * 2 + 1);
            addConsolidationRequest(srcPubkey, tgtPubkey, fee);
        }
    }

    /**
     * @dev Assert consolidation request data matches expected values
     *      Return entry is 116 bytes: source_address(20) + source_pubkey(48) + target_pubkey(48)
     */
    function assertConsolidationRequest(
        bytes memory returnData,
        uint256 index,
        address expectedSource,
        bytes memory expectedSrcPubkey,
        bytes memory expectedTgtPubkey
    ) internal pure {
        uint256 offset = index * CONSOLIDATION_QUEUE_ENTRY_SIZE;

        // Extract source address (20 bytes)
        address source;
        assembly {
            source := shr(96, mload(add(add(returnData, 0x20), offset)))
        }

        // Extract source pubkey (48 bytes at offset+20)
        bytes memory srcPubkey = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            srcPubkey[i] = returnData[offset + 20 + i];
        }

        // Extract target pubkey (48 bytes at offset+68)
        bytes memory tgtPubkey = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            tgtPubkey[i] = returnData[offset + 68 + i];
        }

        assert(source == expectedSource);
        assert(keccak256(srcPubkey) == keccak256(expectedSrcPubkey));
        assert(keccak256(tgtPubkey) == keccak256(expectedTgtPubkey));
    }

    // ========================================
    // HAPPY CASES - FEE GETTER
    // ========================================

    function test_GetFee_Success_InitialState() public {
        uint256 fee = getConsolidationFee();
        assertEq(fee, MIN_CONSOLIDATION_REQUEST_FEE, "Initial fee should be minimum");
    }

    function test_GetFee_Success_WithExcess() public {
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(100)));

        uint256 fee = getConsolidationFee();
        assertTrue(fee > MIN_CONSOLIDATION_REQUEST_FEE, "Fee should increase with excess");
    }

    function test_GetFee_Success_ViaReceive() public {
        (bool success, bytes memory data) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call("");

        assertTrue(success, "Fee getter via receive should succeed");
        uint256 fee = abi.decode(data, (uint256));
        assertEq(fee, MIN_CONSOLIDATION_REQUEST_FEE, "Fee via receive should match");
    }

    // ========================================
    // HAPPY CASES - ADD CONSOLIDATION REQUEST
    // ========================================

    function test_AddRequest_Success_Single() public {
        uint256 fee = getConsolidationFee();

        addConsolidationRequest(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY, fee);

        assertConsolidationQueueState(0, 1, 0, 1);
    }

    function test_AddRequest_Success_Multiple() public {
        uint256 fee = getConsolidationFee();
        uint256 requestCount = 5;

        for (uint256 i = 0; i < requestCount; i++) {
            bytes memory srcPubkey = makePubkey(i * 2);
            bytes memory tgtPubkey = makePubkey(i * 2 + 1);
            addConsolidationRequest(srcPubkey, tgtPubkey, fee);
        }

        assertConsolidationQueueState(0, requestCount, 0, requestCount);
    }

    function test_AddRequest_Success_WithExcessFee() public {
        uint256 fee = getConsolidationFee();
        uint256 excessFee = fee * 2;

        addConsolidationRequest(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY, excessFee);

        assertConsolidationQueueState(0, 1, 0, 1);
    }

    // ========================================
    // HAPPY CASES - SYSTEM CALL
    // ========================================

    function test_SystemCall_Success_DequeueRequests() public {
        // Add 2 requests (MAX_CONSOLIDATION_REQUESTS_PER_BLOCK = 2)
        uint256 fee = getConsolidationFee();
        bytes memory src1 = makePubkey(0);
        bytes memory tgt1 = makePubkey(1);
        bytes memory src2 = makePubkey(2);
        bytes memory tgt2 = makePubkey(3);

        addConsolidationRequest(src1, tgt1, fee);
        addConsolidationRequest(src2, tgt2, fee);

        bytes memory returnData = triggerConsolidationSystemCall();

        // Both should be dequeued
        assertEq(returnData.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should return 2 requests");
        // Excess = 0 + 2 - TARGET(1) = 1, count reset, queue reset
        assertConsolidationQueueState(1, 0, 0, 0);

        // Verify returned data
        assertConsolidationRequest(returnData, 0, address(this), src1, tgt1);
        assertConsolidationRequest(returnData, 1, address(this), src2, tgt2);
    }

    function test_SystemCall_Success_EmptyQueue() public {
        bytes memory returnData = triggerConsolidationSystemCall();

        assertEq(returnData.length, 0, "Empty queue should return no data");
        assertConsolidationQueueState(0, 0, 0, 0);
    }

    function test_SystemCall_Success_ResetQueueWhenEmpty() public {
        // Add 2 requests and system call to empty it
        addMultipleConsolidationRequests(2);
        triggerConsolidationSystemCall();

        // Queue should be reset (head = 0, tail = 0)
        // Excess = 0 + 2 - 1 = 1
        assertConsolidationQueueState(1, 0, 0, 0);

        // Add new requests should start from index 0
        addMultipleConsolidationRequests(1);
        assertConsolidationQueueState(1, 1, 0, 1);
    }

    function test_SystemCall_Success_UpdateExcess() public {
        // Set initial excess and add requests
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(10)));
        addMultipleConsolidationRequests(3);

        triggerConsolidationSystemCall();

        // Excess should be: previousExcess(10) + count(3) - TARGET(1) = 12
        (uint256 excess,,,) = getConsolidationQueueState();
        assertEq(excess, 12, "Excess calculation incorrect");
    }

    function test_SystemCall_Success_MaxDequeueCapped() public {
        // Add 5 requests, only MAX(2) should be dequeued
        addMultipleConsolidationRequests(5);

        bytes memory returnData = triggerConsolidationSystemCall();

        assertEq(
            returnData.length,
            MAX_CONSOLIDATION_REQUESTS_PER_BLOCK * CONSOLIDATION_QUEUE_ENTRY_SIZE,
            "Should return max requests"
        );
        // Excess = 0 + 5 - 1 = 4, head = 2, tail = 5 (not empty, so no reset)
        assertConsolidationQueueState(4, 0, 2, 5);
    }

    // ========================================
    // REVERT CONDITIONS
    // ========================================

    function test_Revert_Condition1_ExcessInhibitor() public {
        vm.store(
            CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(CONSOLIDATION_EXCESS_INHIBITOR)
        );

        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call("");
    }

    function test_Revert_Condition2_InvalidCalldata() public {
        // Calldata not 0 or 96 bytes (and not system address)
        bytes memory invalidData = "invalid";

        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call(invalidData);

        // Try with 95 bytes (one byte short)
        bytes memory shortData = new bytes(95);
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call(shortData);

        // Try with 97 bytes (one byte too many)
        bytes memory longData = new bytes(97);
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call(longData);
    }

    function test_Revert_Condition3_FeeGetterWithValue() public {
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: 1}("");

        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: 1 ether}("");
    }

    function test_Revert_Condition4_InsufficientFee() public {
        uint256 fee = getConsolidationFee();
        bytes memory data = abi.encodePacked(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY);

        // Send less than required fee
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: fee - 1}(data);

        // Send 0 fee
        vm.expectRevert();
        // forge-lint: disable-next-line(unchecked-call)
        CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call{value: 0}(data);
    }

    // ========================================
    // BOUNDARY CONDITIONS
    // ========================================

    function test_Boundary_MaxQueueDequeue() public {
        // Add exactly MAX_CONSOLIDATION_REQUESTS_PER_BLOCK (2)
        addMultipleConsolidationRequests(MAX_CONSOLIDATION_REQUESTS_PER_BLOCK);

        bytes memory returnData = triggerConsolidationSystemCall();
        assertEq(
            returnData.length,
            MAX_CONSOLIDATION_REQUESTS_PER_BLOCK * CONSOLIDATION_QUEUE_ENTRY_SIZE,
            "Should dequeue all max requests"
        );
    }

    function test_Boundary_MoreThanMaxInQueue() public {
        // Add 4 requests (more than MAX=2), partial dequeue
        addMultipleConsolidationRequests(4);

        bytes memory returnData = triggerConsolidationSystemCall();
        assertEq(returnData.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should only dequeue max 2");

        // 2 remain in queue
        (,, uint256 head, uint256 tail) = getConsolidationQueueState();
        assertEq(tail - head, 2, "Should have 2 remaining in queue");
    }

    function test_Boundary_ZeroExcessFee() public {
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));

        uint256 fee = getConsolidationFee();
        assertEq(fee, MIN_CONSOLIDATION_REQUEST_FEE, "Zero excess should give minimum fee");
    }

    // ========================================
    // EDGE CASES
    // ========================================

    function test_EdgeCase_QueueWrapAround() public {
        // Fill queue, dequeue all, add more
        addMultipleConsolidationRequests(2);

        // Dequeue all
        triggerConsolidationSystemCall();

        // Add more (queue indices should reset since fully drained)
        addMultipleConsolidationRequests(2);
        // Excess from previous = 1, new count = 2
        assertConsolidationQueueState(1, 2, 0, 2);

        // Dequeue again
        bytes memory returnData = triggerConsolidationSystemCall();
        assertEq(returnData.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should dequeue new requests");
    }

    function test_EdgeCase_AlternatingAddAndDequeue() public {
        // Round 1: add 1, dequeue
        addMultipleConsolidationRequests(1);
        triggerConsolidationSystemCall();

        // Round 2: add 2, dequeue
        addMultipleConsolidationRequests(2);
        bytes memory data = triggerConsolidationSystemCall();
        assertEq(data.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should dequeue 2 requests");

        // Round 3: add 1, dequeue
        addMultipleConsolidationRequests(1);
        data = triggerConsolidationSystemCall();
        assertEq(data.length, CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should dequeue 1 request");
    }

    function test_EdgeCase_FeeIncreaseUnderDemand() public {
        // Start with 0 excess
        uint256 initialFee = getConsolidationFee();
        assertEq(initialFee, 1, "Initial fee should be 1 wei");

        // Add many requests to simulate high demand
        // Need enough to push excess above 17 (the fee update fraction)
        // so that fake_exponential returns > 1 with integer division
        uint256 requestCount = 20;
        for (uint256 i = 0; i < requestCount; i++) {
            addConsolidationRequest(makePubkey(i * 2), makePubkey(i * 2 + 1), initialFee);
        }

        // Trigger system call - this updates excess
        triggerConsolidationSystemCall();

        // Fee should now be higher due to excess
        // excess = 0 + 20 - TARGET(1) = 19
        uint256 newFee = getConsolidationFee();
        assertTrue(newFee > initialFee, "Fee should increase with excess");
    }

    function test_EdgeCase_OverpaymentNotRefunded() public {
        uint256 fee = getConsolidationFee();
        uint256 overpayment = fee * 100;
        uint256 initialBalance = address(this).balance;

        addConsolidationRequest(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY, overpayment);

        assertEq(address(this).balance, initialBalance - overpayment, "Overpayment not refunded");
        assertConsolidationQueueState(0, 1, 0, 1);
    }

    function test_EdgeCase_SmartContractAsSource() public {
        ConsolidationRequester requester = new ConsolidationRequester();
        uint256 fee = getConsolidationFee();

        vm.deal(address(requester), 10 ether);

        requester.submitRequest(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY, fee);

        assertConsolidationQueueState(0, 1, 0, 1);

        // Dequeue and verify source address
        bytes memory data = triggerConsolidationSystemCall();
        assertConsolidationRequest(data, 0, address(requester), TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY);
    }

    function test_EdgeCase_MinimumFeeWithZeroExcess() public {
        vm.store(CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));

        uint256 fee = getConsolidationFee();
        assertEq(fee, 1, "Minimum fee should be exactly 1 wei");

        // Should succeed with exactly 1 wei
        addConsolidationRequest(TEST_SOURCE_PUBKEY, TEST_TARGET_PUBKEY, 1);
        assertConsolidationQueueState(0, 1, 0, 1);
    }

    function test_EdgeCase_SystemCallFromNonSystem() public {
        // Non-system address with empty data should return fee
        (bool success, bytes memory data) = CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS.call("");
        assertTrue(success, "Should succeed as fee getter");
        assertEq(abi.decode(data, (uint256)), MIN_CONSOLIDATION_REQUEST_FEE, "Should return fee");
    }

    function test_EdgeCase_PartialDequeuePreservesRemaining() public {
        // Add 4 requests; dequeue 2 (max); verify remaining 2 are still there
        bytes memory src1 = makePubkey(10);
        bytes memory tgt1 = makePubkey(11);
        bytes memory src2 = makePubkey(12);
        bytes memory tgt2 = makePubkey(13);
        bytes memory src3 = makePubkey(14);
        bytes memory tgt3 = makePubkey(15);
        bytes memory src4 = makePubkey(16);
        bytes memory tgt4 = makePubkey(17);

        uint256 fee = getConsolidationFee();
        addConsolidationRequest(src1, tgt1, fee);
        addConsolidationRequest(src2, tgt2, fee);
        addConsolidationRequest(src3, tgt3, fee);
        addConsolidationRequest(src4, tgt4, fee);

        // First system call: dequeue first 2
        bytes memory data1 = triggerConsolidationSystemCall();
        assertEq(data1.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should dequeue 2");
        assertConsolidationRequest(data1, 0, address(this), src1, tgt1);
        assertConsolidationRequest(data1, 1, address(this), src2, tgt2);

        // Second system call: dequeue remaining 2
        bytes memory data2 = triggerConsolidationSystemCall();
        assertEq(data2.length, 2 * CONSOLIDATION_QUEUE_ENTRY_SIZE, "Should dequeue remaining 2");
        assertConsolidationRequest(data2, 0, address(this), src3, tgt3);
        assertConsolidationRequest(data2, 1, address(this), src4, tgt4);
    }
}
