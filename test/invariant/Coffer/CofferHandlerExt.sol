//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";
import {CofferRedemptionEscrow} from "../../../src/CofferRedemptionEscrow.sol";
import {Interest} from "../../../src/libraries/Interest.sol";

contract CofferHandlerExt is Test {
    uint256 constant MAX_RATE = 1e8;
    uint256 constant GWEI_RATE = 1e9;
    uint256 constant SECONDS_IN_YEAR = 31_536_000;
    uint256 constant BUFFER_DENOMINATOR = 10000;
    uint256 constant MAX_DURATION = 1_576_800_000;

    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;

    // Models the wall-clock between an EIP-7002 request landing on-chain and its ETH arriving at
    // the withdrawal-credential address: exit/withdrawal queue plus withdrawability delay plus the
    // beacon sweep, ~8.7 days at a 500k ETH queue.
    uint256 constant EXIT_QUEUE_ETH = 500_000 ether;
    uint256 constant ETH_PER_EPOCH = 256 ether;
    uint16 constant SECONDS_PER_EPOCH = 384;
    uint256 constant EXIT_QUEUE_DELAY = (EXIT_QUEUE_ETH * SECONDS_PER_EPOCH) / ETH_PER_EPOCH;

    struct PendingWithdrawal {
        uint128 amount;
        uint256 arrivalTime;
    }

    // Snapshot of one validatorRedeemBonds batch, kept in memory to stay clear of stack limits.
    struct RedeemBatch {
        uint256[] bondIds;
        uint128[] amounts;
        uint256 total;
        address[] owners;
        uint256[] expectedCredit;
        uint256[] pendingBefore;
        uint256 ownerCount;
        uint256 balanceBefore;
        uint256 escrowBefore;
        uint256 msgValue;
        uint32 outstandingBefore;
        uint128 issueSizeBefore;
    }

    Coffer public coffer;
    FeeCurve public feeCurve;
    CofferRedemptionEscrow public redemptionEscrow;

    address public validator;
    address[] public holders;

    uint128 public ghostIssueSize;
    uint128 public ghostConsensusBalance;

    uint256[] public ghostActiveBondIds;
    // Append-only: every id this coffer ever minted, never popped, so the all-ids invariants visit settled ids too.
    uint256[] public ghostAllBondIds;
    mapping(uint256 => bool) public ghostIsBondActive;
    mapping(uint256 => address) public ghostBondHolder;
    mapping(uint256 => uint128) public ghostBondMaturityValue;
    mapping(uint256 => uint128) public ghostPrincipal;
    mapping(uint256 => uint128) public ghostExecutionWithdrawn;
    // Promise ledger. Set or accumulated once and never deleted, so settled ids stay checkable:
    // the value stored at issuance, the wei the two holder paths delivered (measured on the wallet), and the
    // wei validatorRedeemBonds credited to the owner in the escrow (measured on sPendingClaims).
    mapping(uint256 => uint128) public ghostIssuedMaturityValue;
    mapping(uint256 => uint128) public ghostPaidDirect;
    mapping(uint256 => uint128) public ghostEscrowCredited;
    // Escrow ledger: every wei validatorRedeemBonds forwarded to the escrow, and every wei claimed
    // back from it.
    uint256 public ghostTotalEscrowedValue;
    uint256 public ghostTotalEscrowClaimed;
    // Set when a batch credits an owner by other than the sum of that owner's remainders, moves other than the
    // batch total, touches issueSize, or a claim pays other than the pending amount. Asserted false by
    // invariant_escrowCreditsAndClaimsExact.
    bool public ghostEscrowViolation;
    // Terms frozen at purchase: the duration as passed and the startTimestamp observed at the buy,
    // never deleted.
    mapping(uint256 => uint32) public ghostBondDuration;
    mapping(uint256 => uint32) public ghostBondStart;
    PendingWithdrawal[] public ghostPendingWithdrawals;

    uint256 public ghostTotalBondsBought;
    uint256 public ghostTotalBondsRedeemed;
    uint256 public ghostTotalBondsWithdrawnExecution;
    uint256 public ghostTotalEthArrivedFromConsensus;

    // ── Ghost state: default machine ───────────────────────────────────────
    // Mirrors the on-chain flag both ways: set by handlerDeclareDefault or handlerHolderRedeemBondOrDefault
    // on a successful declare, cleared by handlerClearDefault on a successful clear.
    // A default epoch is the span between one flip to true and the matching clear.
    bool public ghostValidatorDefaulted;
    // Set if a declare ever SUCCEEDS while the pre-call balance covered the bond. Handler-side
    // asserts would be masked under fail_on_revert = false, so violations are recorded here and
    // asserted by invariant_coveredBondNeverDefaulted.
    bool public ghostDefaultViolation;
    // Set when a declaration or an early redeem lands where the predicate forbids it, or the revert carries an
    // unexpected selector (the probe half of the default predicate). Asserted false by
    // invariant_defaultPredicateRefused.
    bool public ghostDeclareViolation;
    // Set when a setter loosens a protected parameter while bonds are outstanding, or the contract accepts a
    // loosening move it must refuse. Asserted false by
    // invariant_parameterMonotonicityWhileBondsOutstanding.
    bool public ghostParamViolation;
    // Epoch snapshots, re-baselined by handlerDeclareDefault at every flip to true. The post-default
    // invariants early-out while the flag is down, so between-epoch flows need no attribution.
    uint256 public ghostBondsAtDefault;
    uint256 public ghostBoughtAtDefault;
    uint256 public ghostBalanceAtDefault;
    uint128 public ghostConsensusAtDefault;
    uint256 public ghostTotalDefaultsDeclared;
    uint256 public ghostTotalDefaultsCleared;
    // Epoch ledger: every wei entering/leaving the contract balance within the current default epoch,
    // attributed by cause and zeroed at each flip to true.
    // Inflows: receive() tops, consensus arrivals, exit-fee surpluses (none: exact fee).
    // Outflows: holder claim payouts and validatorRedeemBonds net escrow spend.
    uint256 public ghostBalanceInflowsSinceDefault;
    uint256 public ghostBalanceOutflowsSinceDefault;
    // Whole-run balance ledger: the balance at construction plus every attributed inflow minus
    // every attributed outflow, each booked as the amount the code intends, never re-baselined. Inflows: receive()
    // tops, modeled consensus arrivals, validatorRedeemBonds msg.value, the predeploy surplus msg.value - fee (zero
    // today). Outflows: holder payouts (the record delta), execution withdrawals, the total forwarded to the escrow.
    uint256 public ghostBalanceBase;
    uint256 public ghostBalanceInflows;
    uint256 public ghostBalanceOutflows;
    // Set when a permissionless call (receive, buyBond, declareDefault, exitValidator) lowered the balance or a
    // call that transfers nothing moved it. Asserted false by invariant_permissionlessCallsNeverLowerBalance.
    bool public ghostBalanceViolation;
    // Set when a plain transfer to the coffer fails, the documented cure path closing. The model
    // never reaches the uint128 ceiling of issueSize, so the flag must stay false.
    bool public ghostTopUpReverted;
    // Exit-sweep model: the stake moves into in-transit at most once per default epoch; the latch
    // resets when the default clears so a later epoch can sweep whatever stake the model has accrued since.
    bool public ghostExitSweepQueued;
    // Version ledger: version == base + bumps, one bump per successful call of the six bumping
    // functions. The terms tuple is re-read only at a bump, so any drift without a bump fails
    // invariant_termsBoundToVersion. minimumValueToAccept and isActive are excluded by design: their setters do
    // not bump.
    uint32 public ghostVersionBase;
    uint256 public ghostVersionBumps;
    uint32 public ghostTermsRate;
    uint32 public ghostTermsMinDur;
    uint32 public ghostTermsMaxDur;
    uint16 public ghostTermsBuffer;

    uint256 public callsBuyBond;
    uint256 public callsHolderRedeemBondOrDefault;
    uint256 public callsHolderRedeemBondInDefault;
    uint256 public callsSimulateEthArrival;
    uint256 public callsValidatorRedeemBonds;
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
    uint256 public callsAdvanceTime;
    uint256 public callsSendEthToCoffer;
    uint256 public callsDeclareDefault;
    uint256 public callsExitValidator;
    uint256 public callsClearDefault;
    uint256 public callsEscrowClaim;
    uint256 public callsDeclareDefaultInvalid;
    uint256 public callsParameterLoosenInvalid;

    constructor(Coffer _coffer, FeeCurve _feeCurve) {
        coffer = _coffer;
        feeCurve = _feeCurve;
        validator = _coffer.owner();
        redemptionEscrow = CofferRedemptionEscrow(_coffer.iCofferRedemptionEscrowAddress());
        ghostBalanceBase = address(_coffer).balance;

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

        Vc memory v0 = _readVc();
        ghostVersionBase = v0.version;
        ghostTermsRate = v0.interestRate;
        ghostTermsMinDur = v0.minimumDuration;
        ghostTermsMaxDur = v0.maximumDuration;
        ghostTermsBuffer = v0.issueSizeBufferBps;
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
        bool validatorDefaulted;
    }

    function _readVc() private view returns (Vc memory v) {
        // Split reads across two calls to avoid stack-too-deep
        (v.issueSize, v.interestRate, v.minimumDuration, v.maximumDuration, v.minimumValueToAccept) = _readVc1();
        (v.version, v.outstandingBonds, v.issueSizeBufferBps, v.isActive, v.validatorDefaulted) = _readVc2();
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

        // buyBond is frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

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

        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.recordLogs();
        vm.prank(holder);
        coffer.buyBond{value: amt}(dur, vc.version);
        // The principal leaves in the same call, the fee too, so the coffer keeps nothing of msg.value
        if (address(coffer).balance != cofferBalanceBefore) ghostBalanceViolation = true;

        uint256 bondId = _extractBondIdFromLogs();

        ghostActiveBondIds.push(bondId);
        ghostAllBondIds.push(bondId);
        ghostIsBondActive[bondId] = true;
        ghostBondHolder[bondId] = holder;
        // casting to 'uint128' is safe because computedBondMaturityValue fits inside consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostBondMaturityValue[bondId] = uint128(computedBondMaturityValue);
        ghostIssuedMaturityValue[bondId] = ghostBondMaturityValue[bondId];
        ghostPrincipal[bondId] = amt;
        ghostBondDuration[bondId] = dur;
        // casting to 'uint32' is safe because block.timestamp fits uint32 until 2106, the contract's own cast
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostBondStart[bondId] = uint32(block.timestamp);
        ++ghostTotalBondsBought;
        // casting to 'uint128' is safe because computedBondMaturityValue fits inside consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostIssueSize -= uint128(computedBondMaturityValue);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: holderRedeemBondOrDefault (serving-state: full payout or atomic default)
    // ══════════════════════════════════════════════════════════════════════
    function handlerHolderRedeemBondOrDefault(uint256 idSeed) external {
        ++callsHolderRedeemBondOrDefault;

        if (ghostValidatorDefaulted) return;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        (uint128 amount, uint32 _duration, uint32 startTimestamp) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;
        // Maturity is required while serving
        // forge-lint: disable-next-line
        if (uint256(_duration) + uint256(startTimestamp) > block.timestamp) return;

        // If the shortfall path defaults although the bond was covered, record the
        // violation instead of asserting (asserts would be masked under fail_on_revert=false)
        bool coveredBeforeCall = address(coffer).balance >= amount;
        uint256 holderBalanceBefore = holder.balance;
        uint256 cofferBalanceBefore = address(coffer).balance;

        vm.prank(holder);
        bool paidInFull = coffer.holderRedeemBondOrDefault(bondId);

        if (paidInFull) {
            // casting to 'uint128' is safe because a payout never exceeds the uint128 maturity value
            // forge-lint: disable-next-line(unsafe-typecast)
            ghostPaidDirect[bondId] += uint128(holder.balance - holderBalanceBefore);
            ghostBalanceOutflows += amount;
            ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
            ghostActiveBondIds.pop();
            ghostIsBondActive[bondId] = false;
            delete ghostBondHolder[bondId];
            delete ghostBondMaturityValue[bondId];
            delete ghostPrincipal[bondId];
            delete ghostExecutionWithdrawn[bondId];
            ++ghostTotalBondsWithdrawnExecution;
        } else {
            // Shortfall: the default was declared atomically in the same transaction, nothing moved.
            if (address(coffer).balance != cofferBalanceBefore) ghostBalanceViolation = true;
            _recordDefaultFlip(coveredBeforeCall);
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: holderRedeemBondInDefault (defaulted-state claim, no maturity check)
    // ══════════════════════════════════════════════════════════════════════
    function handlerHolderRedeemBondInDefault(uint256 idSeed) external {
        ++callsHolderRedeemBondInDefault;

        if (!ghostValidatorDefaulted) return;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];
        address holder = ghostBondHolder[bondId];

        (uint128 amount,,) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;
        // The zero balance reverts (NothingToRedeem)
        if (address(coffer).balance == 0) return;
        uint256 holderBalanceBefore = holder.balance;

        vm.prank(holder);
        coffer.holderRedeemBondInDefault(bondId);

        (uint128 amountAfter,,) = coffer.sHolderConditions(bondId);
        uint128 paidOut = amount - amountAfter;
        ghostBalanceOutflowsSinceDefault += paidOut;
        ghostBalanceOutflows += paidOut;
        // casting to 'uint128' is safe because a payout never exceeds the uint128 maturity value
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostPaidDirect[bondId] += uint128(holder.balance - holderBalanceBefore);

        if (amountAfter == 0) {
            ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
            ghostActiveBondIds.pop();
            ghostIsBondActive[bondId] = false;
            delete ghostBondHolder[bondId];
            delete ghostBondMaturityValue[bondId];
            delete ghostPrincipal[bondId];
            delete ghostExecutionWithdrawn[bondId];
            ++ghostTotalBondsWithdrawnExecution;
        } else {
            ghostBondMaturityValue[bondId] -= paidOut;
            ghostExecutionWithdrawn[bondId] += paidOut;
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
                ghostBalanceInflows += pw.amount;
                if (ghostValidatorDefaulted) ghostBalanceInflowsSinceDefault += pw.amount;
                ghostPendingWithdrawals[idx] = ghostPendingWithdrawals[ghostPendingWithdrawals.length - 1];
                ghostPendingWithdrawals.pop();
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorRedeemBonds
    // ══════════════════════════════════════════════════════════════════════
    /// @dev Settles 1 to 3 distinct active ids in one call, a shared owner allowed, with a bounded msg.value
    ///      surplus above the shortfall. Strict-safe: every id comes from the active list, so no
    ///      record is zero and no id repeats, and msg.value covers the batch total.
    function handlerValidatorRedeemBonds(uint256 idSeed, uint256 countSeed, uint256 surplusSeed) external {
        ++callsValidatorRedeemBonds;
        if (ghostActiveBondIds.length == 0) return;

        RedeemBatch memory b = _pickRedeemBatch(idSeed, countSeed);
        for (uint256 j = 0; j < b.amounts.length; j++) {
            if (b.amounts[j] == 0) return;
        }
        uint256 topUp = b.total > b.balanceBefore ? b.total - b.balanceBefore : 0;
        b.msgValue = topUp + bound(surplusSeed, 0, 0.1 ether);
        if (validator.balance < b.msgValue) return;

        vm.prank(validator);
        coffer.validatorRedeemBonds{value: b.msgValue}(b.bondIds);

        _checkRedeemBatch(b);

        // Epoch ledger: msg.value carries the surplus, so the inflow is msgValue, the outflow the measured delta.
        if (ghostValidatorDefaulted) {
            ghostBalanceInflowsSinceDefault += b.msgValue;
            ghostBalanceOutflowsSinceDefault += b.balanceBefore + b.msgValue - address(coffer).balance;
        }
        ghostBalanceInflows += b.msgValue;
        ghostBalanceOutflows += b.total;
        ghostTotalEscrowedValue += b.total;

        for (uint256 j = 0; j < b.bondIds.length; j++) {
            uint256 bondId = b.bondIds[j];
            // The per-owner delta check verified the credit, so the per-id amount is the intended one.
            ghostEscrowCredited[bondId] += b.amounts[j];
            _removeActiveBondId(bondId);
            ghostIsBondActive[bondId] = false;
            delete ghostBondHolder[bondId];
            delete ghostBondMaturityValue[bondId];
            delete ghostPrincipal[bondId];
            ++ghostTotalBondsRedeemed;
        }
    }

    /// @dev A contiguous window over the active list modulo its length: distinct ids for any count <= length.
    function _pickRedeemBatch(uint256 idSeed, uint256 countSeed) private view returns (RedeemBatch memory b) {
        uint256 len = ghostActiveBondIds.length;
        uint256 count = bound(countSeed, 1, len < 3 ? len : 3);
        uint256 start = idSeed % len;
        b.bondIds = new uint256[](count);
        b.amounts = new uint128[](count);
        b.owners = new address[](count);
        b.expectedCredit = new uint256[](count);
        b.pendingBefore = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            uint256 bondId = ghostActiveBondIds[(start + j) % len];
            b.bondIds[j] = bondId;
            (b.amounts[j],,) = coffer.sHolderConditions(bondId);
            b.total += b.amounts[j];
            address owner = ghostBondHolder[bondId];
            uint256 k = 0;
            while (k < b.ownerCount && b.owners[k] != owner) {
                k++;
            }
            if (k == b.ownerCount) {
                b.owners[k] = owner;
                b.pendingBefore[k] = redemptionEscrow.sPendingClaims(owner);
                ++b.ownerCount;
            }
            b.expectedCredit[k] += b.amounts[j];
        }
        b.balanceBefore = address(coffer).balance;
        b.escrowBefore = address(redemptionEscrow).balance;
        Vc memory vc = _readVc();
        b.outstandingBefore = vc.outstandingBonds;
        b.issueSizeBefore = vc.issueSize;
    }

    function _checkRedeemBatch(RedeemBatch memory b) private {
        Vc memory vc = _readVc();
        if (address(redemptionEscrow).balance != b.escrowBefore + b.total) ghostEscrowViolation = true;
        if (address(coffer).balance != b.balanceBefore + b.msgValue - b.total) ghostEscrowViolation = true;
        if (uint256(vc.outstandingBonds) != uint256(b.outstandingBefore) - b.bondIds.length) {
            ghostEscrowViolation = true;
        }
        if (vc.issueSize != b.issueSizeBefore) ghostEscrowViolation = true;
        for (uint256 k = 0; k < b.ownerCount; k++) {
            if (redemptionEscrow.sPendingClaims(b.owners[k]) != b.pendingBefore[k] + b.expectedCredit[k]) {
                ghostEscrowViolation = true;
            }
        }
    }

    function _removeActiveBondId(uint256 bondId) private {
        uint256 len = ghostActiveBondIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (ghostActiveBondIds[i] == bondId) {
                ghostActiveBondIds[i] = ghostActiveBondIds[len - 1];
                ghostActiveBondIds.pop();
                return;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: escrow claim (to self, or redirected to another holder)
    // ══════════════════════════════════════════════════════════════════════
    /// @dev Strict-safe: only a claimant with a pending claim calls, and every payee is an EOA.
    function handlerEscrowClaim(uint256 claimantSeed, uint256 toSeed) external {
        ++callsEscrowClaim;
        address claimant = holders[claimantSeed % holders.length];
        uint256 pending = redemptionEscrow.sPendingClaims(claimant);
        if (pending == 0) return;

        // Half the calls redirect, the path the _to parameter exists for.
        address to = toSeed % 2 == 0 ? claimant : holders[(toSeed / 2) % holders.length];
        uint256 toBefore = to.balance;
        uint256 claimantBefore = claimant.balance;
        uint256 toPendingBefore = redemptionEscrow.sPendingClaims(to);
        uint256 escrowBefore = address(redemptionEscrow).balance;

        vm.prank(claimant);
        redemptionEscrow.claim(payable(to));

        if (to.balance != toBefore + pending) ghostEscrowViolation = true;
        if (to != claimant) {
            if (claimant.balance != claimantBefore) ghostEscrowViolation = true;
            if (redemptionEscrow.sPendingClaims(to) != toPendingBefore) ghostEscrowViolation = true;
        }
        if (redemptionEscrow.sPendingClaims(claimant) != 0) ghostEscrowViolation = true;
        if (address(redemptionEscrow).balance != escrowBefore - pending) ghostEscrowViolation = true;

        ghostTotalEscrowClaimed += pending;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorWithdrawFromExecution
    // ══════════════════════════════════════════════════════════════════════
    function handlerValidatorWithdrawFromExecution(uint256 amount) external {
        ++callsValidatorWithdrawFromExecution;

        // Frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

        Vc memory vc = _readVc();
        uint256 contractBalance = address(coffer).balance;
        if (contractBalance == 0) return;

        uint128 amt;
        if (vc.outstandingBonds > 0) {
            if (vc.issueSize == 0) return;
            uint256 maxWithdraw = vc.issueSize < contractBalance ? vc.issueSize : contractBalance;
            amt = uint128(bound(amount, 1, maxWithdraw));
        } else {
            amt = uint128(bound(amount, 1, contractBalance));
        }

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(amt);
        _recordVersionBump();
        ghostBalanceOutflows += amt;

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

        // Frozen while defaulted (ValidatorInDefault) -- the security boundary: no new pending
        // partial can ever be created post-default. Pre-default pendings still arrive later,
        // which mirrors a dust partial fired just before the flip.
        if (ghostValidatorDefaulted) return;

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));
        if (validator.balance < fee) return;

        // Request up to the modeled stake, capped at 50 ETH per request
        uint256 maxGwei = uint256(ghostConsensusBalance) / GWEI_RATE;
        if (maxGwei > 50 gwei) maxGwei = 50 gwei; // 50 gwei of gwei-units == 50 ETH in wei
        // casting to 'uint64' is safe because maxGwei is capped at 5e10
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 amtGwei = uint64(bound(amount, 0, maxGwei));

        uint256 msgValue = fee;
        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.prank(validator);
        coffer.validatorWithdrawFromConsensus{value: msgValue}(amtGwei);
        // The predeploy takes exactly the fee, the coffer keeps msg.value - fee (zero today)
        ghostBalanceInflows += msgValue - fee;
        if (address(coffer).balance != cofferBalanceBefore + msgValue - fee) ghostBalanceViolation = true;

        // casting to 'uint128' is safe because GWEI_RATE fits in uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amtWei = uint128(amtGwei) * uint128(GWEI_RATE);
        if (amtWei == 0) return;

        // Move the requested stake into in-transit: it leaves the modeled consensus balance now
        // and lands at the coffer once handlerSimulateEthArrival passes the queue delay.
        uint128 inTransit = amtWei <= ghostConsensusBalance ? amtWei : ghostConsensusBalance;
        ghostConsensusBalance -= inTransit;
        if (inTransit > 0) {
            ghostPendingWithdrawals.push(
                PendingWithdrawal({amount: inTransit, arrivalTime: block.timestamp + EXIT_QUEUE_DELAY})
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: validatorAddFundsToConsensus
    // ══════════════════════════════════════════════════════════════════════
    function handlerValidatorAddFundsToConsensus(uint256 amount) external {
        ++callsValidatorAddFundsToConsensus;

        // Frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

        Vc memory vc = _readVc();

        // casting to 'uint128' is safe because bound result stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amt = uint128(bound(amount, 1 ether, 100 ether));
        // round down to a gwei multiple (the contract requires msg.value % 1 gwei == 0)
        // casting to 'uint128' is safe because result stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast, divide-before-multiply) floor to a gwei multiple
        amt = uint128((amt / GWEI_RATE) * GWEI_RATE);
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

        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: amt}(depositDataRoot);
        // All of msg.value is forwarded to the deposit contract
        if (address(coffer).balance != cofferBalanceBefore) ghostBalanceViolation = true;

        ghostIssueSize += issueSizeIncrement;
        ghostConsensusBalance += amt;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: convertToCompounding
    // ══════════════════════════════════════════════════════════════════════
    function handlerConvertToCompounding() external {
        ++callsConvertToCompounding;

        // Frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

        address consolidation = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;
        (bool readOk, bytes memory feeData) = consolidation.staticcall("");
        if (!readOk) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));
        if (validator.balance < fee) return;
        uint256 msgValue = fee;
        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.prank(validator);
        coffer.convertToCompounding{value: msgValue}();
        ghostBalanceInflows += msgValue - fee;
        if (address(coffer).balance != cofferBalanceBefore + msgValue - fee) ghostBalanceViolation = true;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: sendEthToCoffer (receive)
    // ══════════════════════════════════════════════════════════════════════
    function handlerSendEthToCoffer(uint256 amount) external {
        ++callsSendEthToCoffer;
        uint128 amt = uint128(bound(amount, 0.01 ether, 10 ether));
        address sender = holders[amount % holders.length];
        if (sender.balance < amt) return;
        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.prank(sender);
        (bool success,) = address(coffer).call{value: amt}("");
        if (!success) {
            ghostTopUpReverted = true;
            return;
        }
        ghostBalanceInflows += amt;
        if (address(coffer).balance != cofferBalanceBefore + amt) ghostBalanceViolation = true;
        // The on-chain issueSize bump still happens post-default (dead state, every consumer is
        // frozen), so the ghost keeps mirroring it either way.
        ghostIssueSize += amt;
        if (ghostValidatorDefaulted) ghostBalanceInflowsSinceDefault += amt;
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
        _recordVersionBump();
        if (vc.outstandingBonds > 0 && _readVc().interestRate >= vc.interestRate) ghostParamViolation = true;
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
        _recordVersionBump();
        if (vc.outstandingBonds > 0 && _readVc().issueSize >= vc.issueSize) ghostParamViolation = true;
        ghostIssueSize = newIssueSize;
        // Declaring a larger issueSize is the validator asserting issuance capacity that must be
        // backed by consensus-layer stake (issueSize = stake * (1 - buffer) <= stake). Model the
        // stake so cross-layer solvency reflects an honest, adequately-staked validator. We only
        // raise (never lower) the modeled stake; a lower issueSize keeps the prior stake. Post
        // default the honest-staking assumption no longer applies (deposits are frozen), so the
        // modeled stake never grows there. The recovery estate only shrinks toward the contract.
        if (!ghostValidatorDefaulted && ghostConsensusBalance < newIssueSize) {
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
        _recordVersionBump();
        if (vc.outstandingBonds > 0 && _readVc().issueSizeBufferBps <= vc.issueSizeBufferBps) {
            ghostParamViolation = true;
        }
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
        _recordVersionBump();
        if (vc.outstandingBonds > 0 && _readVc().maximumDuration > vc.maximumDuration) ghostParamViolation = true;
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
    // HANDLER: advanceTime
    // ══════════════════════════════════════════════════════════════════════
    function handlerAdvanceTime(uint256 seconds_) external {
        ++callsAdvanceTime;
        uint256 advance = bound(seconds_, 1, 60 days);
        vm.warp(block.timestamp + advance);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: declareDefault
    // ══════════════════════════════════════════════════════════════════════
    /// @dev Anyone-callable default declaration. Strict-safe: scans the active list for a bond
    /// that satisfies the on-chain predicate (matured AND unpayable) and only calls when one
    /// exists, so the handler never reverts by construction.
    function handlerDeclareDefault(uint256 idSeed) external {
        ++callsDeclareDefault;

        if (ghostValidatorDefaulted) return;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 contractBalance = address(coffer).balance;
        uint256 start = idSeed % len;

        // Pick a matured, unpayable bond. If every unpayable bond is still running, model the
        // patient adversary: warp to the earliest such maturity (same precedent as
        // handlerAdvanceTime warping) and declare then. Without the wait, the rich test validator
        // redeems bonds faster than they can mature unpaid and the default region goes unexplored.
        uint256 targetBondId;
        uint256 earliestMaturity = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            uint256 bondId = ghostActiveBondIds[(start + i) % len];
            (uint128 amount, uint32 _duration, uint32 startTimestamp) = coffer.sHolderConditions(bondId);

            if (amount == 0) continue;
            if (contractBalance >= amount) continue;

            uint256 maturity = uint256(_duration) + uint256(startTimestamp);
            // forge-lint: disable-next-line
            if (maturity <= block.timestamp) {
                targetBondId = bondId;
                earliestMaturity = 0;
                break;
            }
            if (maturity < earliestMaturity) {
                earliestMaturity = maturity;
                targetBondId = bondId;
            }
        }
        if (earliestMaturity == type(uint256).max) return; // every bond is covered
        if (earliestMaturity != 0) vm.warp(earliestMaturity + 1);

        {
            uint256 bondId = targetBondId;

            // If this declare succeeds although the bond was covered, record the
            // violation instead of asserting (asserts would be masked under fail_on_revert=false)
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            bool coveredBeforeCall = address(coffer).balance >= amount;

            vm.prank(holders[idSeed % holders.length]);
            coffer.declareDefault(bondId);
            // The declaring call moves nothing (contractBalance was read before the warp, a warp moves no ETH)
            if (address(coffer).balance != contractBalance) ghostBalanceViolation = true;

            _recordDefaultFlip(coveredBeforeCall);
            return;
        }
    }

    /// @dev Both default-flip sites (handlerDeclareDefault and handlerHolderRedeemBondOrDefault's
    /// shortfall) record the epoch ghosts through this single function, so they cannot drift apart.
    /// The epoch ledger restarts from the balance snapshot taken here.
    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: declareDefault refused (the negative half of the predicate)
    // ══════════════════════════════════════════════════════════════════════
    /// @dev handlerDeclareDefault only declares where the predicate holds, so the contract's refusals were never
    ///      exercised. Strict-safe: every call sits in a try/catch.
    function handlerDeclareDefaultInvalid(uint256 idSeed) external {
        ++callsDeclareDefaultInvalid;
        if (ghostActiveBondIds.length == 0) return;
        uint256 bondId = ghostActiveBondIds[idSeed % ghostActiveBondIds.length];
        (uint128 amount, uint32 duration, uint32 startTimestamp) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;
        address caller = holders[idSeed % holders.length];

        if (ghostValidatorDefaulted) {
            // A standing default refuses a second declaration
            vm.prank(caller);
            try coffer.declareDefault(bondId) {
                ghostDeclareViolation = true;
            } catch (bytes memory reason) {
                if (bytes4(reason) != Coffer.AlreadyDefaulted.selector) ghostDeclareViolation = true;
            }
            return;
        }

        // forge-lint: disable-next-line
        bool unmatured = uint256(duration) + uint256(startTimestamp) > block.timestamp;
        bool covered = address(coffer).balance >= amount;
        if (!unmatured && !covered) return; // the predicate holds, that is handlerDeclareDefault's case

        vm.prank(caller);
        try coffer.declareDefault(bondId) {
            ghostDeclareViolation = true;
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            if (sel != Coffer.HoldersTimeHasNotExpiredYet.selector && sel != Coffer.ValidatorNotDefaultable.selector) {
                ghostDeclareViolation = true;
            }
        }
        if (unmatured) {
            // The holder's own redeem is gated by the same maturity check
            vm.prank(ghostBondHolder[bondId]);
            try coffer.holderRedeemBondOrDefault(bondId) returns (bool) {
                ghostDeclareViolation = true;
            } catch (bytes memory reason) {
                if (bytes4(reason) != Coffer.HoldersTimeHasNotExpiredYet.selector) ghostDeclareViolation = true;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: parameter loosening refused while bonds are outstanding
    // ══════════════════════════════════════════════════════════════════════
    /// @dev The setter handlers pre-filter their inputs to the legal side, so the contract's four guards were never
    ///      asked to refuse. Strict-safe: low-level calls, a failure never reverts the handler.
    function handlerParameterLoosenInvalid(uint256 seed) external {
        ++callsParameterLoosenInvalid;
        Vc memory vc = _readVc();
        if (vc.outstandingBonds == 0) return;
        _expectSetterRevert(
            abi.encodeCall(Coffer.changeInterestRate, (vc.interestRate)),
            Coffer.ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist.selector
        );
        if (vc.interestRate < MAX_RATE) {
            _expectSetterRevert(
                abi.encodeCall(Coffer.changeInterestRate, (vc.interestRate + 1)),
                Coffer.ValidatorCannotIncreaseInterestRateWhileOutstandingBondExist.selector
            );
        }
        if (vc.maximumDuration < MAX_DURATION) {
            _expectSetterRevert(
                abi.encodeCall(Coffer.changeMinimumAndMaximumDuration, (vc.minimumDuration, vc.maximumDuration + 1)),
                Coffer.ValidatorCannotIncreaseMaximumDurationWhileOutstandingBondExist.selector
            );
        }
        if (vc.issueSizeBufferBps > 0) {
            _expectSetterRevert(
                abi.encodeCall(Coffer.changeIssueSizeBufferBps, (vc.issueSizeBufferBps - 1)),
                Coffer.ValidatorCannotDecreaseIssueSizeBufferWhileOutstandingBondExist.selector
            );
        }
        _expectSetterRevert(
            abi.encodeCall(Coffer.changeIssueSize, (vc.issueSize)),
            Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector
        );
        if (vc.issueSize < type(uint128).max) {
            _expectSetterRevert(
                abi.encodeCall(Coffer.changeIssueSize, (vc.issueSize + 1)),
                Coffer.ValidatorCannotIncreaseIssueSizeWhileOutstandingBondExist.selector
            );
        }
        // The seed only keeps the action an ordinary one-argument target for the fuzzer
        (seed);
    }

    function _expectSetterRevert(bytes memory data, bytes4 expected) private {
        vm.prank(validator);
        (bool ok, bytes memory ret) = address(coffer).call(data);
        if (ok || bytes4(ret) != expected) ghostParamViolation = true;
    }

    /// @dev Called after every successful call of a version-bumping function, and nowhere else.
    function _recordVersionBump() private {
        ++ghostVersionBumps;
        Vc memory v = _readVc();
        ghostTermsRate = v.interestRate;
        ghostTermsMinDur = v.minimumDuration;
        ghostTermsMaxDur = v.maximumDuration;
        ghostTermsBuffer = v.issueSizeBufferBps;
    }

    function _recordDefaultFlip(bool coveredBeforeCall) private {
        if (coveredBeforeCall) ghostDefaultViolation = true;
        ghostValidatorDefaulted = true;
        ghostBondsAtDefault = ghostActiveBondIds.length;
        ghostBoughtAtDefault = ghostTotalBondsBought;
        ghostBalanceAtDefault = address(coffer).balance;
        ghostConsensusAtDefault = ghostConsensusBalance;
        ghostBalanceInflowsSinceDefault = 0;
        ghostBalanceOutflowsSinceDefault = 0;
        ++ghostTotalDefaultsDeclared;
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: exitValidator
    // ══════════════════════════════════════════════════════════════════════
    /// @dev Anyone-callable exit request, repeatable while any bond is outstanding (the on-chain
    /// NoOutstandingBonds gate closes at full settlement, so the handler pre-checks it to stay
    /// revert-free). Pays the exact fee (no surplus, keeping the epoch ledger simple). The sweep model
    /// moves the whole remaining modeled stake into in-transit at most once per epoch; it lands at
    /// the coffer via handlerSimulateEthArrival after the queue delay. Repeat calls exercise
    /// on-chain re-callability with nothing further to move.
    function handlerExitValidator(uint256 seed) external {
        ++callsExitValidator;

        if (!ghostValidatorDefaulted) return;
        if (_readVc().outstandingBonds == 0) return;

        (bool readOk, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOk || feeData.length != 32) return;
        // casting to 'uint256' is safe because feeData staticcall return fits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 fee = uint256(bytes32(feeData));

        address caller = holders[seed % holders.length];
        if (caller.balance < fee) return;

        uint256 msgValue = fee;
        uint256 cofferBalanceBefore = address(coffer).balance;
        vm.prank(caller);
        coffer.exitValidator{value: msgValue}();
        ghostBalanceInflows += msgValue - fee;
        if (address(coffer).balance != cofferBalanceBefore + msgValue - fee) ghostBalanceViolation = true;

        if (!ghostExitSweepQueued && ghostConsensusBalance > 0) {
            ghostPendingWithdrawals.push(
                PendingWithdrawal({amount: ghostConsensusBalance, arrivalTime: block.timestamp + EXIT_QUEUE_DELAY})
            );
            ghostConsensusBalance = 0;
            ghostExitSweepQueued = true;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HANDLER: clearDefault
    // ══════════════════════════════════════════════════════════════════════
    /// @dev Owner-only exit from a default, callable exactly when every bond has settled at its
    /// full maturity value. Strict-safe: pre-checks the flag and the on-chain outstandingBonds
    /// gate, so the handler never reverts by construction. Closing the epoch clears the mirror
    /// flag and re-arms the sweep latch; the next declare re-baselines every epoch snapshot.
    function handlerClearDefault(uint256) external {
        ++callsClearDefault;

        if (!ghostValidatorDefaulted) return;
        if (_readVc().outstandingBonds != 0) return;

        vm.prank(validator);
        coffer.clearDefault();
        _recordVersionBump();

        ghostValidatorDefaulted = false;
        ghostExitSweepQueued = false;
        ++ghostTotalDefaultsCleared;

        // Emerging with a standing issueSize is the validator re-asserting that issuance
        // capacity for the new epoch (the validator re-attests via changeIssueSize).
        // Mirror handlerChangeIssueSize's honest-staking device: raise the modeled stake so
        // cross-layer solvency reflects an honest, adequately-backed validator rather than
        // the stale-attestation seller the trust model excludes.
        if (ghostConsensusBalance < ghostIssueSize) {
            ghostConsensusBalance = ghostIssueSize;
        }
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

    function getAllBondIdsLength() external view returns (uint256) {
        return ghostAllBondIds.length;
    }

    function getAllBondIdAt(uint256 index) external view returns (uint256) {
        return ghostAllBondIds[index];
    }

    function getHoldersLength() external view returns (uint256) {
        return holders.length;
    }
}
