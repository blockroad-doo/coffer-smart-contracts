# Coffer

## Quick overview

Coffer is a decentralized and trustless P2P protocol that allows validators to create offers for ETH holders to earn interest on their ETH securely, backed by the validator's stake. A holder gets a fixed rate from the validator and locks their ETH in for an upfront agreed period. At the maturity of the offer, the holder can claim their amount with interest. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When an offer is accepted, an NFT is minted which represents the receivables of the holder. That way, the holder can transfer its receivables to a third party.

## Whitepaper

A detailed description of the protocol can be found in the [Coffer Whitepaper](https://github.com/ivglavas/coffer-whitepaper/blob/main/whitepaper-v0.1.pdf).

## Architecture

### Core Contracts

1. **CofferFactory.sol**: Factory contract for creating validator offers (Coffers)
2. **Coffer.sol**: Individual Coffer contract managing validator-holder relationships
3. **CofferReceivableNFT.sol**: ERC-721 contract representing transferable coffer receivables

### Libraries

1. **Interest.sol**: Pure function for calculating interest given amount, duration, and interest rate

### Interfaces

1. **ICofferReceivableNFT.sol**: Interface of core contract CofferReceivableNFT.sol
2. **IDepositContract.sol**: This is the Ethereum 2.0 deposit contract interface

### Roles

1. Validators - validator is considered as owner of contract
2. Holders - can call `acceptOffer(uint256)`, `holderWithdrawFromExecution(uint256)` and `holderWithdrawFromConsensus(uint256)`

## Validator considerations

### Steps to create Coffer account

It is important to make `immutable` validator signing public key in order to make sure validator cannot create it later and do malicious stuff. So the sigining keys must be created before Coffer contract itself. Yet we need to later assign Coffer contract address to a validator signing keys. So only way to achieve this procedure is through following steps:

1. Create signing keys with `0x00` credentials.
2. Make deposit with 32 ETH using signing keys from 1.
3. Create Coffer contract through CofferFactory. In constructor pass signing public key created in 1.
4. Peform one time `BLSToExecutionChange` to transform `0x00` -> `0x01` with Coffer Contract as withdrawl credential.
5. Call Coffer function `convertToCompounding()` to convert from `0x01` -> `0x02`.

This way reading validator public key costs essentially 0 gas (~3x2 gas for a PUSH32). The value is embedded directly into the contract bytecode at deploy time, so there's no SLOAD. It's treated like a constant in the runtime bytecode. If we remove this complexity and leave public key not immutable, reading costs a cold SLOAD is 2100 gas. Or 100 gas if the slot is already warm in the same transaction (which won't be a case probbably never). So the difference is roughly ~2090 gas per cold read, which is significant if the variable is read frequently, especially from other contracts calling in and in situations in which there are many offers that matured were holders will need to call holderWithdrawFromConsensus(uint256).

### Initialization of contract

#### Starting with inactive validator

Since setting up a Coffer contract takes multiple steps e.g. multiple transactions and consensus layer interactions, it's better to start with inactive validator. If a validator is active at creation, and offer get accepted before vaidator takes all steps, validator than cannot increase `availableAmount` if tops up it's validator with more than 32 ETH.

#### Multifunction call

TODO: It's best to call a function which will set up initialization of contract in one step. Function should do:

1. Call Coffer function `convertToCompounding()` to convert from `0x01` -> `0x02`.
2. If validator want's add more than 32 ETH to a validator.
3. Increase `availableAmount` if more than 32 ETH is added.
4. Activate validator.

TODO: Use different word instead of "Activate" so there is no confusion between Active validator and Active as can accept offers. Maybe "Offering" or "Accepts offers"...

## Restrictions

### Changing offer parameters

Validators shouldn't be able to change parameters in Coffer contract while some offers are accepted and not expired. While there are ongoing offers, a change in interest rate could drain the available balance much quicker than holders of existing offers expected. Additionally, validators should only be allowed to change parameters when in an inactive state.

### Granting full exit to holders

Suppose there is a validator with 32 ETH offering 5 ETH with 2\% yield over a 1-year period. This can make sense if the validator's stake yields 3\%. On the other hand, it's obvious that the validator cannot earn 5 ETH in 1 year, so a holder must have the ability to fully exit the validator in order to close the offer and receive the principal with earned interest as expected. Therefore, it's expected for that validator to allow full exits; otherwise, that offer would be malicious since the holder's offer period could extend to 5 to 6 years instead of 1 year.

A validator with allowed full exit can prevent the holder from initiating an exit by simply depositing in the Coffer contract the amount the holder deserves at maturity. When full exits are allowed, every holder with a matured offer can initiate a full exit whenever there is not enough ETH in the Coffer contract. That's why allowing full exit should be an option that can be changed, but only when the validator has no active offers. This way, validators with a larger stake that makes the available balance exceed the validator's effective balance by at least 32 ETH can make full exits forbidden. In that scenario, holders can only initiate partial withdrawals with the amount needed to fulfill their offer conditions.
