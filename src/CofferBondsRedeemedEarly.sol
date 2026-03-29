//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICofferBondsRedeemedEarly} from "./interfaces/ICofferBondsRedeemedEarly.sol";

/**
 * @title CofferBondsRedeemedEarly
 * @author Blockroad Ltd
 * @notice Simple pull-based claim contract for early bond redemptions
 * @notice When a validator redeems bonds early, Coffer deposits the ETH here
 * @notice Holders claim their funds individually via claim()
 * @notice This prevents griefing by non-payable holder contracts
 */
contract CofferBondsRedeemedEarly is ICofferBondsRedeemedEarly {
    error NoPendingClaim();
    error DepositArrayLengthMismatch();
    error DepositMsgValueMismatch();

    /// @notice Pending ETH claims for holders whose bonds were redeemed early
    mapping(address => uint256) public sPendingClaims;

    /// @notice Emitted when ETH is deposited for a bond holder
    /// @param holder The address of the bond holder
    /// @param amount The amount of ETH deposited
    event ClaimDeposited(address indexed holder, uint128 indexed amount);

    /// @notice Emitted when a holder claims their escrowed funds
    /// @param claimant The address of the claimant
    /// @param to The address receiving the funds
    /// @param amount The amount of ETH claimed
    event ClaimWithdrawn(address indexed claimant, address indexed to, uint256 indexed amount);

    /// @notice Called by Coffer contracts to deposit ETH for bond holders
    /// @param _holders Array of holder addresses
    /// @param _amounts Array of amounts owed to each holder
    function deposit(address[] calldata _holders, uint128[] calldata _amounts) external payable {
        require(_holders.length == _amounts.length, DepositArrayLengthMismatch());
        uint256 total = 0;

        for (uint256 i = 0; i < _holders.length; ++i) {
            sPendingClaims[_holders[i]] += _amounts[i];
            total += _amounts[i];

            emit ClaimDeposited(_holders[i], _amounts[i]);
        }
        require(msg.value == total, DepositMsgValueMismatch());
    }

    /// @notice Claim escrowed funds from early bond redemption
    /// @notice The _to parameter allows non-payable contracts to redirect funds
    /// @param _to Address to receive the claimed funds
    function claim(address payable _to) external {
        uint256 amount = sPendingClaims[msg.sender];
        require(amount != 0, NoPendingClaim());

        sPendingClaims[msg.sender] = 0;
        emit ClaimWithdrawn(msg.sender, _to, amount);

        Address.sendValue(_to, amount);
    }
}
