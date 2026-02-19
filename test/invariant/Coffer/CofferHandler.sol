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
    uint256 constant EXIT_QUEUE_DELAY = (EXIT_QUEUE_ETH / ETH_PER_EPOCH) * SECONDS_PER_EPOCH;

    uint32 constant MAX_RATE = 1e8;
    uint128 constant GWEI_RATE = 1e9;
    uint32 constant SECONDS_IN_YEAR = 31_536_000;

    address private constant WITHDRAWAL_CONTRACT = 0x00000961Ef480Eb55e80D19ad83579A64c007002;

    // ── Struct ─────────────────────────────────────────────────────────────
    struct PendingWithdrawal {
        uint256 holderId;
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
    uint256[] public ghost_activeBondIds;
    mapping(uint256 => bool) public ghost_isBondActive;
    mapping(uint256 => address) public ghost_bondHolder;
    mapping(uint256 => uint128) public ghost_bondAmount;
    mapping(uint256 => bool) public ghost_hasPendingConsensusWithdrawal;
    PendingWithdrawal[] public ghost_pendingWithdrawals;

    uint256 public ghost_totalBondsBought;
    uint256 public ghost_totalBondsRedeemed;
    uint256 public ghost_totalBondsWithdrawnExecution;
    uint256 public ghost_totalBondsWithdrawnConsensus;
    uint256 public ghost_totalEthArrivedFromConsensus;

    // ── Per-function call counters ─────────────────────────────────────────
    uint256 public calls_buyBond;
    uint256 public calls_holderWithdrawFromExecution;
    uint256 public calls_holderWithdrawFromConsensus;
    uint256 public calls_simulateEthArrival;
    uint256 public calls_redeemBondsEarly;
    uint256 public calls_validatorWithdrawFromExecution;
    uint256 public calls_validatorAddFundsToConsensus;
    uint256 public calls_changeCofferActivity;
    uint256 public calls_changeInterestRate;
    uint256 public calls_changeAvailableAmount;
    uint256 public calls_advanceTime;

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
        uint128 availableAmount;
        uint32 interestRate;
        uint32 minimumDuration;
        uint32 maximumDuration;
        uint128 minimumAmountToAccept;
        uint32 version;
        bool isActive;
    }

    function _readBuyBondParams() private view returns (BuyBondParams memory p) {
        (
            uint128 availableAmount,
            uint32 interestRate,
            uint32 minimumDuration,
            uint32 maximumDuration,
            uint128 minimumAmountToAccept,
            uint32 version,
            ,
            ,
            bool isActive,
        ) = coffer.s_validatorConditions();
        p.availableAmount = availableAmount;
        p.interestRate = interestRate;
        p.minimumDuration = minimumDuration;
        p.maximumDuration = maximumDuration;
        p.minimumAmountToAccept = minimumAmountToAccept;
        p.version = version;
        p.isActive = isActive;
    }

    function _extractHolderIdFromLogs() private returns (uint256 holderId) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("HolderAcceptedOffer(address,uint256,uint128,uint32,uint128)")) {
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

    function handler_buyBond(uint256 actorSeed, uint256 amount, uint256 duration) external {
        ++calls_buyBond;

        address holder = holders[actorSeed % holders.length];
        BuyBondParams memory p = _readBuyBondParams();

        // Early returns for invalid states
        if (!p.isActive) return;
        if (p.availableAmount < p.minimumAmountToAccept) return;
        if (holder.balance == 0) return;

        // Clamp duration
        uint32 dur = uint32(bound(duration, p.minimumDuration, p.maximumDuration));

        // Compute max affordable amount (inverse of interest formula)
        uint256 numerator = uint256(p.availableAmount) * uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR);
        uint256 denominator = uint256(MAX_RATE) * uint256(SECONDS_IN_YEAR) + uint256(p.interestRate) * uint256(dur);
        uint128 maxAmt = uint128(numerator / denominator);

        // Clamp amount
        uint128 upperBound = maxAmt < uint128(holder.balance) ? maxAmt : uint128(holder.balance);
        if (upperBound < p.minimumAmountToAccept) return;
        uint128 amt = uint128(bound(amount, p.minimumAmountToAccept, upperBound));

        // Verify amountWithInterest fits
        uint128 amountWithInterest = amt + Interest.calculateInterest(amt, dur, p.interestRate);
        if (amountWithInterest > p.availableAmount) return;

        // Buy the bond
        vm.recordLogs();
        vm.prank(holder);
        coffer.buyBond{value: amt}(dur, p.version);

        uint256 holderId = _extractHolderIdFromLogs();

        // Update ghost state
        ghost_activeBondIds.push(holderId);
        ghost_isBondActive[holderId] = true;
        ghost_bondHolder[holderId] = holder;
        ghost_bondAmount[holderId] = amountWithInterest;
        ++ghost_totalBondsBought;
    }

    function handler_holderWithdrawFromExecution(uint256 idSeed) external {
        ++calls_holderWithdrawFromExecution;

        uint256 len = ghost_activeBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 holderId = ghost_activeBondIds[idx];
        address holder = ghost_bondHolder[holderId];

        // Read on-chain holder conditions
        (uint128 amount, uint32 duration, uint32 startTimestamp) = coffer.s_holderConditions(holderId);
        if (amount == 0) return;

        // Check maturity
        if (uint256(duration) + uint256(startTimestamp) > block.timestamp) return;

        // Check contract has enough balance
        if (address(coffer).balance < amount) return;

        vm.prank(holder);
        coffer.holderWithdrawFromExecution(holderId);

        // Swap-and-pop from ghost_activeBondIds
        ghost_activeBondIds[idx] = ghost_activeBondIds[len - 1];
        ghost_activeBondIds.pop();

        ghost_isBondActive[holderId] = false;
        delete ghost_bondHolder[holderId];
        delete ghost_bondAmount[holderId];
        ghost_hasPendingConsensusWithdrawal[holderId] = false;
        ++ghost_totalBondsWithdrawnExecution;
    }

    function handler_holderWithdrawFromConsensus(uint256 idSeed) external {
        ++calls_holderWithdrawFromConsensus;

        uint256 len = ghost_activeBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 holderId = ghost_activeBondIds[idx];
        address holder = ghost_bondHolder[holderId];

        // Read on-chain holder conditions
        (uint128 amount, uint32 duration, uint32 startTimestamp) = coffer.s_holderConditions(holderId);
        if (amount == 0) return;

        // Check maturity
        if (uint256(duration) + uint256(startTimestamp) > block.timestamp) return;

        // Must NOT have enough balance (opposite of execution path)
        if (address(coffer).balance >= amount) return;

        // Prevent double-submission
        if (ghost_hasPendingConsensusWithdrawal[holderId]) return;

        // Get EIP-7002 fee
        (bool readOK, bytes memory feeData) = WITHDRAWAL_CONTRACT.staticcall("");
        if (!readOK) return;
        uint256 fee = uint256(bytes32(feeData));

        // Check holder can afford the fee
        if (holder.balance < fee) return;

        vm.prank(holder);
        coffer.holderWithdrawFromConsensus{value: fee}(holderId);

        // Push pending withdrawal
        ghost_pendingWithdrawals.push(
            PendingWithdrawal({
                holderId: holderId,
                amount: amount,
                arrivalTime: block.timestamp + EXIT_QUEUE_DELAY,
                holderAddress: holder
            })
        );
        ghost_hasPendingConsensusWithdrawal[holderId] = true;
        ++ghost_totalBondsWithdrawnConsensus;
    }

    function handler_simulateEthArrival() external {
        ++calls_simulateEthArrival;

        uint256 len = ghost_pendingWithdrawals.length;
        if (len == 0) return;

        // Iterate backwards for safe swap-and-pop
        for (uint256 i = len; i > 0; i--) {
            uint256 idx = i - 1;
            PendingWithdrawal memory pw = ghost_pendingWithdrawals[idx];

            if (block.timestamp >= pw.arrivalTime) {
                // Deliver ETH to coffer
                vm.deal(address(coffer), address(coffer).balance + pw.amount);

                ghost_hasPendingConsensusWithdrawal[pw.holderId] = false;
                ghost_totalEthArrivedFromConsensus += pw.amount;

                // Swap-and-pop
                ghost_pendingWithdrawals[idx] = ghost_pendingWithdrawals[ghost_pendingWithdrawals.length - 1];
                ghost_pendingWithdrawals.pop();
            }
        }
    }

    function handler_redeemBondsEarly(uint256 idSeed) external {
        ++calls_redeemBondsEarly;

        uint256 len = ghost_activeBondIds.length;
        if (len == 0) return;

        uint256 idx = idSeed % len;
        uint256 holderId = ghost_activeBondIds[idx];

        // Read on-chain amount
        (uint128 amount,,) = coffer.s_holderConditions(holderId);
        if (amount == 0) return;

        // Calculate top-up needed
        uint256 contractBalance = address(coffer).balance;
        uint256 topUp = 0;
        if (amount > contractBalance) {
            topUp = amount - contractBalance;
        }

        // Check validator can afford top-up
        if (validator.balance < topUp) return;

        uint256[] memory holderIds = new uint256[](1);
        holderIds[0] = holderId;

        vm.prank(validator);
        coffer.redeemBondsEarly{value: topUp}(holderIds);

        // Swap-and-pop from ghost_activeBondIds
        ghost_activeBondIds[idx] = ghost_activeBondIds[len - 1];
        ghost_activeBondIds.pop();

        ghost_isBondActive[holderId] = false;
        delete ghost_bondHolder[holderId];
        delete ghost_bondAmount[holderId];
        ghost_hasPendingConsensusWithdrawal[holderId] = false;
        ++ghost_totalBondsRedeemed;
    }

    function handler_validatorWithdrawFromExecution(uint256 amount) external {
        ++calls_validatorWithdrawFromExecution;

        // Read outstandingBonds
        (,,,,, , uint32 outstandingBonds,,,) = coffer.s_validatorConditions();
        if (outstandingBonds != 0) return;

        uint256 contractBalance = address(coffer).balance;
        if (contractBalance == 0) return;

        uint128 amt = uint128(bound(amount, 1, contractBalance));

        vm.prank(validator);
        coffer.validatorWithdrawFromExecution(amt);
    }

    function handler_validatorAddFundsToConsensus(uint256 amount) external {
        ++calls_validatorAddFundsToConsensus;

        // Clamp amount to [1 ether, 100 ether], round down to gwei multiple
        uint128 amt = uint128(bound(amount, 1 ether, 100 ether));
        amt = (amt / GWEI_RATE) * GWEI_RATE;
        if (amt < 1 ether) amt = 1 ether;

        // Check validator can afford it
        if (validator.balance < amt) return;

        // Reconstruct the deposit_data_root exactly as the DepositContract does
        bytes memory pubkey = abi.encodePacked(coffer.i_public_key_part1(), coffer.i_public_key_part2());
        bytes memory amountLE = _toLittleEndian64(uint64(uint256(amt) / 1 gwei));

        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));

        // signature is 96 zero bytes; split into first 64 and last 32
        bytes memory sig_first64 = new bytes(64);
        bytes memory sig_last32 = new bytes(32);
        bytes32 signature_root = sha256(
            abi.encodePacked(
                sha256(sig_first64),
                sha256(abi.encodePacked(sig_last32, bytes32(0)))
            )
        );

        // withdrawal_credentials is 32 zero bytes = bytes32(0)
        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkey_root, bytes32(0))),
                sha256(abi.encodePacked(amountLE, bytes24(0), signature_root))
            )
        );

        vm.prank(validator);
        coffer.validatorAddFundsToConsensus{value: amt}(depositDataRoot);
    }

    function handler_changeCofferActivity() external {
        ++calls_changeCofferActivity;

        vm.prank(validator);
        coffer.changeCofferActivity();
    }

    function handler_changeInterestRate(uint256 rate) external {
        ++calls_changeInterestRate;

        uint32 newRate = uint32(bound(rate, 1, MAX_RATE));

        // Read current conditions
        (, uint32 currentRate,,,,, uint32 outstandingBonds,,,) = coffer.s_validatorConditions();

        // Cannot increase rate while outstanding bonds exist
        if (newRate >= currentRate && outstandingBonds != 0) return;

        vm.prank(validator);
        coffer.changeInterestRate(newRate);
    }

    function handler_changeAvailableAmount(uint256 amount) external {
        ++calls_changeAvailableAmount;

        // Read conditions
        (,,,, uint128 minimumAmountToAccept,, uint32 outstandingBonds,,,) = coffer.s_validatorConditions();

        if (outstandingBonds != 0) return;
        if (minimumAmountToAccept == 0) return;

        uint128 amt = uint128(bound(amount, minimumAmountToAccept, 1000 ether));

        vm.prank(validator);
        coffer.changeAvailableAmount(amt);
    }

    function handler_advanceTime(uint256 seconds_) external {
        ++calls_advanceTime;

        uint256 advance = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + advance);
    }

    // ══════════════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function getActiveBondIdsLength() external view returns (uint256) {
        return ghost_activeBondIds.length;
    }

    function getActiveBondIdAt(uint256 index) external view returns (uint256) {
        return ghost_activeBondIds[index];
    }

    function getPendingWithdrawalsLength() external view returns (uint256) {
        return ghost_pendingWithdrawals.length;
    }
}
