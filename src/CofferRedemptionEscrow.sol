//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICofferRedemptionEscrow} from "./interfaces/ICofferRedemptionEscrow.sol";

/**
 * @title CofferRedemptionEscrow
 * @author Blockroad d.o.o.
 * @notice Simple pull-based claim contract for bonds the validator redeems
 * @notice When a validator redeems bonds, Coffer deposits the maturity values here
 * @notice Holders claim their funds individually via claim()
 * @notice This prevents griefing by non-payable holder contracts
 */
contract CofferRedemptionEscrow is ICofferRedemptionEscrow {
    error NoPendingClaim();
    error DepositArrayLengthMismatch();
    error DepositMsgValueMismatch();

    /// @notice Pending ETH claims for holders whose bonds the validator redeemed
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
    /// @notice This function has no access control by design. Any caller can deposit ETH that is credited to the
    /// listed holders at 1:1 face value, which means the caller pays real ETH to inflate claims they do not own. No
    /// invariant is violated: the contract gains exactly as much ETH as it records in claims. Any AML or sanctions
    /// filtering is performed off-chain, matching the trust model of Coffer.receive().
    /// @param _holders Array of holder addresses
    /// @param _amounts Array of amounts owed to each holder
    /// #if_succeeds {:msg "msg.value equals sum of amounts"} msg.value == unchecked_sum(_amounts);
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

    /// @notice Claim escrowed funds from a validator redemption
    /// @notice The _to parameter allows non-payable contracts to redirect funds
    /// @param _to Address to receive the claimed funds
    /// #if_succeeds {:msg "claim sets caller's pending to zero"} sPendingClaims[msg.sender] == 0;
    function claim(address payable _to) external {
        uint256 amount = sPendingClaims[msg.sender];
        require(amount != 0, NoPendingClaim());

        sPendingClaims[msg.sender] = 0;
        emit ClaimWithdrawn(msg.sender, _to, amount);

        Address.sendValue(_to, amount);
    }
}
