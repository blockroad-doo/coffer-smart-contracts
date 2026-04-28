//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS} from "../mock/EIP7002Mock.sol";

/**
 * @title RefundBranchProbe
 * @notice Isolated proxy that mirrors the tail of `holderWithdrawFromConsensus`
 *         with and without the proposed refund branch. Used to measure the
 *         marginal gas cost of adding the refund branch BEFORE touching
 *         production code, so `REFUND_BRANCH_GAS` can be set from measurement
 *         rather than from guesswork.
 * @dev The non-refund path is intentionally byte-for-byte identical to the
 *      with-refund path up to the refund branch, so the measured delta
 *      isolates only the branch's marginal cost.
 */
contract RefundBranchProbe {
    uint256 public immutable REFUND_BRANCH_GAS;

    error ReadFailed();
    error WriteFailed();
    error InsufficientFee();

    constructor(uint256 refundBranchGas) {
        REFUND_BRANCH_GAS = refundBranchGas;
    }

    /// @notice Mirrors the tail of `holderWithdrawFromConsensus` as it exists today
    ///         (fee read via staticcall, then value-forwarded call to WITHDRAWAL_CONTRACT).
    function doWithoutRefund(uint64 amount) external payable {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.staticcall("");
        if (!readOk) revert ReadFailed();
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));
        if (fee > msg.value) revert InsufficientFee();

        bytes memory data = abi.encodePacked(bytes32(uint256(1)), bytes16(uint128(2)), amount);
        (bool writeOk,) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        if (!writeOk) revert WriteFailed();
    }

    /// @notice Mirrors the same tail PLUS the proposed refund branch.
    ///         This is the code whose marginal cost we are pinning down.
    function doWithRefund(uint64 amount) external payable {
        (bool readOk, bytes memory feeData) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.staticcall("");
        if (!readOk) revert ReadFailed();
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));
        if (fee > msg.value) revert InsufficientFee();

        bytes memory data = abi.encodePacked(bytes32(uint256(1)), bytes16(uint128(2)), amount);
        (bool writeOk,) = WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS.call{value: fee}(data);
        if (!writeOk) revert WriteFailed();

        // ── Proposed refund branch ──────────────────────────────────────────
        // If the surplus exceeds the gas cost of the refund itself, send it back.
        // Otherwise retain it. Refunding would cost the caller more than they recover.
        uint256 excess = msg.value - fee;
        if (excess > REFUND_BRANCH_GAS * tx.gasprice) {
            Address.sendValue(payable(msg.sender), excess);
        }
    }
}

/**
 * @title RefundMarginalGasTest
 * @notice Measures the marginal gas cost of the proposed refund branch in
 *         `holderWithdrawFromConsensus`. The measurement drives the
 *         `REFUND_BRANCH_GAS` constant on the right-hand side of the
 *         threshold check:
 *
 *             uint256 excess = msg.value - fee;
 *             if (excess > REFUND_BRANCH_GAS * tx.gasprice) { refund(); }
 *
 *         Methodology: run a probe (RefundBranchProbe) whose two functions
 *         differ only by the refund branch, with identical upstream
 *         structure. Delta = marginal cost. Repeated in a realistic context
 *         (EOA caller, warmed access list, realistic `tx.gasprice`).
 */
