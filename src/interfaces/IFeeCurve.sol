//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title IFeeCurve
 * @author Blockroad Ltd
 * @notice Interface for the shared protocol fee curve contract
 */
interface IFeeCurve {
    /// @notice Returns the current protocol fee and recipient in one call
    /// @return bps Current fee in basis points (1% = 100 bps)
    /// @return recipient Current fee recipient address
    function getFee() external view returns (uint256 bps, address recipient);
}
