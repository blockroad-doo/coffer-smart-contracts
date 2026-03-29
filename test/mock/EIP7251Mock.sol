// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {SYSTEM_ADDRESS} from "./EIP7002Mock.sol";

// ─── Constants ───────────────────────────────────────────────────────────────

address payable constant CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS = payable(0x0000BBdDc7CE488642fb579F8B00f3a590007251);

// Storage layout
uint256 constant EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT = 0;
uint256 constant CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT = 1;
uint256 constant CONSOLIDATION_REQUEST_QUEUE_HEAD_STORAGE_SLOT = 2;
uint256 constant CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT = 3;
uint256 constant CONSOLIDATION_REQUEST_QUEUE_STORAGE_OFFSET = 4;

// Config
uint256 constant MAX_CONSOLIDATION_REQUESTS_PER_BLOCK = 2;
uint256 constant TARGET_CONSOLIDATION_REQUESTS_PER_BLOCK = 1;
uint256 constant MIN_CONSOLIDATION_REQUEST_FEE = 1;
uint256 constant CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION = 17;
uint256 constant CONSOLIDATION_EXCESS_INHIBITOR = type(uint256).max;

// Each queue entry is 116 bytes (20 + 48 + 48) = 0x74
uint256 constant CONSOLIDATION_QUEUE_ENTRY_SIZE = 116;

// ─── The Mock Contract ───────────────────────────────────────────────────────

/**
 * @title EIP7251Mock
 * @notice A Solidity mock of the EIP-7251 Consolidation Request predeploy contract.
 *         Faithfully replicates all revert conditions and code paths from the bytecode.
 *
 *         Code paths:
 *           1. System call (caller == SYSTEM_ADDRESS) → dequeue up to 2, update excess, reset count, return data
 *           2. Fee getter (calldatasize == 0, msg.value == 0)  → return current fee
 *           3. Add request (calldatasize == 96, msg.value >= fee) → enqueue consolidation request
 *           4. Everything else → REVERT
 *
 *         Each consolidation request contains two 48-byte pubkeys (source + target).
 *         Queue entries use 4 slots:
 *           slot+0: msg.sender (address)
 *           slot+1: calldataload(0)   — source pubkey bytes [0:32]
 *           slot+2: calldataload(32)  — source pubkey bytes [32:48] + target pubkey bytes [0:16]
 *           slot+3: calldataload(64)  — target pubkey bytes [16:48] + zero-padding
 *
 * @dev    Deploy this at the canonical address 0x0000BBdDc7CE488642fb579F8B00f3a590007251
 *         in your test setup using vm.etch().
 */