contract RefundMarginalGasTest is BaseTest {
    RefundBranchProbe public probe;

    /// @notice Headroom budget the refund branch must stay below. Real
    ///         measurement is reported via console2.log. This bound exists
    ///         so upstream toolchain changes (Solidity, OZ, optimizer runs)
    ///         surface in CI the moment they push the branch over budget.
    uint256 public constant REFUND_BRANCH_GAS = 10_000;

    /// @notice Realistic gas price so `REFUND_BRANCH_GAS * tx.gasprice` is
    ///         large enough to be a meaningful threshold in the probe.
    ///         Matches typical post-London mainnet base fee levels.
    uint256 public constant REALISTIC_GAS_PRICE = 20 gwei;

    /// @notice The refund branch calls `msg.sender.call{value: excess}("")`.
    ///         When the test contract is the caller, the refund lands here;
    ///         a payable receiver is required or the send reverts.
    receive() external payable {}

    function setUp() public override {
        super.setUp();
        probe = new RefundBranchProbe(REFUND_BRANCH_GAS);
        vm.deal(address(this), 100 ether);
        vm.txGasPrice(REALISTIC_GAS_PRICE);
    }

    // ────────────────────────────────────────────────────────────────────────
    // CORE MEASUREMENT: drives the constant
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Measures the marginal gas cost of the refund branch when the
    ///         surplus exceeds the threshold (refund actually fires). This
    ///         is the upper-bound case the constant must cover.
    function test_MarginalRefundBranchGas_RefundTakenPath() public {
        uint256 fee = getWithdrawalFee();
        uint256 sendValue = 0.001 ether; // ≈ 1e15 wei surplus, above threshold
        uint256 threshold = REFUND_BRANCH_GAS * tx.gasprice;
        require(sendValue - fee > threshold, "setup: surplus must exceed threshold");

        // Warm-up runs so cold-access charges on WITHDRAWAL_CONTRACT, probe,
        // and msg.sender don't skew the second-call measurements.
        probe.doWithoutRefund{value: sendValue}(32);
        probe.doWithRefund{value: sendValue}(32);

        // Measured run: without-refund path.
        uint256 before1 = gasleft();
        probe.doWithoutRefund{value: sendValue}(32);
        uint256 gasWithout = before1 - gasleft();

        // Measured run: with-refund path.
        uint256 before2 = gasleft();
        probe.doWithRefund{value: sendValue}(32);
        uint256 gasWith = before2 - gasleft();

        console2.log("without-refund gas :", gasWithout);
        console2.log("with-refund gas    :", gasWith);
        assertGt(gasWith, gasWithout, "refund path should consume strictly more gas");

        uint256 marginal = gasWith - gasWithout;
        console2.log("marginal refund gas:", marginal);
        console2.log("budget (constant)  :", REFUND_BRANCH_GAS);

        assertLt(marginal, REFUND_BRANCH_GAS, "refund branch exceeds the stated budget");
    }

    /// @notice Measures the marginal cost when the surplus is below the
    ///         threshold (refund is skipped). Only the `SUB + GT + JUMPI`
    ///         comparison runs, so the delta should be a small constant
    ///         (low hundreds of gas at most) representing the cost of the
    ///         guard itself.
    function test_MarginalRefundBranchGas_RefundSkippedPath() public {
        uint256 fee = getWithdrawalFee();
        uint256 threshold = REFUND_BRANCH_GAS * tx.gasprice;
        // Surplus of 1 wei, guaranteed below the threshold.
        uint256 sendValue = fee + 1;
        require(sendValue - fee < threshold, "setup: surplus must be below threshold");

        probe.doWithoutRefund{value: sendValue}(32);
        probe.doWithRefund{value: sendValue}(32);

        uint256 before1 = gasleft();
        probe.doWithoutRefund{value: sendValue}(32);
        uint256 gasWithout = before1 - gasleft();

        uint256 before2 = gasleft();
        probe.doWithRefund{value: sendValue}(32);
        uint256 gasWith = before2 - gasleft();

        console2.log("without-refund gas :", gasWithout);
        console2.log("with-refund gas    :", gasWith);

        // The skipped-refund path only adds the comparison and branch; the
        // CALL+value transfer never runs. Marginal should be small but can
        // occasionally be zero or slightly negative depending on how the
        // compiler reorders adjacent ops. Assert absolute delta is tiny.
        uint256 absMarginal = gasWith > gasWithout ? gasWith - gasWithout : gasWithout - gasWith;
        console2.log("|marginal| (skipped):", absMarginal);
        assertLt(absMarginal, 300, "guard-only path should cost only a few opcodes");
    }

    // ────────────────────────────────────────────────────────────────────────
    // SUPPORTING MEASUREMENTS: sanity-check the dominant component
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Baseline: cost of a raw `Address.sendValue` to a warm,
    ///         pre-existing EOA. Per EVM spec the CALL with value transfer
    ///         is 9,000 + 100 (warm) = 9,100 gas, plus a few hundred gas of
    ///         Solidity / OZ overhead. Anchors the expectation behind
    ///         REFUND_BRANCH_GAS = 10,000.
    function test_SendValueBaseline_WarmExistingRecipient() public {
        address payable recipient = payable(holder1); // funded in BaseTest.setUp

        // Warm the recipient so we measure the warm-access path.
        (bool ok,) = recipient.call{value: 0}("");
        require(ok, "warm-up failed");

        uint256 before = gasleft();
        Address.sendValue(recipient, 100 wei);
        uint256 used = before - gasleft();

        console2.log("raw sendValue gas (warm EOA):", used);
        // 9,000 (value) + 100 (warm CALL) + ~500 (OZ wrapper + SELFBALANCE check) = ~9,600.
        assertLt(used, 10_000, "sendValue to warm EOA should fit inside the budget");
    }

    /// @notice Baseline: cost of `Address.sendValue` to a cold, non-existent
    ///         recipient. Demonstrates the penalty we avoid by measuring
    ///         the refund branch against `msg.sender` (which is always warm
    ///         inside a transaction after the entry-point access).
    function test_SendValueBaseline_ColdNewAccount() public {
        address payable recipient = payable(address(uint160(uint256(keccak256("fresh-never-touched")))));
        // No warm-up: first touch. New-account value transfer triggers the
        // +25,000 gas account-creation surcharge on top of the 9,000 value
        // cost and 2,600 cold-access cost.

        uint256 before = gasleft();
        Address.sendValue(recipient, 100 wei);
        uint256 used = before - gasleft();

        console2.log("raw sendValue gas (cold new account):", used);
        // Cold + new-account path: can exceed 30,000 gas. This is why the
        // real refund target must be a warm, existing EOA (msg.sender).
        assertGt(used, 20_000, "cold new-account send should be materially more expensive");
    }

    // ────────────────────────────────────────────────────────────────────────
    // FUTURE: once the refund branch lands in production Coffer, switch
    // measurement to the real function for end-to-end coverage.
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Placeholder for measuring the real `holderWithdrawFromConsensus`
    ///         once the refund branch is added to `src/Coffer.sol`. Compares
    ///         gas of a call with a tight buffer (refund skipped) against a
    ///         call with a fat buffer (refund taken) on the production
    ///         function itself. Until the branch exists, both calls consume
    ///         identical gas and this test is skipped.
    function test_ProductionFunction_MarginalRefundBranchGas() public {
        // Disabled until refund branch is implemented. Uncomment the body
        // below once `Coffer.holderWithdrawFromConsensus` contains the
        // `if (excess > REFUND_BRANCH_GAS * tx.gasprice) Address.sendValue(...)`
        // block.
        vm.skip(true);

        // address cofferAddr = createDefaultCoffer();
        // Coffer c = Coffer(payable(cofferAddr));
        // vm.prank(validator);
        // c.changeIssueSize(10 ether);
        // uint256 bondId1 = buyBond(cofferAddr, holder1, 1 ether, ONE_MONTH, 2);
        // uint256 bondId2 = buyBond(cofferAddr, holder2, 1 ether, ONE_MONTH, 2);
        // advanceTime(ONE_MONTH + 1);
        //
        // uint256 fee = getWithdrawalFee();
        //
        // // Tight buffer: surplus below threshold → refund branch skipped.
        // vm.prank(holder1);
        // uint256 before1 = gasleft();
        // c.holderWithdrawFromConsensus{value: fee + 1}(bondId1);
        // uint256 gasTight = before1 - gasleft();
        //
        // // Fat buffer: surplus above threshold → refund branch taken.
        // vm.prank(holder2);
        // uint256 before2 = gasleft();
        // c.holderWithdrawFromConsensus{value: 0.001 ether}(bondId2);
        // uint256 gasFat = before2 - gasleft();
        //
        // console2.log("tight-buffer gas :", gasTight);
        // console2.log("fat-buffer gas   :", gasFat);
        // console2.log("marginal (taken) :", gasFat - gasTight);
        // assertLt(gasFat - gasTight, REFUND_BRANCH_GAS, "production refund exceeds budget");
    }
}
