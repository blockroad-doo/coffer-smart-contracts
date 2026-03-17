//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

/**
 * @title ICofferBondsRedeemedEarly
 * @author Blockroad Ltd
 * @notice Interface for the pull-based early bond redemption contract
 * @notice Coffer contracts use this interface to deposit ETH for bond holders
 */
interface ICofferBondsRedeemedEarly {
    /// @notice Called by Coffer contracts to deposit ETH for bond holders
    /// @param _holders Array of holder addresses
    /// @param _amounts Array of amounts owed to each holder
    function deposit(address[] calldata _holders, uint128[] calldata _amounts) external payable;
}
