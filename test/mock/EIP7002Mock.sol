// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// ─── Constants ───────────────────────────────────────────────────────────────

address payable constant WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS = payable(0x00000961Ef480Eb55e80D19ad83579A64c007002);
address constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

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
 *         IMPORTANT CONSENSUS LAYER BEHAVIOR:
 *         ====================================
 *         This contract is a "dumb queue" - it does NOT validate:
 *           - Whether the pubkey corresponds to a real validator
 *           - Whether msg.sender matches the validator's withdrawal credentials
 *           - Whether the amount is valid or sensible
 *           - Whether partial withdrawals are allowed for the validator type
 *
 *         The consensus layer handles all validation after dequeuing:
 *
 *         For validators with 0x01 credentials (regular validators):
 *           - Partial withdrawals are SILENTLY IGNORED
 *           - Only full exits (amount = 0) are processed
 *           - The fee is consumed but nothing happens
 *
 *         For validators with 0x02 credentials (compounding validators):
 *           - Partial withdrawals are allowed
 *           - Amount is CLAMPED to maintain MIN_ACTIVATION_BALANCE (32 ETH)
 *           - Example: 40 ETH validator requesting 10 ETH withdrawal
 *             → Only 8 ETH withdrawn (40 - 32 = 8), keeping exactly 32 ETH
 *           - If balance <= 32 ETH, partial withdrawal is ignored entirely
 *
 *         For invalid requests (wrong pubkey, wrong credentials, etc):
 *           - Request is dequeued and discarded
 *           - Fee is NOT refunded
 *           - No error is raised
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
        if (msg.data.length == 0) {
            require(msg.value == 0); // Revert condition #3
            // Return fee as uint256
            assembly {
                mstore(0x00, fee)
                return(0x00, 0x20)
            }
        }

        // Path 3: Add withdrawal request (calldatasize == 56)
        // Format: 32 bytes pubkey1 + 16 bytes pubkey2 + 8 bytes amount
        if (msg.data.length == 56) {
            require(msg.value >= fee); // Revert condition #4
            _addWithdrawalRequest();
            return;
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
        // Store pubkey[32:48] ++ amount (big-endian uint64) in third slot
        //
        // calldata layout: [0:48] = pubkey, [48:56] = amount (big-endian uint64)

        bytes32 pubkeyFirst32;
        bytes32 pubkeySecondAndAmount;
        assembly {
            pubkeyFirst32 := calldataload(0)
            // calldataload(32) gives us bytes [32:64] of calldata
            // For 56-byte calldata: bytes [32:48] = pubkey part 2, [48:56] = amount
            // Bytes [56:64] are zero-padded since calldata is only 56 bytes
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

        // Emit LOG0 matching the real contract: 76 bytes = sender(20) ++ pubkey(48) ++ amount(8)
        // We also emit a typed event for convenience.
        bytes32 pubkeyPart1;
        bytes16 pubkeyPart2;
        uint64 amount;
        assembly {
            pubkeyPart1 := calldataload(0)
            // For bytes16, we want the first 16 bytes of calldataload(32)
            // calldataload(32) already gives us pubkeyPart2 in the high-order 16 bytes
            let temp := calldataload(32)
            pubkeyPart2 := temp // implicit truncation to bytes16 takes the first 16 bytes
            // amount is big-endian uint64 at calldata offset 48
            amount := shr(192, calldataload(48))
        }

        // LOG0 (unindexed, matches real contract)
        bytes memory logData = new bytes(76);
        assembly {
            // Store sender address at logData+32 (first 20 bytes of data portion)
            mstore(add(logData, 32), shl(96, caller()))
            // Copy only first 56 bytes of calldata (exclude source suffix)
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
            // forge-lint: disable-next-line(unsafe-typecast) extracting high 16 bytes from slot value
            bytes16 pubkeySecond = bytes16(slot2Val);

            // Extract amount (big-endian uint64) from slot2Val bytes [16:24]
            uint64 amountBe;
            assembly {
                // slot2Val has: pubkey[32:48] (16 bytes) ++ amount_be (8 bytes) ++ zeros (8 bytes)
                // We want bytes [16:24] which contain the amount
                // First shift left by 128 bits to remove first 16 bytes
                // Then shift right by 192 bits to get the 8 bytes we want as uint64
                amountBe := shr(192, shl(128, slot2Val))
            }

            // We'll write this amount in little-endian byte order
            // No need to swap - we'll just write the bytes in reverse order

            // Write to returnData
            assembly {
                let ptr := add(add(returnData, 32), offset)
                // source_address: 20 bytes, left-shifted
                mstore(ptr, shl(96, sourceAddr))
                // pubkey first 32 bytes at offset+20
                mstore(add(ptr, 20), pubkeyFirst)
                // pubkey second 16 bytes at offset+52 - write byte by byte
                // pubkeySecond is bytes16, left-aligned in the word
                let pubkey2 := pubkeySecond
                mstore8(add(ptr, 52), byte(0, pubkey2))
                mstore8(add(ptr, 53), byte(1, pubkey2))
                mstore8(add(ptr, 54), byte(2, pubkey2))
                mstore8(add(ptr, 55), byte(3, pubkey2))
                mstore8(add(ptr, 56), byte(4, pubkey2))
                mstore8(add(ptr, 57), byte(5, pubkey2))
                mstore8(add(ptr, 58), byte(6, pubkey2))
                mstore8(add(ptr, 59), byte(7, pubkey2))
                mstore8(add(ptr, 60), byte(8, pubkey2))
                mstore8(add(ptr, 61), byte(9, pubkey2))
                mstore8(add(ptr, 62), byte(10, pubkey2))
                mstore8(add(ptr, 63), byte(11, pubkey2))
                mstore8(add(ptr, 64), byte(12, pubkey2))
                mstore8(add(ptr, 65), byte(13, pubkey2))
                mstore8(add(ptr, 66), byte(14, pubkey2))
                mstore8(add(ptr, 67), byte(15, pubkey2))
                // Write amount at offset+68 (8 bytes in little-endian)
                // amountBe is big-endian, write it in little-endian byte order
                mstore8(add(ptr, 68), and(amountBe, 0xff))
                mstore8(add(ptr, 69), and(shr(8, amountBe), 0xff))
                mstore8(add(ptr, 70), and(shr(16, amountBe), 0xff))
                mstore8(add(ptr, 71), and(shr(24, amountBe), 0xff))
                mstore8(add(ptr, 72), and(shr(32, amountBe), 0xff))
                mstore8(add(ptr, 73), and(shr(40, amountBe), 0xff))
                mstore8(add(ptr, 74), and(shr(48, amountBe), 0xff))
                mstore8(add(ptr, 75), and(shr(56, amountBe), 0xff))
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

    // ── Consensus layer simulation helpers (for testing only) ─────────────────

    /// Constants matching consensus layer specs
    uint256 public constant MIN_ACTIVATION_BALANCE = 32 ether;

    /// Credential types
    uint8 public constant CREDENTIAL_TYPE_BLS = 0x00;
    uint8 public constant CREDENTIAL_TYPE_EXECUTION = 0x01;
    uint8 public constant CREDENTIAL_TYPE_COMPOUNDING = 0x02;

    /**
     * @notice Simulates consensus layer processing of a partial withdrawal request
     * @dev This helper demonstrates what would happen on the consensus layer
     * @param credentialType The validator's credential type (0x01 or 0x02)
     * @param validatorBalance Current validator balance in wei
     * @param requestedAmount Amount requested to withdraw in Gwei
     * @return actualAmount Amount that would actually be withdrawn in Gwei
     * @return wouldProcess Whether the request would be processed (not ignored)
     */
    function simulateConsensusWithdrawal(uint8 credentialType, uint256 validatorBalance, uint64 requestedAmount)
        external
        pure
        returns (uint64 actualAmount, bool wouldProcess)
    {
        // Convert Gwei amount to wei for calculation
        uint256 requestedWei = uint256(requestedAmount) * 1 gwei;

        // Full exit (amount = 0) is always processed for any credential type
        if (requestedAmount == 0) {
            return (0, true);
        }

        // 0x01 credentials: partial withdrawals are silently ignored
        if (credentialType == CREDENTIAL_TYPE_EXECUTION) {
            return (0, false);
        }

        // 0x02 compounding credentials: partial withdrawals are allowed with clamping
        if (credentialType == CREDENTIAL_TYPE_COMPOUNDING) {
            // Check if validator has excess balance above MIN_ACTIVATION_BALANCE
            if (validatorBalance <= MIN_ACTIVATION_BALANCE) {
                // No excess balance, withdrawal ignored
                return (0, false);
            }

            // Calculate maximum withdrawable amount (maintaining MIN_ACTIVATION_BALANCE)
            uint256 maxWithdrawable = validatorBalance - MIN_ACTIVATION_BALANCE;

            // If available balance is less than 1 Gwei, cannot withdraw (Gwei precision)
            if (maxWithdrawable < 1 gwei) {
                return (0, false);
            }

            // Clamp the withdrawal amount
            uint256 actualWei = requestedWei > maxWithdrawable ? maxWithdrawable : requestedWei;

            // Convert back to Gwei
            // forge-lint: disable-next-line(unsafe-typecast) bounded by validator balance
            actualAmount = uint64(actualWei / 1 gwei);
            return (actualAmount, actualAmount > 0);
        }

        // Unknown credential type (shouldn't happen in practice)
        return (0, false);
    }

    /**
     * @notice Helper to demonstrate the 40 ETH validator withdrawing 10 ETH scenario
     * @param credentialType The validator's credential type
     * @return actualWithdrawnGwei Amount actually withdrawn in Gwei
     * @return explanation Human-readable explanation of what happened
     */
    function demonstratePartialWithdrawalScenario(uint8 credentialType)
        external
        view
        returns (uint64 actualWithdrawnGwei, string memory explanation)
    {
        uint256 validatorBalance = 40 ether;
        uint64 requestedGwei = 10_000_000_000; // 10 ETH in Gwei

        (uint64 actualAmount, bool wouldProcess) =
            this.simulateConsensusWithdrawal(credentialType, validatorBalance, requestedGwei);

        if (credentialType == CREDENTIAL_TYPE_EXECUTION) {
            return (0, "0x01 credentials: Partial withdrawal ignored, fee lost");
        } else if (credentialType == CREDENTIAL_TYPE_COMPOUNDING) {
            if (wouldProcess) {
                return
                    (actualAmount, "0x02 credentials: Withdrew 8 ETH (clamped from 10 ETH to maintain 32 ETH minimum)");
            }
        }

        return (0, "Unknown credential type or request ignored");
    }
}
