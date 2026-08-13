//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Coffer} from "../../../src/Coffer.sol";
import {FeeCurve} from "../../../src/FeeCurve.sol";
import {Interest} from "../../../src/libraries/Interest.sol";

contract CofferHandler is Test {
    // ── Constants ──────────────────────────────────────────────────────────
    uint256 constant MAX_RATE = 1e8;
    uint256 constant GWEI_RATE = 1e9;
    uint256 constant SECONDS_IN_YEAR = 31_536_000;
    uint256 constant BUFFER_DENOMINATOR = 10000;

    // ── Contracts ──────────────────────────────────────────────────────────
    Coffer public coffer;
    FeeCurve public feeCurve;

    // ── Actors ─────────────────────────────────────────────────────────────
    address public validator;
    address[] public holders;

    // ── Ghost state ────────────────────────────────────────────────────────
    uint256[] public ghostActiveBondIds;
    mapping(uint256 => bool) public ghostIsBondActive;
    mapping(uint256 => address) public ghostBondHolder;
    mapping(uint256 => uint128) public ghostBondAmount;

    uint256 public ghostTotalBondsBought;
    uint256 public ghostTotalBondsRedeemed;
    uint256 public ghostTotalBondsWithdrawnExecution;

    // ── Ghost state: default machine ───────────────────────────────────────
    // Latched true by handlerDeclareDefault on a successful declare, never unset (C1 mirror).
    bool public ghostValidatorDefaulted;
    // Set if a declare ever SUCCEEDS while the pre-call balance covered the bond. Handler-side
    // asserts would be masked under fail_on_revert = false, so violations are recorded here and
    // asserted by invariant_solventValidatorNeverDefaulted (C3).
    bool public ghostDefaultViolation;
    // Snapshots taken at the default flip (C8: the bond set only shrinks afterwards).
    uint256 public ghostBondsAtDefault;
    uint256 public ghostBoughtAtDefault;
    uint256 public ghostTotalDefaultsDeclared;

    // ── Per-function call counters ─────────────────────────────────────────
    uint256 public callsBuyBond;
    uint256 public callsHolderWithdrawFromExecution;
    uint256 public callsRedeemBondsEarly;
    uint256 public callsValidatorWithdrawFromExecution;
    uint256 public callsValidatorAddFundsToConsensus;
    uint256 public callsChangeCofferActivity;
    uint256 public callsChangeInterestRate;
    uint256 public callsChangeIssueSize;
    uint256 public callsAdvanceTime;
    uint256 public callsSendEthToCoffer;
    uint256 public callsDeclareDefault;

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(Coffer _coffer, FeeCurve _feeCurve) {
        coffer = _coffer;
        feeCurve = _feeCurve;
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
            if (entries[i].topics[0] == keccak256("BondBought(address,uint256,uint128,uint32,uint128,uint32)")) {
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

        // buyBond is frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

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

        // Compute bondMaturityValue exactly as Coffer.buyBond does: principal + interest - fee.
        // The protocol fee (FeeCurve, 100-990 bps of interest) is borne by the holder.
        uint256 interest = Interest.calculateInterest(amt, dur, p.interestRate);
        (uint256 feeBps,) = feeCurve.getFee();
        uint256 fee = (interest * feeBps) / BUFFER_DENOMINATOR;
        if (fee >= amt + 1) return; // mirror require(fee < msg.value + 1)
        uint256 bondMaturityValue = amt + interest - fee;
        if (bondMaturityValue > p.issueSize) return;

        // Buy the bond
        vm.recordLogs();
        vm.prank(holder);
        coffer.buyBond{value: amt}(dur, p.version);

        uint256 bondId = _extractBondIdFromLogs();

        // Update ghost state
        ghostActiveBondIds.push(bondId);
        ghostIsBondActive[bondId] = true;
        ghostBondHolder[bondId] = holder;
        // casting to 'uint128' is safe because bondMaturityValue stays within consensus limits
        // forge-lint: disable-next-line(unsafe-typecast)
        ghostBondAmount[bondId] = uint128(bondMaturityValue);
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
        (uint128 amount, uint32 duration, uint32 startTimestamp) = coffer.sHolderConditions(bondId);
        if (amount == 0) return;

        // Check maturity; waived while defaulted (acceleration, R5)
        // forge-lint: disable-next-line
        if (!ghostValidatorDefaulted && uint256(duration) + uint256(startTimestamp) > block.timestamp) return;

        // Allow both full and partial paths
        uint256 balance = address(coffer).balance;
        if (balance == 0) return;

        vm.prank(holder);
        coffer.holderWithdrawFromExecution(bondId);

        // Re-read on-chain amount after withdrawal to determine what happened
        (uint128 amountAfter,,) = coffer.sHolderConditions(bondId);

        if (amountAfter == 0) {
            // Full withdrawal: remove from active
            ghostActiveBondIds[idx] = ghostActiveBondIds[len - 1];
            ghostActiveBondIds.pop();
            ghostIsBondActive[bondId] = false;
            delete ghostBondHolder[bondId];
            delete ghostBondAmount[bondId];
            ++ghostTotalBondsWithdrawnExecution;
        } else {
            // Partial withdrawal: update ghost amount, keep active
            uint128 withdrawn = amount - amountAfter;
            ghostBondAmount[bondId] -= withdrawn;
        }
    }

    function handlerRedeemBondsEarly(uint256 idSeed) external {
        ++callsRedeemBondsEarly;

        uint256 len = ghostActiveBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 bondId = ghostActiveBondIds[idx];

        // Read on-chain amount
        (uint128 amount,,) = coffer.sHolderConditions(bondId);
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
        ++ghostTotalBondsRedeemed;
    }

    function handlerValidatorWithdrawFromExecution(uint256 amount) external {
        ++callsValidatorWithdrawFromExecution;

        // Frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

        (uint128 issueSize,,,,,, uint32 outstandingBonds,,,) = coffer.sValidatorConditions();

        uint256 contractBalance = address(coffer).balance;
        if (contractBalance == 0) return;

        if (outstandingBonds > 0) {
            // Bounded withdrawal: capped by issueSize and balance
            if (issueSize == 0) return;

            uint256 maxWithdraw = issueSize < contractBalance ? issueSize : contractBalance;
            uint128 amt = uint128(bound(amount, 1, maxWithdraw));

            vm.prank(validator);
            coffer.validatorWithdrawFromExecution(amt);
        } else {
            // No bonds: free withdrawal
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

        // Frozen while defaulted (ValidatorInDefault)
        if (ghostValidatorDefaulted) return;

        // Clamp amount to [1 ether, 100 ether], round down to gwei multiple
        uint128 amt = uint128(bound(amount, 1 ether, 100 ether));

        // casting to 'uint128' is safe because bounds are introduced
        // forge-lint: disable-next-line(unsafe-typecast, divide-before-multiply) floor to a gwei multiple
        amt = uint128((amt / GWEI_RATE) * GWEI_RATE);
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
            (uint128 amount, uint32 duration, uint32 startTimestamp) = coffer.sHolderConditions(bondId);

            if (amount == 0) continue;
            if (contractBalance >= amount) continue;

            uint256 maturity = uint256(duration) + uint256(startTimestamp);
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

            // C3 evidence: if this declare succeeds although the bond was covered, record the
            // violation instead of asserting (asserts would be masked under fail_on_revert=false)
            (uint128 amount,,) = coffer.sHolderConditions(bondId);
            bool coveredBeforeCall = address(coffer).balance >= amount;

            vm.prank(holders[idSeed % holders.length]);
            coffer.declareDefault(bondId);

            if (coveredBeforeCall) ghostDefaultViolation = true;

            ghostValidatorDefaulted = true;
            ghostBondsAtDefault = ghostActiveBondIds.length;
            ghostBoughtAtDefault = ghostTotalBondsBought;
            ++ghostTotalDefaultsDeclared;
            return;
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
}