contract EIP7251Mock {
    // ── Events ──────────────────────────────────────────────────────────────
    event ConsolidationRequestAdded(address indexed sender, bytes sourcePubkey, bytes targetPubkey);

    // ── Fallback: routes all calls exactly like the bytecode ────────────────
    fallback() external payable {
        // Path 1: System call
        if (msg.sender == SYSTEM_ADDRESS) {
            _systemCall();
            //return;
        }

        // Compute fee (reverts if EXCESS_INHIBITOR)
        uint256 fee = _getFee();

        // Path 2: Fee getter (calldatasize == 0)
        if (msg.data.length == 0) {
            require(msg.value == 0);
            assembly {
                mstore(0x00, fee)
                return(0x00, 0x20)
            }
        }

        // Path 3: Add consolidation request (calldatasize == 96)
        if (msg.data.length == 96) {
            require(msg.value >= fee);
            _addConsolidationRequest();
            return;
        }

        // Invalid calldatasize
        revert();
    }

    // Support receive for the fee getter path (calldatasize==0, value==0)
    receive() external payable {
        if (msg.sender == SYSTEM_ADDRESS) {
            _systemCall();
            //return;
        }

        uint256 fee = _getFee();

        require(msg.value == 0);
        assembly {
            mstore(0x00, fee)
            return(0x00, 0x20)
        }
    }

    // ── Fee calculation (fake_exponential) ──────────────────────────────────

    function _getFee() internal view returns (uint256) {
        uint256 excess;
        assembly {
            excess := sload(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT)
        }
        require(excess != CONSOLIDATION_EXCESS_INHIBITOR);

        return _fakeExponential(MIN_CONSOLIDATION_REQUEST_FEE, excess, CONSOLIDATION_REQUEST_FEE_UPDATE_FRACTION);
    }

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

    // ── Add consolidation request ──────────────────────────────────────────

    function _addConsolidationRequest() internal {
        // Increment count
        uint256 count;
        assembly {
            count := sload(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT)
            sstore(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT, add(count, 1))
        }

        // Read queue tail
        uint256 queueTailIndex;
        assembly {
            queueTailIndex := sload(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT)
        }

        // Compute storage slot for this entry (4 slots per entry)
        uint256 queueSlot = CONSOLIDATION_REQUEST_QUEUE_STORAGE_OFFSET + queueTailIndex * 4;

        // Store:
        //   slot+0: msg.sender
        //   slot+1: calldataload(0)   — source pubkey [0:32]
        //   slot+2: calldataload(32)  — source pubkey [32:48] + target pubkey [0:16]
        //   slot+3: calldataload(64)  — target pubkey [16:48] + zero-padding
        assembly {
            sstore(queueSlot, caller())
            sstore(add(queueSlot, 1), calldataload(0))
            sstore(add(queueSlot, 2), calldataload(32))
            sstore(add(queueSlot, 3), calldataload(64))

            // Update tail
            sstore(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT, add(queueTailIndex, 1))
        }

        // Emit event
        bytes memory sourcePubkey = new bytes(48);
        bytes memory targetPubkey = new bytes(48);
        assembly {
            calldatacopy(add(sourcePubkey, 32), 0, 48)
            calldatacopy(add(targetPubkey, 32), 48, 48)
        }
        emit ConsolidationRequestAdded(msg.sender, sourcePubkey, targetPubkey);
    }

    // ── System call: dequeue + update excess + reset count ──────────────────

    function _systemCall() internal {
        // Dequeue
        uint256 queueHeadIndex;
        uint256 queueTailIndex;
        assembly {
            queueHeadIndex := sload(CONSOLIDATION_REQUEST_QUEUE_HEAD_STORAGE_SLOT)
            queueTailIndex := sload(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT)
        }

        uint256 numInQueue = queueTailIndex - queueHeadIndex;
        uint256 numDequeued =
            numInQueue < MAX_CONSOLIDATION_REQUESTS_PER_BLOCK ? numInQueue : MAX_CONSOLIDATION_REQUESTS_PER_BLOCK;

        // Build return data: each entry is 116 bytes
        // Layout per entry: source_address(20) + source_pubkey(48) + target_pubkey(48)
        bytes memory returnData = new bytes(numDequeued * CONSOLIDATION_QUEUE_ENTRY_SIZE);

        for (uint256 i = 0; i < numDequeued; i++) {
            uint256 queueSlot = CONSOLIDATION_REQUEST_QUEUE_STORAGE_OFFSET + (queueHeadIndex + i) * 4;
            uint256 offset = i * CONSOLIDATION_QUEUE_ENTRY_SIZE;

            address sourceAddr;
            bytes32 slot1Val;
            bytes32 slot2Val;
            bytes32 slot3Val;
            assembly {
                sourceAddr := sload(queueSlot)
                slot1Val := sload(add(queueSlot, 1))
                slot2Val := sload(add(queueSlot, 2))
                slot3Val := sload(add(queueSlot, 3))
            }

            // Reconstruct 116 bytes:
            //   [0:20]   source_address
            //   [20:52]  slot1Val  (source pubkey bytes [0:32])
            //   [52:68]  slot2Val high 16 bytes (source pubkey bytes [32:48])
            //   [68:84]  slot2Val low 16 bytes  (target pubkey bytes [0:16])
            //   [84:116] slot3Val first 32 bytes (target pubkey bytes [16:48])
            assembly {
                let ptr := add(add(returnData, 32), offset)
                // source_address: 20 bytes
                mstore(ptr, shl(96, sourceAddr))
                // slot1Val: source pubkey [0:32] at offset+20
                mstore(add(ptr, 20), slot1Val)
                // slot2Val: source pubkey [32:48] + target pubkey [0:16] at offset+52
                mstore(add(ptr, 52), slot2Val)
                // slot3Val: target pubkey [16:48] at offset+84
                mstore(add(ptr, 84), slot3Val)
            }
        }

        // Update queue head
        uint256 newQueueHeadIndex = queueHeadIndex + numDequeued;
        if (newQueueHeadIndex == queueTailIndex) {
            // Queue empty, reset both pointers
            assembly {
                sstore(CONSOLIDATION_REQUEST_QUEUE_HEAD_STORAGE_SLOT, 0)
                sstore(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT, 0)
            }
        } else {
            assembly {
                sstore(CONSOLIDATION_REQUEST_QUEUE_HEAD_STORAGE_SLOT, newQueueHeadIndex)
            }
        }

        // Update excess
        uint256 previousExcess;
        assembly {
            previousExcess := sload(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT)
        }
        if (previousExcess == CONSOLIDATION_EXCESS_INHIBITOR) {
            previousExcess = 0;
        }

        uint256 count;
        assembly {
            count := sload(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT)
        }

        uint256 newExcess = 0;
        if (previousExcess + count > TARGET_CONSOLIDATION_REQUESTS_PER_BLOCK) {
            newExcess = previousExcess + count - TARGET_CONSOLIDATION_REQUESTS_PER_BLOCK;
        }

        assembly {
            sstore(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT, newExcess)
        }

        // Reset count
        assembly {
            sstore(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT, 0)
        }

        // Return dequeued data
        uint256 retSize = numDequeued * CONSOLIDATION_QUEUE_ENTRY_SIZE;
        assembly {
            return(add(returnData, 32), retSize)
        }
    }

    // ── View helpers for tests (not part of the real contract) ───────────────

    function getExcess() external view returns (uint256) {
        uint256 val;
        assembly {
            val := sload(EXCESS_CONSOLIDATION_REQUESTS_STORAGE_SLOT)
        }
        return val;
    }

    function getCount() external view returns (uint256) {
        uint256 val;
        assembly {
            val := sload(CONSOLIDATION_REQUEST_COUNT_STORAGE_SLOT)
        }
        return val;
    }

    function getQueueHead() external view returns (uint256) {
        uint256 val;
        assembly {
            val := sload(CONSOLIDATION_REQUEST_QUEUE_HEAD_STORAGE_SLOT)
        }
        return val;
    }

    function getQueueTail() external view returns (uint256) {
        uint256 val;
        assembly {
            val := sload(CONSOLIDATION_REQUEST_QUEUE_TAIL_STORAGE_SLOT)
        }
        return val;
    }
}
