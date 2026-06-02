//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFeeCurve} from "./interfaces/IFeeCurve.sol";

/// @title FeeCurve
/// @author Blockroad Ltd
/// @notice Shared, protocol-wide fee schedule. The curve (fee amounts) is immutable —
/// sampled from f(t) = 10% - 9%*e^(-k t) with k chosen so the curve is ~99% of the way to
/// 10% by year 10. Only the fee RECIPIENT can be changed (by the protocol admin).
/// Fees are returned in basis points (1% = 100 bps) and applied to a bond's INTEREST.
contract FeeCurve is Ownable2Step, IFeeCurve {
    error ZeroAddress();

    /// @notice Protocol launch time; the curve's time axis is measured from here.
    uint256 public immutable START_TIME;
    /// @notice Where buyBond sends the protocol fee. Changeable by the owner only.
    address public feeRecipient;

    /// @notice Emitted when the fee recipient is changed
    /// @param oldRecipient The previous fee recipient
    /// @param newRecipient The new fee recipient
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

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
