// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// ─── Constants ───────────────────────────────────────────────────────────────

address constant WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
address constant SYSTEM_ADDRESS = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF; // 0xff...fe but in solidity checksummed

// Storage layout
uint256 constant EXCESS_WITHDRAWAL_REQUESTS_STORAGE_SLOT = 0;
uint256 constant WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT = 1;
uint256 constant WITHDRAWAL_REQUEST_QUEUE_HEAD_STORAGE_SLOT = 2;
uint256 constant WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT = 3;
uint256 constant WITHDRAWAL_REQUEST_QUEUE_STORAGE_OFFSET = 4;

// Config
uint256 constant MAX_WITHDRAWAL_REQUESTS_PER_BLOCK = 16;
uint256 constant TARGET_WITHDRAWAL_REQUESTS_PER_BLOCK = 2;
uint256 constant MIN_WITHDRAWAL_REQUEST_FEE = 1;
uint256 constant WITHDRAWAL_REQUEST_FEE_UPDATE_FRACTION = 17;
uint256 constant EXCESS_INHIBITOR = type(uint256).max;

// Each queue entry is 76 bytes (20 + 48 + 8) = 0x4c
uint256 constant QUEUE_ENTRY_SIZE = 76;

// ─── Struct for dequeued requests ────────────────────────────────────────────

struct WithdrawalRequest {
    address sourceAddress;
    bytes32 validatorPubkeyPart1; // First 32 bytes of pubkey
    bytes16 validatorPubkeyPart2; // Last 16 bytes of pubkey (48 bytes total)
    uint64 amount; // little-endian in storage, but we decode it here
}

// ─── Interface for convenient typed interaction from tests ────────────────────

interface IEIP7002Mock {
    /// Returns current fee. Call with no data and no value.
    function getFee() external view returns (uint256);

    /// Add a withdrawal request. Must send >= fee as msg.value.
    /// @param pubkeyPart1   First 32 bytes of validator public key
    /// @param pubkeyPart2   Last 16 bytes of validator public key
    /// @param amount        Withdrawal amount (in Gwei, big-endian uint64)
    function addWithdrawalRequest(bytes32 pubkeyPart1, bytes16 pubkeyPart2, uint64 amount) external payable;
}

// ─── The Mock Contract ───────────────────────────────────────────────────────

/**
 * @title EIP7002Mock
 * @notice A Solidity mock of the EIP-7002 Withdrawal Request predeploy contract.
 *         Faithfully replicates all revert conditions and code paths from the bytecode.
 *
 *         Code paths:
 *           1. System call (caller == SYSTEM_ADDRESS, any calldatasize) → dequeue, update excess, reset count, return data
 *           2. Fee getter (calldatasize == 0, msg.value == 0)           → return current fee
 *           3. Add request (calldatasize == 56, msg.value >= fee)       → enqueue withdrawal request
 *           4. Everything else                                          → REVERT
 *
 *         Revert conditions (exactly 4):
 *           1. excess == EXCESS_INHIBITOR (contract not yet initialized)
 *           2. calldatasize ∉ {0, 56} and caller ≠ SYSTEM_ADDRESS
 *           3. calldatasize == 0 && msg.value > 0
 *           4. calldatasize == 56 && msg.value < fee
 *
 * @dev    Deploy this at the canonical address 0x00000961Ef480Eb55e80D19ad83579A64c007002
 *         in your test setup using vm.etch() (Foundry) or hardhat_setCode (Hardhat).
 *
 *         Usage with Foundry:
 *           EIP7002Mock mock = new EIP7002Mock();
 *           vm.etch(0x00000961Ef480Eb55e80D19ad83579A64c007002, address(mock).code);
 *           Then use the interface below to interact
 *
 *         Usage with vm.store() to pre-initialize:
 *           After etch, initialize excess to 0 so it doesn't revert with EXCESS_INHIBITOR
 *           vm.store(WITHDRAWAL_REQUEST_ADDRESS, bytes32(uint256(0)), bytes32(uint256(0)));
 */
