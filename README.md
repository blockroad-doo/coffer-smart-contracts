# Coffer

## Quick overview

Coffer is a decentralized and trustless P2P protocol that allows validators issue a bonds for ETH holders to earn interest on their ETH securely, backed by the validator's stake. A holder gets a fixed rate from the validator and locks their ETH in for an upfront agreed period. At the maturity of the offer, the holder can claim their amount with interest. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When holder buys a bond, an NFT is minted so holder can effectively transfer its bond to a third party.

## Whitepaper

A detailed description of the protocol can be found in the [Coffer Whitepaper](https://github.com/ivglavas/coffer-whitepaper/blob/main/whitepaper-v0.1.pdf).

## Architecture

### Core Contracts

1. **CofferFactory.sol**: Factory contract for creating validator offers (Coffers)
2. **Coffer.sol**: Individual Coffer contract managing validator-holder relationships
3. **CofferBondNft.sol**: ERC-721 contract representing transferable coffer receivables

### Libraries

1. **Interest.sol**: Pure function for calculating interest given amount, duration, and interest rate

### Interfaces

1. **ICofferBondNft.sol**: Interface of core contract CofferBondNft.sol
2. **IDepositContract.sol**: This is the Ethereum 2.0 deposit contract interface

### Roles

1. Validators - validator is considered as owner of contract
2. Holders - can call `acceptOffer(uint256)`, `holderWithdrawFromExecution(uint256)` and `holderWithdrawFromConsensus(uint256)`

## Validator considerations

### Steps to create Coffer account

It is important to make `immutable` validator signing public key in order to make sure validator cannot create it later and do malicious stuff. Also it's more gas efficient to read from `immutable` variable rather than from `storage`. So the sigining keys must be created before Coffer contract itself. Yet we need to later assign Coffer contract address to a validator signing keys. So only way to achieve this procedure is through following steps:

1. Create signing keys with `0x00` credentials.
2. Make deposit with 32 ETH using signing keys from 1.
3. Create Coffer contract through CofferFactory. In constructor pass signing public key created in 1.
4. Peform one time `BLSToExecutionChange` to transform `0x00` -> `0x01` with Coffer Contract as withdrawl credential.
5. Call Coffer function `convertToCompounding()` to convert from `0x01` -> `0x02`.

This way reading validator public key costs essentially 0 gas (~3x2 gas for a PUSH32). The value is embedded directly into the contract bytecode at deploy time, so there's no SLOAD. It's treated like a constant in the runtime bytecode. If we remove this complexity and leave public key not immutable, reading costs a cold SLOAD is 2100 gas. Or 100 gas if the slot is already warm in the same transaction (which won't be a case probbably never). So the difference is roughly ~2090 gas per cold read, which is significant if the variable is read frequently, especially from other contracts calling in and in situations in which there are many offers that matured were holders will need to call holderWithdrawFromConsensus(uint128).

### Initialization with inactive validator

Since setting up a Coffer contract takes multiple steps e.g. multiple transactions and consensus layer interactions, it's better to start with inactive validator. If a validator is active at creation, and and some holder buys a bond right away, validator cannot increase its `availableAmount` while there is unmature bond. There is higher chance that validator would like to increase `availableAmount` since validator starts with 32 ETH.

The nice part is that when validator initiates `validatorAddFundsToConsensus(bytes32, uint128)` it doesn't have to wait for the amount to be deposited to validator on beacon chain since contract increases `availableAmount` right away if deposit is successful.

### What is considered safe validator

There are possible atempts in which a bad actor could create malicious Coffer contract. Most obvious example is setting `availableAmount` greater than effective balance of validator on beacon chain. So we should cover some possibilities, how can validator and Coffer contract be defined and what are considered safe and what are not.

#### Unsafe: **Wrong consensus public key passed while creating Coffer contract**

Malicious actor can create Coffer contract and assign wrong public key. It could be a key of radnom honest validator. This should be always checked on execution and consensus layer before any interactions.

#### Unsafe: **Assigning wrong Coffer address to freshly created validator**

When validator with `0x00` credentials is created, it can assign wrong address. This also should be always checked on execution and consensus layer before any interactions.

#### Unsafe: **Unfinished setup of validator**

Validator should end up with `0x02` credentilas so it's safe to interact.

#### Unsafe: **`availableAmount` in Coffer contract is not enough**

Validator can set up `availableAmount` so it's greater than effective balance minus possible penalties that could happened before **minimum** duration has passed. Slashing and leaking for not performing a duties should be considered.

#### Partially safe: **`availableAmount` in Coffer contract is some cases enough**

Validator can set up `availableAmount` so it's greater than effective balance minus possible penalties that could happened before **maximum** duration has passed.

#### Safe: **`availableAmount` in Coffer contract covers all penalties**

Validator can set up `availableAmount` less than effective balance minus possible penalties that could happened before **maximum** duration has passed. When this validator issues first bond, `availableAmount` locks up and cannot be changed until all bonds are repayed.

## Restrictions

### Changing offer parameters

Validators shouldn't be able to change `availableAmount` in Coffer contract while some bonds are not matured. That would gave ability to a validator to manipulate amounts Coffer is responsible to handle for its own benefit at the expense of a holder.

### Granting full exit to holders

Suppose there is a validator with 32 ETH issueing 5 ETH with 2\% yield over a 1-year period. This can make sense if the validator's stake yields 2.5\%. On the other hand, it's obvious that the validator cannot earn 5 ETH in 1 year, so a holder must have the ability to fully exit the validator in order to repay bond and receive the principal with earned interest as expected. Therefore, it's expected for that validator to allow full exits; otherwise, holder wouldn't be able to repay a bond until validator stake enough ETH on consensus layer which could be much greater period than holer accepted.

A validator with allowed full exit can prevent the holder from initiating an exit by simply depositing in the Coffer contract the amount the holder deserves at maturity. When full exits are allowed, every holder with a matured bond can initiate a full exit whenever there is not enough ETH in the Coffer contract. That's why allowing full exit should be an option that can be changed, but only when the validator has no unmatured bonds. This way, validators with a larger stake that makes the available balance exceed the validator's effective balance by at least 32 ETH can make full exits forbidden. In that scenario, holders can only initiate partial withdrawals with the amount needed to fulfill their bond conditions at maturity.
