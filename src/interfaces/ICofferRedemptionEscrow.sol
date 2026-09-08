//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * @title ICofferRedemptionEscrow
 * @author Blockroad d.o.o.
 * @notice Interface for the pull-based redemption escrow contract
 * @notice Coffer contracts use this interface to deposit ETH for bond holders
 */
interface ICofferRedemptionEscrow {
    /// @notice Called by Coffer contracts to deposit ETH for bond holders
    /// @param _holders Array of holder addresses
    /// @param _amounts Array of amounts owed to each holder
    function deposit(address[] calldata _holders, uint128[] calldata _amounts) external payable;
}
