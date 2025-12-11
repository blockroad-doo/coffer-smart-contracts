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

1. Validators
2. Holders

### Critical considirations

