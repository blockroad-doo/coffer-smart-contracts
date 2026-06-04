//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFeeCurve} from "./interfaces/IFeeCurve.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title FeeCurve
/// @author Blockroad Ltd
/// @notice Shared, protocol-wide fee schedule. The curve (fee amounts) is immutable -
/// sampled from f(t) = 10% - 9%*e^(-k t) with k chosen so the curve is ~99% of the way to
/// 10% by year 10. Only the fee RECIPIENT can be changed (by the protocol admin).
/// Fees are returned in basis points (1% = 100 bps) and applied to a bond's INTEREST.
contract FeeCurve is Ownable2Step, IFeeCurve {
    error ZeroAddress();
    error NoFeesToClaim();
    error RenounceDisabled();

    /// @notice Protocol launch time; the curve's time axis is measured from here.
    uint256 public immutable START_TIME;
    /// @notice Where buyBond sends the protocol fee. Changeable by the owner only.
    address public feeRecipient;
    /// @notice Protocol fees collected from buyBond, pooled here and awaiting claim() by the fee recipient
    uint256 public sAccruedFees;

    /// @notice Emitted when the fee recipient is changed
    /// @param oldRecipient The previous fee recipient
    /// @param newRecipient The new fee recipient
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when a protocol fee is collected from a Coffer's buyBond
    /// @param amount The fee amount collected, in wei
    event FeeCollected(uint256 indexed amount);
    /// @notice Emitted when accrued protocol fees are claimed by the fee recipient
    /// @param to The recipient that received the fees
    /// @param amount The amount claimed, in wei
    event FeesClaimed(address indexed to, uint256 indexed amount);

    constructor(address _owner, address _feeRecipient) Ownable(_owner) {
        require(_feeRecipient != address(0), ZeroAddress());
        START_TIME = block.timestamp;
        feeRecipient = _feeRecipient;
    }

    /// @notice Change the protocol fee recipient. Fee amounts cannot be changed.
    /// @param _newRecipient The new fee recipient address
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), ZeroAddress());
        emit FeeRecipientChanged(feeRecipient, _newRecipient);
        feeRecipient = _newRecipient;
    }

    /// @notice Collect a protocol fee from a Coffer's buyBond (pull pattern).
    /// @dev Intentionally performs no require and no external call, so it can NEVER revert. This decouples
    /// bond issuance from the fee recipient: a hostile, non-payable, or self-destructed recipient can no
    /// longer brick buyBond on any clone. Fees pool here until claim().
    function collectFee() external payable {
        sAccruedFees += msg.value;
        emit FeeCollected(msg.value);
    }

    /// @notice Pull all accrued protocol fees to the current fee recipient.
    /// @notice Permissionless poke. Pays only the fixed feeRecipient (never a caller-chosen address),
    /// because the fee pool is shared across all Coffers. If the recipient cannot receive, this reverts
    /// but does NOT affect bond issuance; the admin can setFeeRecipient to a payable address and re-claim.
    function claim() external {
        uint256 amount = sAccruedFees;
        require(amount != 0, NoFeesToClaim());
        sAccruedFees = 0;
        emit FeesClaimed(feeRecipient, amount);
        Address.sendValue(payable(feeRecipient), amount);
    }

    /// @notice Disabled to prevent irreversibly locking the fee recipient (mirrors Coffer.renounceOwnership)
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice One-call accessor used by Coffer.buyBond
    /// @return bps current fee in basis points
    /// @return recipient current fee recipient
    function getFee() external view returns (uint256 bps, address recipient) {
        return (currentFeeBps(), feeRecipient);
    }

    /// @notice Returns the current fee in basis points, sampled from the immutable curve.
    /// @return current fee in basis points
    function currentFeeBps() public view returns (uint256) {
        uint256 elapsedDays = (block.timestamp - START_TIME) / 1 days;
        return feeBpsAtDay(elapsedDays);
    }

    /// @notice Pure piecewise-linear interpolation of the hardcoded curve.
    /// @dev Breakpoints live in code (not storage): no setter, truly immutable.
    /// @param d The elapsed day count
    function feeBpsAtDay(uint256 d) public pure returns (uint256) {
        uint32[10] memory breakpointDay = [uint32(0), 90, 180, 365, 730, 1095, 1460, 1825, 2555, 3650];
        uint32[10] memory breakpointBps = [uint32(100), 197, 283, 432, 642, 774, 857, 910, 964, 990];

        for (uint256 i = 0; i < 9; ++i) {
            if (d < breakpointDay[i + 1]) {
                uint256 b0 = breakpointBps[i];
                uint256 b1 = breakpointBps[i + 1]; // B increasing, so b1 >= b0
                return b0 + ((b1 - b0) * (d - breakpointDay[i])) / (breakpointDay[i + 1] - breakpointDay[i]);
            }
        }
        return breakpointBps[9]; // d >= breakpointDay[9], plateau after last breakpoint
    }
}
