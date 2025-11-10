//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Coffer
 * @notice Created by a validator, using CofferFactory smart contract
 * @notice Supports multiple users per validator with transferable receivable NFT instruments
 * @notice Integrates with EIP-7002 for consensus layer withdrawals
 */
contract Coffer is Ownable, ReentrancyGuard {

    address immutable i_validatorAddress;

    constructor(address _validatorAddress) Ownable(_validatorAddress) {

        i_validatorAddress = _validatorAddress;

    }

}