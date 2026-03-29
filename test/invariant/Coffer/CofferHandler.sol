//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";
import {Interest} from "../../../src/libraries/Interest.sol";

contract CofferHandler is Test {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 constant EXIT_QUEUE_ETH = 500_000 ether;
    uint256 constant ETH_PER_EPOCH = 256 ether;
    uint16 constant SECONDS_PER_EPOCH = 384;
    uint256 constant EXIT_QUEUE_DELAY = (EXIT_QUEUE_ETH * SECONDS_PER_EPOCH) / ETH_PER_EPOCH;

    uint256 constant MAX_RATE = 1e8;
    uint256 constant GWEI_RATE = 1e9;
    uint256 constant SECONDS_IN_YEAR = 31_536_000;

    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;

    // ── Struct ─────────────────────────────────────────────────────────────
    struct PendingWithdrawal {
        uint256 bondId;
        uint128 amount;
        uint256 arrivalTime;
        address holderAddress;
    }

    // ── Contracts ──────────────────────────────────────────────────────────
    Coffer public coffer;
    CofferBondNft public bondNft;

    // ── Actors ─────────────────────────────────────────────────────────────
    address public validator;
    address[] public holders;

    // ── Ghost state ────────────────────────────────────────────────────────
    uint256[] public ghostActiveBondIds;
    mapping(uint256 => bool) public ghostIsBondActive;
    mapping(uint256 => address) public ghostBondHolder;
    mapping(uint256 => uint128) public ghostBondAmount;
    mapping(uint256 => bool) public ghostHasPendingConsensusWithdrawal;
    PendingWithdrawal[] public ghostPendingWithdrawals;

    uint256 public ghostTotalBondsBought;
    uint256 public ghostTotalBondsRedeemed;
    uint256 public ghostTotalBondsWithdrawnExecution;
    uint256 public ghostTotalBondsWithdrawnConsensus;
    uint256 public ghostTotalEthArrivedFromConsensus;

    // ── Per-function call counters ─────────────────────────────────────────
    uint256 public callsBuyBond;
    uint256 public callsHolderWithdrawFromExecution;
    uint256 public callsHolderWithdrawFromConsensus;
    uint256 public callsSimulateEthArrival;
    uint256 public callsRedeemBondsEarly;
    uint256 public callsValidatorWithdrawFromExecution;
    uint256 public callsValidatorAddFundsToConsensus;
    uint256 public callsChangeCofferActivity;
    uint256 public callsChangeInterestRate;
    uint256 public callsChangeIssueSize;
    uint256 public callsAdvanceTime;
    uint256 public callsSendEthToCoffer;

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(Coffer _coffer, CofferBondNft _bondNft) {
        coffer = _coffer;
        bondNft = _bondNft;
        validator = _coffer.owner();

        holders.push(makeAddr("cofferHolder0"));
        holders.push(makeAddr("cofferHolder1"));
        holders.push(makeAddr("cofferHolder2"));
        holders.push(makeAddr("cofferHolder3"));
        holders.push(makeAddr("cofferHolder4"));

        for (uint256 i = 0; i < holders.length; i++) {
            vm.deal(holders[i], 1000 ether);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS (stack-depth reduction)
    // ══════════════════════════════════════════════════════════════════════

    struct BuyBondParams {
        uint128 issueSize;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumValueToAccept;
        uint32 version;
        bool isActive;
    }

    function _readBuyBondParams() private view returns (BuyBondParams memory p) {
        (
            uint128 issueSize,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumValueToAccept,
            uint32 version,,,
            bool isActive,
        ) = coffer.sValidatorConditions();
        p.issueSize = issueSize;
        p.interestRate = interestRate;
        p.minimumDuration = minimumDuration;
        p.maximumDuration = maximumDuration;
        p.minimumValueToAccept = minimumValueToAccept;
        p.version = version;
        p.isActive = isActive;
    }

    function _extractBondIdFromLogs() private returns (uint256 bondId) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("BondBought(address,uint256,uint128,uint32)")) {
                return uint256(entries[i].topics[2]);
            }
        }
    }

    function _toLittleEndian64(uint64 value) private pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════

    function handlerBuyBond(uint256 actorSeed, uint256 amount, uint256 duration) external {
        ++callsBuyBond;

        address holder = holders[actorSeed % holders.length];
        BuyBondParams memory p = _readBuyBondParams();

        // Early returns for invalid states
        if (!p.isActive) return;
        if (p.issueSize < p.minimumValueToAccept) return;
        if (holder.balance == 0) return;

        // Clamp duration
        uint32 dur = uint32(bound(duration, p.minimumDuration, p.maximumDuration));

        // Compute max affordable amount (inverse of interest formula)
        uint256 numerator = uint256(p.issueSize) * uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR);
        uint256 denominator = uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR) + uint256(p.interestRate) * uint256(dur);
        // forge-lint: disable-next-line(unsafe-typecast) bounded by issueSize which is uint128
        uint128 maxAmt = uint128(numerator / denominator);

        // Clamp amount
        uint128 upperBound = maxAmt < uint128(holder.balance) ? maxAmt : uint128(holder.balance);
        if (upperBound < p.minimumValueToAccept) return;
        uint128 amt = uint128(bound(amount, p.minimumValueToAccept, upperBound));

        // Verify amountWithInterest fits
        uint128 amountWithInterest = uint128(amt + Interest.calculateInterest(amt, dur, p.interestRate));
        if (amountWithInterest > p.issueSize) return;

        // Buy the bond
        vm.recordLogs();
        vm.prank(holder);
        coffer.buyBond{value: amt}(dur, p.version);

        uint256 bondId = _extractBondIdFromLogs();

        // Update ghost state
        ghostActiveBondIds.push(bondId);
        ghostIsBondActive[bondId] = true;
        ghostBondHolder[bondId] = holder;
        ghostBondAmount[bondId] = amountWithInterest;
        ++ghostTotalBondsBought;
    }

    function handlerHolderWithdrawFromExecution(uint256 idSeed) external {
        ++callsHolderWithdrawFromExecution;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        // Read on-chain holder conditions
        (uint128 amount, uint32 duration, uint32 startTimestamp,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;

        // Check maturity
        if (uint256(duration) + uint256(startTimestamp) > block.timestamp) return;

        // Allow both full and partial paths
        uint256 balance = address(coffer).balance;
        if (balance == 0) return;

        vm.prank(holder);
        coffer.holderWithdrawFromExecution(bondId);

        // Re-read on-chain amount after withdrawal to determine what happened
        (uint128 amountAfter,,,) = coffer.sHolderConditions(bondId);

        if (amountAfter == 0) {
            // Full withdrawal — remove from active
            ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
            ghostActiveBondIds.pop();
            ghostIsBondActive[bondId] = false;
            delete ghostBondHolder[bondId];
            delete ghostBondAmount[bondId];
            ghostHasPendingConsensusWithdrawal[bondId] = false;
            ++ghostTotalBondsWithdrawnExecution;
        } else {
            // Partial withdrawal — update ghost amount, keep active
            uint128 withdrawn = amount - amountAfter;
            ghostBondAmount[bondId] -= withdrawn;
        }
    }

    function handlerHolderWithdrawFromConsensus(uint256 idSeed) external {
        ++callsHolderWithdrawFromConsensus;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        // Read on-chain holder conditions
        (uint128 amount, uint32 duration, uint32 startTimestamp,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;

        // Check maturity
        if (uint256(duration) + uint256(startTimestamp) > block.timestamp) return;

        // Must NOT have enough balance (opposite of execution path)
        if (address(coffer).balance >= amount) return;

        // Prevent double-submission
        if (ghostHasPendingConsensusWithdrawal[bondId]) return;

        // Get EIP-7002 fee
        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) return;
        // forge-lint: disable-next-line(unsafe-typecast) fee data is always 32 bytes
        uint256 fee = uint256(bytes32(feeData));

        // Check holder can afford the fee
        if (holder.balance < fee) return;

        vm.prank(holder);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);

        // Push pending withdrawal
        ghostPendingWithdrawals.push(
            PendingWithdrawal({
                bondId: bondId, amount: amount, arrivalTime: block.timestamp + EXIT_QUEUE_DELAY, holderAddress: holder
            })
        );
        ghostHasPendingConsensusWithdrawal[bondId] = true;
        ++ghostTotalBondsWithdrawnConsensus;
    }

    function handlerSimulateEthArrival() external {
        ++callsSimulateEthArrival;

        uint256 len = ghostPendingWithdrawals.length;
        if (len == 0) return;

        // Iterate backwards for safe swap-and-pop
        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            PendingWithdrawal memory pw = ghostPendingWithdrawals[idx];

            if (block.timestamp >= pw.arrivalTime) {
                // Deliver ETH to coffer
                vm.deal(address(coffer), address(coffer).balance + pw.amount);

                ghostHasPendingConsensusWithdrawal[pw.bondId] = false;
                ghostTotalEthArrivedFromConsensus += pw.amount;

                // Swap-and-pop
                ghostPendingWithdrawals[idx] = ghostPendingWithdrawals[ghostPendingWithdrawals.length - 1];
                ghostPendingWithdrawals.pop();
            }
        }
    }

    function handlerRedeemBondsEarly(uint256 idSeed) external {
        ++callsRedeemBondsEarly;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];

        // Read on-chain amount
        (uint128 amount,,,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;

        // Calculate top-up needed
        uint256 contractBalance = address(coffer).balance;
        uint256 topUp = 0;
        if (amount > contractBalance) {
            topUp = amount - contractBalance;
        }

        // Check validator can afford top-up
        if (validator.balance < topUp) return;

        uint256[] memory bondIds = new uint256[](1);
        bondIds[0] = bondId;

        vm.prank(validator);
        coffer.redeemBondsEarly{value: topUp}(bondIds);

        // Swap-and-pop from ghostActiveBondIds
        ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
        ghostActiveBondIds.pop();

        ghostIsBondActive[bondId] = false;
        delete ghostBondHolder[bondId];
        delete ghostBondAmount[bondId];
        ghostHasPendingConsensusWithdrawal[bondId] = false;
        ++ghostTotalBondsRedeemed;
    }

    function handlerValidatorWithdrawFromExecution(uint256 amount) external {
        ++callsValidatorWithdrawFromExecution;

        (uint128 issueSize,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();

        uint256 contractBalance = address(coffer).balance;
        if (contractBalance == 0) return;

        if (outstandingBonds > 0) {
            // Bounded withdrawal: capped by issueSize and balance - consensusReserved
            if (issueSize == 0) return;
            uint128 consensusReserved = coffer.totalConsensusReserved();
            uint256 maxByBalance = contractBalance > consensusReserved ? contractBalance - consensusReserved : 0;
            if (maxByBalance == 0) return;

            uint256 maxWithdraw = issueSize < maxByBalance ? issueSize : maxByBalance;
            uint128 amt = uint128(bound(amount, 1, maxWithdraw));

            vm.prank(validator);
            coffer.validatorWithdrawFromExecution(amt);
        } else {
            // No bonds — free withdrawal
            uint128 amt = uint128(bound(amount, 1, contractBalance));

            vm.prank(validator);
            coffer.validatorWithdrawFromExecution(amt);
        }
    }

    function handlerSendEthToCoffer(uint256 amount) external {
        ++callsSendEthToCoffer;

        // Bound to reasonable range
        uint128 amt = uint128(bound(amount, 0.01 ether, 10 ether));

        // Pick a random holder to send from
        address sender = holders[amount % holders.length];
        if (sender.balance < amt) return;

        vm.prank(sender);
        (bool success,) = address(coffer).call{value: amt}("");
        if (!success) return;
    }

    function handlerValidatorAddFundsToConsensus(uint256 amount) external {
        ++callsValidatorAddFundsToConsensus;

        // Clamp amount to [1 ether, 100 ether], round down to gwei multiple
        uint128 amt = uint128(bound(amount, 1 ether, 100 ether));

        // casting to 'uint128' is safe because bounds are intorduced
        // forge-lint: disable-next-line(unsafe-typecast) bounded to [1 ether, 100 ether] fits uint128
        amt = uint128((amt * GWEI_RATE) / GWEI_RATE);
        if (amt < 1 ether) amt = 1 ether;

        // Check validator can afford it
        if (validator.balance < amt) return;

        // Reconstruct the deposit_data_root exactly as the DepositContract does
        bytes memory pubkey = abi.encodePacked(coffer.iPublicKeyPart1(), coffer.iPublicKeyPart2());
        // forge-lint: disable-next-line(unsafe-typecast) bounded by validator balance
        bytes memory amountLe = _toLittleEndian64(uint64(uint256(amt) / 1 gwei));

        bytes32 pubkeyRoot = sha256(abi.encodePacked(pubkey, bytes16(0)));

        // signature is 96 zero bytes; split into first 64 and last 32
        bytes memory sigFirst64 = new bytes(64);
        bytes memory sigLast32 = new bytes(32);
        bytes32 signatureRoot =
            sha256(abi.encodePacked(sha256(sigFirst64), sha256(abi.encodePacked(sigLast32, bytes32(0)))));

        // withdrawal_credentials is 32 zero bytes = bytes32(0)
        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkeyRoot, bytes32(0))),
                sha256(abi.encodePacked(amountLe, bytes24(0), signatureRoot))
            )
        );

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: amt}(depositDataRoot);
    }

    function handlerChangeCofferActivity() external {
        ++callsChangeCofferActivity;

        vm.prank(validator);
        coffer.changeCofferActivity();
    }

    function handlerChangeInterestRate(uint256 rate) external {
        ++callsChangeInterestRate;

        uint32 newRate = uint32(bound(rate, 1, MAX_RATE));

        // Read current conditions
        (, uint32 currentRate,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();

        // Cannot increase rate while outstanding bonds exist
        if (newRate >= currentRate && outstandingBonds != 0) return;

        vm.prank(validator);
        coffer.changeInterestRate(newRate);
    }

    function handlerChangeIssueSize(uint256 amount) external {
        ++callsChangeIssueSize;

        // Read conditions
        (,,,, uint128 minimumValueToAccept,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();

        if (outstandingBonds != 0) return;
        if (minimumValueToAccept == 0) return;

        uint128 amt = uint128(bound(amount, minimumValueToAccept, 1000 ether));

        vm.prank(validator);
        coffer.changeIssueSize(amt);
    }

    function handlerAdvanceTime(uint256 seconds_) external {
        ++callsAdvanceTime;

        uint256 advance = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + advance);
    }

    // ══════════════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function getActiveBondIdsLength() external view returns (uint256) {
        return ghostActiveBondIds.length;
    }

    function getActiveBondIdAt(uint256 index) external view returns (uint256) {
        return ghostActiveBondIds[index];
    }

    function getPendingWithdrawalsLength() external view returns (uint256) {
        return ghostPendingWithdrawals.length;
    }
}