contract EIP7002Mock {
    // ── Events ──────────────────────────────────────────────────────────────
    // The real contract emits a LOG0 with 76 bytes: sender(20) ++ calldata(56)
    // We emit a typed event for easier test assertions.
    event WithdrawalRequestAdded(
        address indexed sender, bytes32 validatorPubkeyPart1, bytes16 validatorPubkeyPart2, uint64 amount
    );

    // ── Storage (matches the predeploy layout) ──────────────────────────────
    // slot 0: excess withdrawal requests
    // slot 1: withdrawal request count (current block)
    // slot 2: queue head index
    // slot 3: queue tail index
    // slot 4+: queue entries, each taking 3 slots

    // We use raw assembly for storage to match the exact slot layout.
    // But we also provide Solidity-level helpers for readability.

    // ── Fallback: routes all calls exactly like the bytecode ────────────────
    fallback() external payable {
        // Path 1: System call
        if (msg.sender == SYSTEM_ADDRESS) {
            _systemCall();
            return;
        }

        // Compute fee (reverts if EXCESS_INHIBITOR)
        uint256 fee = _getFee();

        // Path 2: Fee getter (calldatasize == 0)
        if (msg.data.length == 56) {
            // Path 3: Add withdrawal request
            require(msg.value >= fee); // Revert condition #4
            _addWithdrawalRequest();
            return;
        }

        if (msg.data.length == 0) {
            require(msg.value == 0); // Revert condition #3
            // Return fee as uint256
            assembly {
                mstore(0x00, fee)
                return(0x00, 0x20)
            }
        }

        // Revert condition #2: invalid calldatasize
        revert();
    }

    // Also support receive for the fee getter path (calldatasize==0, value==0)
    receive() external payable {
        if (msg.sender == SYSTEM_ADDRESS) {
            _systemCall();
            return;
        }

        uint256 fee = _getFee();

        // Fee getter: calldatasize == 0
        require(msg.value == 0); // Revert condition #3
        assembly {
            mstore(0x00, fee)
            return(0x00, 0x20)
        }
    }

    // ── Fee calculation (fake_exponential) ──────────────────────────────────

    function _getFee() internal view returns (uint256) {
        uint256 excess;
        assembly {
            excess := sload(EXCESS_WITHDRAWAL_REQUESTS_STORAGE_SLOT)
        }
        require(excess != EXCESS_INHIBITOR); // Revert condition #1

        return _fakeExponential(MIN_WITHDRAWAL_REQUEST_FEE, excess, WITHDRAWAL_REQUEST_FEE_UPDATE_FRACTION);
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

    // ── Add withdrawal request ──────────────────────────────────────────────

    function _addWithdrawalRequest() internal {
        // Increment count
        uint256 count;
        assembly {
            count := sload(WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT)
            sstore(WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT, add(count, 1))
        }

        // Read queue tail
        uint256 queueTailIndex;
        assembly {
            queueTailIndex := sload(WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT)
        }

        // Compute storage slot for this entry (3 slots per entry)
        uint256 queueSlot = WITHDRAWAL_REQUEST_QUEUE_STORAGE_OFFSET + queueTailIndex * 3;

        // Store source_address (msg.sender) in first slot
        // Store pubkey[0:32] in second slot
        // Store pubkey[32:48] ++ little_endian(amount) in third slot
        //
        // calldata layout: [0:48] = pubkey, [48:56] = amount (big-endian uint64)

        bytes32 pubkeyFirst32;
        bytes32 pubkeySecondAndAmount;
        assembly {
            pubkeyFirst32 := calldataload(0)
            // calldataload(32) gives us bytes [32:64] of calldata
            // but calldata is only 56 bytes, so bytes [56:64] are zero-padded
            // pubkey[32:48] is the top 16 bytes of calldataload(32)
            // amount (big-endian) is bytes [48:56] = next 8 bytes
            pubkeySecondAndAmount := calldataload(32)
        }

        // The real contract stores:
        //   slot+0: msg.sender (stored as address, left-padded with zeros in 32-byte slot)
        //   slot+1: pubkey[0:32] (calldataload(0))
        //   slot+2: pubkey[32:48] ++ amount (calldataload(0x20))
        //
        // But for the amount, the bytecode stores calldataload(0x20) directly,
        // which contains pubkey[32:48] (16 bytes) ++ amount_bigendian (8 bytes) ++ zeros (8 bytes).
        // The system call later reads it back and converts amount to little-endian for the output.

        assembly {
            sstore(queueSlot, caller())
            sstore(add(queueSlot, 1), pubkeyFirst32)
            sstore(add(queueSlot, 2), pubkeySecondAndAmount)

            // Update tail
            sstore(WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT, add(queueTailIndex, 1))
        }

        // Emit LOG0 matching the real contract: 76 bytes = sender(20) ++ calldata(56)
        // The real bytecode does: caller pushed to mem[0:20] as 60-shl, then calldatacopy 56 bytes at offset 20
        // Totaling 76 bytes for LOG0.
        // We also emit a typed event for convenience.
        bytes32 pubkeyPart1;
        bytes16 pubkeyPart2;
        uint64 amount;
        assembly {
            pubkeyPart1 := calldataload(0)
            pubkeyPart2 := calldataload(32)
            // amount is big-endian uint64 at calldata offset 48
            amount := shr(192, calldataload(48))
        }

        // LOG0 (unindexed, matches real contract)
        bytes memory logData = new bytes(76);
        assembly {
            // Store sender address at logData+32 (first 20 bytes of data portion)
            mstore(add(logData, 32), shl(96, caller()))
            // Copy calldata (56 bytes) starting at logData+32+20 = logData+52
            calldatacopy(add(logData, 52), 0, 56)
            log0(add(logData, 32), 76)
        }

        emit WithdrawalRequestAdded(msg.sender, pubkeyPart1, pubkeyPart2, amount);
    }

    // ── System call: dequeue + update excess + reset count ──────────────────

    function _systemCall() internal {
        // Dequeue
        uint256 queueHeadIndex;
        uint256 queueTailIndex;
        assembly {
            queueHeadIndex := sload(WITHDRAWAL_REQUEST_QUEUE_HEAD_STORAGE_SLOT)
            queueTailIndex := sload(WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT)
        }

        uint256 numInQueue = queueTailIndex - queueHeadIndex;
        uint256 numDequeued =
            numInQueue < MAX_WITHDRAWAL_REQUESTS_PER_BLOCK ? numInQueue : MAX_WITHDRAWAL_REQUESTS_PER_BLOCK;

        // Build return data: each request is 76 bytes (0x4c)
        // Layout per request: source_address(20) ++ pubkey(32) ++ pubkey_rest(16) ++ amount_le(8)
        bytes memory returnData = new bytes(numDequeued * QUEUE_ENTRY_SIZE);

        for (uint256 i = 0; i < numDequeued; i++) {
            uint256 queueSlot = WITHDRAWAL_REQUEST_QUEUE_STORAGE_OFFSET + (queueHeadIndex + i) * 3;
            uint256 offset = i * QUEUE_ENTRY_SIZE;

            address sourceAddr;
            bytes32 pubkeyFirst;
            bytes32 slot2Val;
            assembly {
                sourceAddr := sload(queueSlot)
                pubkeyFirst := sload(add(queueSlot, 1))
                slot2Val := sload(add(queueSlot, 2))
            }

            // slot2Val layout: pubkey[32:48] (16 bytes) ++ amount_be (8 bytes) ++ zeros (8 bytes)
            // The real bytecode converts amount from big-endian to little-endian byte by byte.
            // Extract the 16 bytes of pubkey remainder
            bytes16 pubkeySecond = bytes16(slot2Val);

            // Extract amount (big-endian uint64) from slot2Val bytes [16:24]
            uint64 amountBE;
            assembly {
                amountBE := shr(192, shl(128, slot2Val))
            }

            // Convert to little-endian
            uint64 amountLE = _swapEndian64(amountBE);

            // Write to returnData
            assembly {
                let ptr := add(add(returnData, 32), offset)
                // source_address: 20 bytes, left-shifted
                mstore(ptr, shl(96, sourceAddr))
                // pubkey first 32 bytes at offset+20
                mstore(add(ptr, 20), pubkeyFirst)
                // pubkey second 16 bytes at offset+52
                // We need to write 16 bytes of pubkeySecond then 8 bytes of amountLE
                mstore(add(ptr, 52), pubkeySecond)
                // amount LE at offset+68 (overwrite the zeros after pubkeySecond)
                // pubkeySecond wrote 16 bytes starting at 52, so next 16 bytes are zeros
                // We need to place amountLE (8 bytes) at offset+68
                mstore8(add(ptr, 68), and(amountLE, 0xff))
                mstore8(add(ptr, 69), and(shr(8, amountLE), 0xff))
                mstore8(add(ptr, 70), and(shr(16, amountLE), 0xff))
                mstore8(add(ptr, 71), and(shr(24, amountLE), 0xff))
                mstore8(add(ptr, 72), and(shr(32, amountLE), 0xff))
                mstore8(add(ptr, 73), and(shr(40, amountLE), 0xff))
                mstore8(add(ptr, 74), and(shr(48, amountLE), 0xff))
                mstore8(add(ptr, 75), and(shr(56, amountLE), 0xff))
            }
        }

        // Update queue head
        uint256 newQueueHeadIndex = queueHeadIndex + numDequeued;
        if (newQueueHeadIndex == queueTailIndex) {
            // Queue empty, reset both pointers
            assembly {
                sstore(WITHDRAWAL_REQUEST_QUEUE_HEAD_STORAGE_SLOT, 0)
                sstore(WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT, 0)
            }
        } else {
            assembly {
                sstore(WITHDRAWAL_REQUEST_QUEUE_HEAD_STORAGE_SLOT, newQueueHeadIndex)
            }
        }

        // Update excess
        uint256 previousExcess;
        assembly {
            previousExcess := sload(EXCESS_WITHDRAWAL_REQUESTS_STORAGE_SLOT)
        }
        if (previousExcess == EXCESS_INHIBITOR) {
            previousExcess = 0;
        }

        uint256 count;
        assembly {
            count := sload(WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT)
        }

        uint256 newExcess = 0;
        if (previousExcess + count > TARGET_WITHDRAWAL_REQUESTS_PER_BLOCK) {
            newExcess = previousExcess + count - TARGET_WITHDRAWAL_REQUESTS_PER_BLOCK;
        }

        assembly {
            sstore(EXCESS_WITHDRAWAL_REQUESTS_STORAGE_SLOT, newExcess)
        }

        // Reset count
        assembly {
            sstore(WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT, 0)
        }

        // Return dequeued data
        uint256 retSize = numDequeued * QUEUE_ENTRY_SIZE;
        assembly {
            return(add(returnData, 32), retSize)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _swapEndian64(uint64 val) internal pure returns (uint64) {
        val = ((val & 0xFF00FF00FF00FF00) >> 8) | ((val & 0x00FF00FF00FF00FF) << 8);
        val = ((val & 0xFFFF0000FFFF0000) >> 16) | ((val & 0x0000FFFF0000FFFF) << 16);
        val = (val >> 32) | (val << 32);
        return val;
    }

    // ── View helpers for tests (not part of the real contract) ───────────────

    /// Read the current excess value from storage
    function getExcess() external view returns (uint256) {
        uint256 val;
        assembly { val := sload(EXCESS_WITHDRAWAL_REQUESTS_STORAGE_SLOT) }
        return val;
    }

    /// Read the current request count for this block
    function getCount() external view returns (uint256) {
        uint256 val;
        assembly { val := sload(WITHDRAWAL_REQUEST_COUNT_STORAGE_SLOT) }
        return val;
    }

    /// Read queue head index
    function getQueueHead() external view returns (uint256) {
        uint256 val;
        assembly { val := sload(WITHDRAWAL_REQUEST_QUEUE_HEAD_STORAGE_SLOT) }
        return val;
    }

    /// Read queue tail index
    function getQueueTail() external view returns (uint256) {
        uint256 val;
        assembly { val := sload(WITHDRAWAL_REQUEST_QUEUE_TAIL_STORAGE_SLOT) }
        return val;
    }
}
