//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {CofferBondNft} from "../../../src/CofferBondNft.sol";
import {CofferBondsRedeemedEarly} from "../../../src/CofferBondsRedeemedEarly.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";
import {Interest} from "../../../src/libraries/Interest.sol";

contract CofferHandlerExt is Test {
    uint256 constant MAX_RATE = 1e8;
    uint256 constant GWEI_RATE = 1e9;
    uint256 constant SECONDS_IN_YEAR = 31_536_000;
    uint256 constant BUFFER_DENOMINATOR = 10000;
    uint256 constant MAX_DURATION = 1_576_800_000;

    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;

    uint256 constant EXIT_QUEUE_ETH = 500_500 ether;
    uint256 constant ETH_PER_EPOCH = 256 ether;
    uint16 constant SECONDS_PER_EPOCH = 384;
    uint256 constant EXIT_QUEUE_DELAY = (EXIT_QUEUE_ETH * SECONDS_PER_EPOCH) / ETH_PER_EPOCH;

    struct PendingWithdrawal {
        uint256 bondId;
        uint128 amount;
        uint256 arrivalTime;
        address holderAddress;
    }

    Coffer public coffer;
    CofferBondNft public bondNft;
    CofferBondsRedeemedEarly public bondsRedeemedEarly;
    FeeCurve public feeCurve;

    address public validator;
    address[] public holders;

    uint128 public ghostIssueSize;
    uint128 public ghostConsensusBalance;
    uint128 public ghostTotalConsensusReserved;

    uint256[] public ghostActiveBondIds;
    mapping(uint256 => bool) public ghostIsBondActive;
    mapping(uint256 => address) public ghostBondHolder;
    mapping(uint256 => uint128) public ghostBondMaturityValue;
    mapping(uint256 => uint128) public ghostPrincipal;
    mapping(uint256 => uint128) public ghostExecutionWithdrawn;
    mapping(uint256 => bool) public ghostConsensusWithdrawClosed;
    PendingWithdrawal[] public ghostPendingWithdrawals;

    uint256 public ghostTotalBondsBought;
    uint256 public ghostTotalBondsRedeemed;
    uint256 public ghostTotalBondsWithdrawnExecution;
    uint256 public ghostTotalBondsWithdrawnConsensus;
    uint256 public ghostTotalEthArrivedFromConsensus;

    uint256 public callsBuyBond;
    uint256 public callsHolderWithdrawFromExecution;
    uint256 public callsHolderWithdrawFromConsensus;
    uint256 public callsSimulateEthArrival;
    uint256 public callsRedeemBondsEarly;
    uint256 public callsValidatorWithdrawFromExecution;
    uint256 public callsValidatorWithdrawFromConsensus;
    uint256 public callsValidatorAddFundsToConsensus;
    uint256 public callsConvertToCompounding;
    uint256 public callsChangeCofferActivity;
    uint256 public callsChangeInterestRate;
    uint256 public callsChangeIssueSize;
    uint256 public callsChangeIssueSizeBufferBps;
    uint256 public callsChangeMinimumAndMaximumDuration;
    uint256 public callsChangeMinimumValueToAccept;
    uint256 public callsChangeExitAllowed;
    uint256 public callsAdvanceTime;
    uint256 public callsSendEthToCoffer;

    constructor(
        Coffer _coffer,
        CofferBondNft _bondNft,
        CofferBondsRedeemedEarly _bondsRedeemedEarly,
        FeeCurve _feeCurve
    ) {
        coffer = _coffer;
        bondNft = _bondNft;
        bondsRedeemedEarly = _bondsRedeemedEarly;
        feeCurve = _feeCurve;
        validator = _coffer.owner();

        holders.push(makeAddr("extHolder0"));
        holders.push(makeAddr("extHolder1"));
        holders.push(makeAddr("extHolder2"));
        holders.push(makeAddr("extHolder3"));
        holders.push(makeAddr("extHolder4"));
        for (uint256 i = 0; i < holders.length; i++) {
            vm.deal(holders[i], 1000 ether);
        }

        ghostIssueSize = _readVc().issueSize;
        ghostConsensusBalance = 0;
        ghostTotalConsensusReserved = 0;
    }

    // One-shot: setUp seeds the modeled consensus stake exactly once. Guarded because
    // targetContract(handler) exposes every external function to the invariant fuzzer, which would
    // otherwise call this with a fuzzed value and corrupt ghostConsensusBalance (breaking the
    // cross-layer solvency check). Fuzzer calls after the initial seed are no-ops.
    bool private consensusSeeded;

    function seedConsensusBalance(uint128 _balance) external {
        if (consensusSeeded) return;
        consensusSeeded = true;
        ghostConsensusBalance = _balance;
    }

    // ══════════════════════════════════════════════════════════════════════
    // INTERNAL: read full ValidatorConditions struct
    // ══════════════════════════════════════════════════════════════════════
    struct Vc {
        uint128 issueSize;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumValueToAccept;
        uint32 version;
        uint32 outstandingBonds;
        uint16 issueSizeBufferBps;
        bool isActive;
        bool exitAllowed;
    }

    function _readVc() private view returns (Vc memory v) {
        // Split reads across two calls to avoid stack-too-deep
        (v.issueSize, v.interestRate, v.minimumDuration, v.maximumDuration, v.minimumValueToAccept) = _readVc1();
        (v.version, v.outstandingBonds, v.issueSizeBufferBps, v.isActive, v.exitAllowed) = _readVc2();
    }

    function _readVc1() private view returns (uint128, uint32, uint32, uint32, uint128) {
        (uint128 a, uint32 b, uint32 c, uint32 d, uint128 e,,,,,) = coffer.sValidatorConditions();
        return (a, b, c, d, e);
    }

    function _readVc2() private view returns (uint32, uint32, uint16, bool, bool) {
        (,,,,, uint32 a, uint32 b, uint16 c, bool d, bool e) = coffer.sValidatorConditions();
        return (a, b, c, d, e);
    }

    function _extractBondIdFromLogs() private returns (uint256 bondId) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("BondBought(address,uint256,uint128,uint32,uint128,uint32)")) {
                return uint256(entries[i].topics[2]);
            }
        }
    }

    function _toLittleEndian64(uint64 value) private pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 val = bytes8(value);
        ret[0] = val[7];
        ret[1] = val[6];
        ret[2] = val[5];
        ret[3] = val[4];
        ret[4] = val[3];
        ret[5] = val[2];
        ret[6] = val[1];
        ret[7] = val[0];
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: buyBond
    // ══════════════════════════════════════════════════════════════════════
    function handlerBuyBond(uint256 actorSeed, uint256 amount, uint256 duration) external {
        ++callsBuyBond;
        address holder = holders[actorSeed % holders.length];
        Vc memory vc = _readVc();

        if (!vc.isActive) return;
        if (vc.issueSize < vc.minimumValueToAccept) return;
        if (holder.balance == 0) return;

        uint32 dur = uint32(bound(duration, vc.minimumDuration, vc.maximumDuration));

        uint256 numerator = uint256(vc.issueSize) * uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR);
        uint256 denominator = uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR) + uint256(vc.interestRate) * uint256(dur);
        // casting to 'uint128' is safe because result stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 maxPrincipal = uint128(numerator / denominator);

        uint128 upperBound = maxPrincipal < uint128(holder.balance) ? maxPrincipal : uint128(holder.balance);
        if (upperBound < vc.minimumValueToAccept) return;
        uint128 amt = uint128(bound(amount, vc.minimumValueToAccept, upperBound));

        uint256 interest = Interest.calculateInterest(amt, dur, vc.interestRate);
        (uint256 feeBps,) = feeCurve.getFee();
        uint256 fee = (interest * feeBps) / BUFFER_DENOMINATOR;
        if (fee >= amt + 1) return;

        uint256 computedBondMaturityValue = amt + interest - fee;
        if (computedBondMaturityValue > vc.issueSize) return;

        vm.recordLogs();
        vm.prank(holder);
        coffer.buyBond{value: amt}(dur, vc.version);

        uint256 bondId = _extractBondIdFromLogs();

        ghostActiveBondIds.push(bondId);
        ghostIsBondActive[bondId] = true;
        ghostBondHolder[bondId] = holder;
        // casting to 'uint128' is safe because computedBondMaturityValue fits inside consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostBondMaturityValue[bondId] = uint128(computedBondMaturityValue);
        ghostPrincipal[bondId] = amt;
        ghostConsensusWithdrawClosed[bondId] = false;
        ++ghostTotalBondsBought;
        // casting to 'uint128' is safe because computedBondMaturityValue fits inside consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostIssueSize -= uint128(computedBondMaturityValue);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: holderWithdrawFromExecution
    // ══════════════════════════════════════════════════════════════════════
    function handlerHolderWithdrawFromExecution(uint256 idSeed) external {
        ++callsHolderWithdrawFromExecution;
        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        (uint128 amount, uint32 _duration, uint32 startTimestamp,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;
        // forge-lint: disable-next-line
        if (uint256(_duration) + uint256(startTimestamp) > block.timestamp) return;
        if (address(coffer).balance == 0) return;

        vm.prank(holder);
        coffer.holderWithdrawFromExecution(bondId);

        (uint128 amountAfter,,,) = coffer.sHolderConditions(bondId);

        if (amountAfter == 0) {
            ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
            ghostActiveBondIds.pop();
            ghostIsBondActive[bondId] = false;
            // Full withdrawal deletes the on-chain struct, so its consensusWithdrawClosed flag
            // reads back false. Rely on the ghost flag (kept in lockstep with the on-chain flag
            // in handlerHolderWithdrawFromConsensus) to mirror the contract's reserved decrement.
            if (ghostConsensusWithdrawClosed[bondId]) {
                ghostTotalConsensusReserved -= ghostBondMaturityValue[bondId];
            }
            delete ghostBondHolder[bondId];
            delete ghostBondMaturityValue[bondId];
            delete ghostPrincipal[bondId];
            delete ghostExecutionWithdrawn[bondId];
            delete ghostConsensusWithdrawClosed[bondId];
            ++ghostTotalBondsWithdrawnExecution;
        } else {
            uint128 withdrawn = amount - amountAfter;
            ghostBondMaturityValue[bondId] -= withdrawn;
            ghostExecutionWithdrawn[bondId] += withdrawn;
            if (ghostConsensusWithdrawClosed[bondId]) {
                ghostTotalConsensusReserved -= withdrawn;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: holderWithdrawFromConsensus
    // ══════════════════════════════════════════════════════════════════════
    function handlerHolderWithdrawFromConsensus(uint256 idSeed) external {
        ++callsHolderWithdrawFromConsensus;
        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        (uint128 amount, uint32 _duration, uint32 startTimestamp, bool alreadyClosed) = coffer.sHolderConditions(bondId);
        if (amount == 0 || alreadyClosed) return;
        // forge-lint: disable-next-line
        if (uint256(_duration) + uint256(startTimestamp) > block.timestamp) return;
        if (ghostConsensusWithdrawClosed[bondId]) return;

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));
        if (holder.balance < fee) return;

        uint256 preCallBalance = address(coffer).balance;
        uint128 reservedBefore = coffer.totalConsensusReserved();
        bool fallbackPath = preCallBalance >= uint256(amount) + uint256(reservedBefore);

        vm.prank(holder);
        coffer.holderWithdrawFromConsensus{value: fee}(bondId);

        ghostConsensusWithdrawClosed[bondId] = true;
        ghostTotalConsensusReserved += amount;
        ++ghostTotalBondsWithdrawnConsensus;

        if (!fallbackPath) {
            ghostPendingWithdrawals.push(
                PendingWithdrawal({
                    bondId: bondId,
                    amount: amount,
                    arrivalTime: block.timestamp + EXIT_QUEUE_DELAY,
                    holderAddress: holder
                })
            );
            ghostConsensusBalance = ghostConsensusBalance > amount ? ghostConsensusBalance - amount : 0;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: simulateEthArrival
    // ══════════════════════════════════════════════════════════════════════
    function handlerSimulateEthArrival() external {
        ++callsSimulateEthArrival;
        uint256 len = ghostPendingWithdrawals.length;
        if (len == 0) return;
        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            PendingWithdrawal memory pw = ghostPendingWithdrawals[idx];
            // forge-lint: disable-next-line
            if (block.timestamp >= pw.arrivalTime) {
                vm.deal(address(coffer), address(coffer).balance + pw.amount);
                ghostTotalEthArrivedFromConsensus += pw.amount;
                ghostPendingWithdrawals[idx] = ghostPendingWithdrawals[ghostPendingWithdrawals.length - 1];
                ghostPendingWithdrawals.pop();
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: redeemBondsEarly
    // ══════════════════════════════════════════════════════════════════════
    function handlerRedeemBondsEarly(uint256 idSeed) external {
        ++callsRedeemBondsEarly;
        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];

        (uint128 amount,,,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;

        uint256 topUp = amount > address(coffer).balance ? amount - address(coffer).balance : 0;
        if (validator.balance < topUp) return;

        uint256[] memory bondIds = new uint256[](1);
        bondIds[0] = bondId;

        vm.prank(validator);
        coffer.redeemBondsEarly{value: topUp}(bondIds);

        if (ghostConsensusWithdrawClosed[bondId]) {
            ghostTotalConsensusReserved -= ghostBondMaturityValue[bondId];
        }
        ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
        ghostActiveBondIds.pop();
        ghostIsBondActive[bondId] = false;
        delete ghostBondHolder[bondId];
        delete ghostBondMaturityValue[bondId];
        delete ghostPrincipal[bondId];
        delete ghostConsensusWithdrawClosed[bondId];
        ++ghostTotalBondsRedeemed;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorWithdrawFromExecution
    // ══════════════════════════════════════════════════════════════════════
    function handlerValidatorWithdrawFromExecution(uint256 amount) external {
        ++callsValidatorWithdrawFromExecution;
        Vc memory vc = _readVc();
        uint256 contractBalance = address(coffer).balance;
        if (contractBalance == 0) return;

        uint128 amt;
        if (vc.outstandingBonds > 0) {
            if (vc.issueSize == 0) return;
            uint128 reserved = coffer.totalConsensusReserved();
            uint256 maxByBalance = contractBalance > reserved ? contractBalance - reserved : 0;
            if (maxByBalance == 0) return;
            uint256 maxWithdraw = vc.issueSize < maxByBalance ? vc.issueSize : maxByBalance;
            amt = uint128(bound(amount, 1, maxWithdraw));
        } else {
            amt = uint128(bound(amount, 1, contractBalance));
        }

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(amt);

        if (vc.outstandingBonds > 0) {
            ghostIssueSize -= amt;
        } else {
            // With no bonds outstanding, the contract does NOT reduce issueSize (the validator keeps
            // their standing issuance capacity) even though execution balance leaves. Model the
            // reclaimed ETH as returning to the validator's consensus stake -- it still backs the
            // issueSize declaration -- so cross-layer solvency stays conserved across both layers.
            ghostConsensusBalance += amt;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorWithdrawFromConsensus
    // ══════════════════════════════════════════════════════════════════════
    function handlerValidatorWithdrawFromConsensus(uint256 amount) external {
        ++callsValidatorWithdrawFromConsensus;

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));
        if (validator.balance < fee) return;

        uint64 amtGwei = uint64(bound(amount, 0, 10_000_000));

        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: fee}(amtGwei);

        // casting to 'uint128' is safe because GWEI_RATE fits in uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amtWei = uint128(amtGwei) * uint128(GWEI_RATE);
        ghostConsensusBalance = ghostConsensusBalance > amtWei ? ghostConsensusBalance - amtWei : 0;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorAddFundsToConsensus
    // ══════════════════════════════════════════════════════════════════════
    function handlerValidatorAddFundsToConsensus(uint256 amount) external {
        ++callsValidatorAddFundsToConsensus;
        Vc memory vc = _readVc();

        // casting to 'uint128' is safe because bound result stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amt = uint128(bound(amount, 1 ether, 100 ether));
        // casting to 'uint128' is safe because result stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        amt = uint128((amt * GWEI_RATE) / GWEI_RATE);
        if (amt < 1 ether) amt = 1 ether;
        if (validator.balance < amt) return;

        bytes memory pubkey = abi.encodePacked(coffer.iPublicKeyPart1(), coffer.iPublicKeyPart2());
        // casting to 'uint64' is safe because amt/gwei stays within deposit contract limits
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory amountLe = _toLittleEndian64(uint64(uint256(amt) / 1 gwei));
        bytes32 pubkeyRoot = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes memory sigFirst64 = new bytes(64);
        bytes memory sigLast32 = new bytes(32);
        bytes32 signatureRoot =
            sha256(abi.encodePacked(sha256(sigFirst64), sha256(abi.encodePacked(sigLast32, bytes32(0)))));
        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkeyRoot, bytes32(0))),
                sha256(abi.encodePacked(amountLe, bytes24(0), signatureRoot))
            )
        );

        // casting to 'uint128' is safe because result stays within consensus limits
        uint128 issueSizeIncrement =
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128(uint256(amt) * (BUFFER_DENOMINATOR - uint256(vc.issueSizeBufferBps)) / BUFFER_DENOMINATOR);

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: amt}(depositDataRoot);

        ghostIssueSize += issueSizeIncrement;
        ghostConsensusBalance += amt;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: convertToCompounding
    // ══════════════════════════════════════════════════════════════════════
    function handlerConvertToCompounding() external {
        ++callsConvertToCompounding;
        address consolidation = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;
        (bool readOk, bytes memory feeData) = consolidation.staticcall("");
        if (!readOk) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));
        if (validator.balance < fee) return;
        vm.prank(validator);
        coffer.convertToCompounding{value: fee}();
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: sendEthToCoffer (receive)
    // ══════════════════════════════════════════════════════════════════════
    function handlerSendEthToCoffer(uint256 amount) external {
        ++callsSendEthToCoffer;
        uint128 amt = uint128(bound(amount, 0.01 ether, 10 ether));
        address sender = holders[amount % holders.length];
        if (sender.balance < amt) return;
        vm.prank(sender);
        (bool success,) = address(coffer).call{value: amt}("");
        if (!success) return;
        ghostIssueSize += amt;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeCofferActivity
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeCofferActivity() external {
        ++callsChangeCofferActivity;
        vm.prank(validator);
        coffer.changeCofferActivity();
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeInterestRate
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeInterestRate(uint256 rate) external {
        ++callsChangeInterestRate;
        uint32 newRate = uint32(bound(rate, 1, MAX_RATE));
        Vc memory vc = _readVc();
        if (newRate >= vc.interestRate && vc.outstandingBonds != 0) return;
        vm.prank(validator);
        coffer.changeInterestRate(newRate);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeIssueSize
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeIssueSize(uint256 amount) external {
        ++callsChangeIssueSize;
        Vc memory vc = _readVc();
        uint128 newIssueSize;
        if (vc.outstandingBonds == 0) {
            if (vc.minimumValueToAccept == 0) return;
            newIssueSize = uint128(bound(amount, vc.minimumValueToAccept, 1000 ether));
        } else {
            if (vc.issueSize <= vc.minimumValueToAccept) return;
            newIssueSize = uint128(bound(amount, vc.minimumValueToAccept, vc.issueSize - 1));
        }
        vm.prank(validator);
        coffer.changeIssueSize(newIssueSize);
        ghostIssueSize = newIssueSize;
        // Declaring a larger issueSize is the validator asserting issuance capacity that must be
        // backed by consensus-layer stake (issueSize = stake * (1 - buffer) <= stake). Model the
        // stake so cross-layer solvency reflects an honest, adequately-staked validator. We only
        // raise (never lower) the modeled stake; a lower issueSize keeps the prior stake.
        if (ghostConsensusBalance < newIssueSize) {
            ghostConsensusBalance = newIssueSize;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeIssueSizeBufferBps
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeIssueSizeBufferBps(uint256 bps) external {
        ++callsChangeIssueSizeBufferBps;
        Vc memory vc = _readVc();
        uint16 newBps;
        if (vc.outstandingBonds == 0) {
            newBps = uint16(bound(bps, 0, BUFFER_DENOMINATOR - 1));
        } else {
            if (vc.issueSizeBufferBps >= BUFFER_DENOMINATOR - 1) return;
            newBps = uint16(bound(bps, vc.issueSizeBufferBps + 1, BUFFER_DENOMINATOR - 1));
        }
        vm.prank(validator);
        coffer.changeIssueSizeBufferBps(newBps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeMinimumAndMaximumDuration
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeMinimumAndMaximumDuration(uint256 minSeed, uint256 maxSeed) external {
        ++callsChangeMinimumAndMaximumDuration;
        Vc memory vc = _readVc();

        uint32 newMin = uint32(bound(minSeed, 1, MAX_DURATION));
        uint32 newMax;
        if (vc.outstandingBonds == 0) {
            newMax = uint32(bound(maxSeed, newMin, MAX_DURATION));
        } else {
            if (vc.maximumDuration <= newMin) return;
            newMax = uint32(bound(maxSeed, newMin, vc.maximumDuration));
        }
        if (newMax < newMin) newMax = newMin;
        vm.prank(validator);
        coffer.changeMinimumAndMaximumDuration(newMin, newMax);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeMinimumValueToAccept
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeMinimumValueToAccept(uint256 value) external {
        ++callsChangeMinimumValueToAccept;
        uint128 newValue = uint128(bound(value, 0.01 ether, 100 ether));
        if (newValue == 0) return;
        vm.prank(validator);
        coffer.changeMinimumValueToAccept(newValue);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: changeExitAllowed
    // ══════════════════════════════════════════════════════════════════════
    function handlerChangeExitAllowed() external {
        ++callsChangeExitAllowed;
        Vc memory vc = _readVc();
        if (!vc.exitAllowed || vc.outstandingBonds == 0) {
            vm.prank(validator);
            coffer.changeExitAllowed();
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: advanceTime
    // ══════════════════════════════════════════════════════════════════════
    function handlerAdvanceTime(uint256 seconds_) external {
        ++callsAdvanceTime;
        uint256 advance = bound(seconds_, 1, 60 days);
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
