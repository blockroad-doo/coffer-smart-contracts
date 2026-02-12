# Coffer

---

## 📚 Table of Contents

- [🔍 Quick Overview](#-quick-overview)
- [📄 Whitepaper](#-whitepaper)
- [🏗️ Architecture](#️-architecture)
  - [Core Contracts](#core-contracts)
  - [Libraries](#libraries)
  - [Interfaces](#interfaces)
  - [Roles](#roles)
- [⚙️ Validator Considerations](#️-validator-considerations)
  - [Setup Steps](#setup-steps)
  - [Initialization](#initialization)
  - [Safety Guidelines](#safety-guidelines)
- [🚫 Restrictions](#-restrictions)
  - [Changing Offer Parameters](#changing-offer-parameters)
  - [Granting Full Exit to Holders](#granting-full-exit-to-holders)

---

## 🔍 Quick Overview

Coffer is a **decentralized and trustless P2P protocol** that allows validators to issue bonds for ETH holders to earn interest on their ETH securely, backed by the validator's stake. A holder gets a fixed rate from the validator and locks their ETH in for an upfront agreed period. At the maturity of the offer, the holder can claim their amount with interest. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When a holder buys a bond, an NFT is minted so the holder can effectively transfer its bond to a third party.

> 💡 **Key Features:**
> - Decentralized & trustless
> - Fixed-rate bonds
> - NFT-based transferable bonds
> - Validator stake-backed security

---

## 📄 Whitepaper

A detailed description of the protocol can be found in the [**Coffer Whitepaper**](https://github.com/ivglavas/coffer-whitepaper/blob/main/whitepaper-v0.1.pdf).

---

## 🏗️ Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| **`CofferFactory.sol`** | Factory contract for creating validator offers (Coffers) |
| **`Coffer.sol`** | Individual Coffer contract managing validator-holder relationships |
| **`CofferBondNft.sol`** | ERC-721 contract representing transferable coffer receivables |

### Libraries

| Library | Purpose |
|---------|---------|
| **`Interest.sol`** | Pure function for calculating interest given amount, duration, and interest rate |

### Interfaces

| Interface | Description |
|-----------|-------------|
| **`ICofferBondNft.sol`** | Interface of core contract CofferBondNft.sol |
| **`IDepositContract.sol`** | Ethereum 2.0 deposit contract interface |

### Roles

#### 👤 **Validators**
- Considered as owner of contract
- Full control over Coffer parameters

#### 💰 **Holders**
Can call the following functions:
- `acceptOffer(uint256)`
- `holderWithdrawFromExecution(uint256)`
- `holderWithdrawFromConsensus(uint256)`

---

## ⚙️ Validator Considerations

### Setup Steps

> ⚠️ **Important:** It is crucial to make the validator signing public key `immutable` to ensure the validator cannot create it later and perform malicious activities. This is also more gas efficient (reading from `immutable` variable rather than from `storage`).

The signing keys must be created before the Coffer contract itself. Yet we need to later assign the Coffer contract address to validator signing keys. The only way to achieve this procedure is through the following steps:

- [ ] **Step 1:** Create signing keys with `0x00` credentials
- [ ] **Step 2:** Make deposit with 32 ETH using signing keys from Step 1
- [ ] **Step 3:** Create Coffer contract through CofferFactory (pass signing public key from Step 1)
- [ ] **Step 4:** Perform one-time `BLSToExecutionChange` to transform `0x00` → `0x01` with Coffer Contract as withdrawal credential
- [ ] **Step 5:** Call Coffer function `convertToCompounding()` to convert from `0x01` → `0x02`

> 💡 **Gas Optimization Note:**
> - Reading validator public key costs essentially 0 gas (~3x2 gas for PUSH32)
> - Value is embedded directly into contract bytecode at deploy time
> - Cold SLOAD would cost 2100 gas (or 100 gas if warm)
> - **Savings:** ~2090 gas per cold read

### Initialization

#### 🔄 Starting with Inactive Validator

Since setting up a Coffer contract takes multiple steps (multiple transactions and consensus layer interactions), it's better to start with an **inactive validator**.

**Why?** If a validator is active at creation and some holder buys a bond right away, the validator cannot increase its `availableAmount` while there is an unmatured bond. There is a higher chance that the validator would like to increase `availableAmount` since the validator starts with 32 ETH.

> ✅ **Benefit:** When a validator initiates `validatorAddFundsToConsensus(bytes32, uint128)`, it doesn't have to wait for the amount to be deposited to the validator on the beacon chain since the contract increases `availableAmount` right away if the deposit is successful.

### Safety Guidelines

There are possible attempts in which a bad actor could create malicious Coffer contracts. The most obvious example is setting `availableAmount` greater than the effective balance of the validator on the beacon chain. Below are various scenarios and their safety levels:

#### 🔴 **UNSAFE Scenarios**

> [!CAUTION]
> **Wrong consensus public key passed while creating Coffer contract**
>
> A malicious actor can create a Coffer contract and assign a wrong public key (could be a key of a random honest validator). This should always be checked on execution and consensus layer before any interactions.

> [!CAUTION]
> **Assigning wrong Coffer address to freshly created validator**
>
> When a validator with `0x00` credentials is created, it can assign a wrong address. This should always be checked on execution and consensus layer before any interactions.

> [!CAUTION]
> **Unfinished setup of validator**
>
> Validator should end up with `0x02` credentials so it's safe to interact.

> [!CAUTION]
> **`availableAmount` in Coffer contract is not enough**
>
> Validator can set up `availableAmount` so it's greater than effective balance minus possible penalties that could happen before **minimum** duration has passed. Slashing and leaking for not performing duties should be considered.

#### 🟡 **PARTIALLY SAFE Scenarios**

> [!WARNING]
> **`availableAmount` in Coffer contract is sometimes enough**
>
> Validator can set up `availableAmount` so it's greater than effective balance minus possible penalties that could happen before **maximum** duration has passed.

#### 🟢 **SAFE Scenarios**

> [!NOTE]
> **`availableAmount` in Coffer contract covers all penalties**
>
> Validator can set up `availableAmount` less than effective balance minus possible penalties that could happen before **maximum** duration has passed. When this validator issues the first bond, `availableAmount` locks up and cannot be changed until all bonds are repaid.

---

## 🚫 Restrictions

### Changing Offer Parameters

> [!IMPORTANT]
> Validators **CANNOT** change `availableAmount` in the Coffer contract while some bonds are not matured. This would give the validator the ability to manipulate amounts Coffer is responsible to handle for its own benefit at the expense of a holder.

### Granting Full Exit to Holders

**Example Scenario:**
- Validator with 32 ETH issuing 5 ETH with 2% yield over a 1-year period
- Makes sense if validator's stake yields 2.5%
- Problem: Validator cannot earn 5 ETH in 1 year

> [!NOTE]
> A holder must have the ability to fully exit the validator to repay the bond and receive the principal with earned interest as expected. Therefore, it's expected for that validator to allow full exits; otherwise, the holder wouldn't be able to repay a bond until the validator stakes enough ETH on the consensus layer, which could be a much longer period than the holder accepted.

**Key Points:**
- ✅ Validator with allowed full exit can prevent holder from initiating exit by depositing the required amount
- ✅ When full exits are allowed, every holder with a matured bond can initiate a full exit when there's insufficient ETH
- ✅ Allowing full exit is an option that can be changed (only when validator has no unmatured bonds)
- ✅ Validators with larger stakes (available balance exceeds validator's effective balance by at least 32 ETH) can make full exits forbidden
- ✅ In restricted scenarios, holders can only initiate partial withdrawals with the amount needed to fulfill bond conditions at maturity

---

<div align="center">

**Built with ❤️ for the Ethereum ecosystem**

</div>