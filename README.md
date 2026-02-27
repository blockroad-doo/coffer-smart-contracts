# Coffer

---

## Table of Contents

- [Quick Overview](#quick-overview)
- [Whitepaper](#whitepaper)
- [Architecture](#architecture)
  - [Core Contracts](#core-contracts)
  - [Libraries](#libraries)
  - [Interfaces](#interfaces)
  - [Roles](#roles)
- [Validator Considerations](#validator-considerations)
  - [Setup Steps](#setup-steps)
  - [Initialization](#initialization)
  - [Safety Guidelines](#safety-guidelines)
- [Testing](#testing)
  - [Environment Setup](#environment-setup)
  - [Deployment Scripts](#deployment-scripts)
  - [Invariant Testing](#invariant-testing)
  - [Integration Tests (Mock Validation)](#integration-tests-mock-validation)
- [Restrictions](#restrictions)
  - [Changing Offer Parameters](#changing-offer-parameters)
  - [Granting Full Exit to Holders](#granting-full-exit-to-holders)

---

## Quick Overview

Coffer is a **decentralized and trustless peer-to-pool protocol** that allows validators to issue bonds for ETH holders to earn interest on their ETH securely, backed by the validator's stake. A holder gets a fixed rate from the validator and locks their ETH in for an upfront agreed period. At the maturity of the offer, the holder can claim their amount with interest. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When a holder buys a bond, an NFT is minted so the holder can effectively transfer its bond to a third party.

---

## Whitepaper

A detailed description of the protocol can be found in the [**Coffer Whitepaper**] TODO-must fix old version.

---

## Architecture

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
| **`Penalty.sol`** | Pure function for calculating penalties for slashing and missing attestations |

### Interfaces

| Interface | Description |
|-----------|-------------|
| **`ICofferBondNft.sol`** | Interface of core contract CofferBondNft.sol |
| **`IDepositContract.sol`** | Ethereum 2.0 deposit contract interface |

### Roles

#### **Validators**
- Considered as owner of contract
- Full control over Coffer parameters

#### **Holders**
Can call the following functions:
- `buyBond(uint128)`
- `holderWithdrawFromExecution(uint128)`
- `holderWithdrawFromConsensus(uint128)`

---

## Testing

### Environment Setup

The `.env` file lives at the **monorepo root** (`coffer/.env`), one level above `coffer-smart-contracts/`. The deployment scripts reference it via `../.env`.

Example `.env` with all variables the scripts read:

```
HOODI_RPC_URL=http://your-execution-node:8545

# Deployed contract addresses (auto-filled by scripts)
HOODI_COFFER_FACTORY_ADDRESS=
HOODI_COFFER_RECEIVABLE_NFT_ADDRESS=
HOODI_COFFER_ADDRESS=

# Coffer creation parameters
VALIDATOR_PUBLIC_KEY=0x<your-48-byte-bls-public-key>
INTEREST_RATE=2000000
MIN_DURATION=2592000
MAX_DURATION=31536000
MINIMUM_AMOUNT_TO_ACCEPT=100000000000000000
SAFE_TOTAL_STAKE=42000000
ALLOW_EXIT=true
```

Private keys and testnet accounts (`HOODI_V*`, `HOODI_C*`) are also needed for broadcasting transactions but are omitted here for brevity.

Deployment scripts **auto-update** `.env` via FFI (`sed`) — `HOODI_COFFER_FACTORY_ADDRESS`, `HOODI_COFFER_RECEIVABLE_NFT_ADDRESS`, and `HOODI_COFFER_ADDRESS` are written automatically after each script run.

**Hoodi** is the recommended testnet because validators operate there identically to mainnet — the same EIP-7002 withdrawal and EIP-7251 consolidation request contracts are active, making it the closest environment for end-to-end testing.

### Deployment Scripts

Two-step deployment flow in `script/`:

**Step 1 — `DeployCofferFactory.s.sol`**

Deploys `CofferFactory` (which internally deploys `CofferBondNft`) and auto-writes `HOODI_COFFER_FACTORY_ADDRESS` and `HOODI_COFFER_RECEIVABLE_NFT_ADDRESS` to `.env`.

```
cd coffer-smart-contracts
forge script script/DeployCofferFactory.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

**Step 2 — `CreateCoffer.s.sol`**

Reads Coffer offer parameters from `.env` (`VALIDATOR_PUBLIC_KEY`, `INTEREST_RATE`, etc.), calls `factory.createCoffer(...)`, and writes `HOODI_COFFER_ADDRESS` back to `.env`. You must source `.env` first so the `vm.env*()` cheatcodes can read the variables.

```
cd coffer-smart-contracts
set -a && source ../.env && set +a
forge script script/CreateCoffer.s.sol \
  --rpc-url $HOODI_RPC_URL \
  --broadcast \
  --private-key <VALIDATOR_PRIVATE_KEY>
```

> **Note:** `ffi = true` must be set in `foundry.toml` (already configured).

### Invariant Testing

Invariant tests are **excluded from the default test run** via `no_match_path` in `foundry.toml`.

To run them, comment out the `no_match_path` line in `foundry.toml`, then:

```
forge test --mp "test/invariant/*"
```

Default invariant config (`[invariant]`): 512 runs, depth 64, `fail_on_revert = false`.

Strict profile (`[profile.strict.invariant]`): same runs/depth but `fail_on_revert = true`. Run with:

```
forge test --mp "test/invariant/*" --profile strict
```

Four invariant suites: `Coffer`, `CofferFactory`, `CofferBondNft`, `Penalty`.

### Integration Tests (Mock Validation)

Located in `test/integration/mock/` — two fork test files:

- **`EIP7002ForkValidation.t.sol`** — validates our EIP-7002 (withdrawal request) mock against the real mainnet predeploy
- **`EIP7251ForkValidation.t.sol`** — validates our EIP-7251 (consolidation request) mock against the real mainnet predeploy

These tests fork mainnet at a pinned post-Pectra block (22,400,000) to compare fee calculation and request queueing behavior between the real predeploys and our mocks. Tests auto-skip if `MAINNET_RPC_URL` is not set (graceful no-op).

To run them:

1. Uncomment the `[rpc_endpoints]` section in `foundry.toml`
2. Set `MAINNET_RPC_URL` in `.env` (or export it)
3. Run:
   ```
   MAINNET_RPC_URL=http://your-mainnet-node:8545 forge test --mp "test/integration/*" -vvv
   ```

These tests verify that our Solidity mocks (used in unit tests) faithfully replicate the behavior of the real EIP-7002 and EIP-7251 system contracts.

---

## Validator Considerations

### Setup Steps

> **Important:** It is crucial to make the validator signing public key `immutable` to ensure the validator cannot create it later and perform malicious activities. This is also more gas efficient (reading from `immutable` variable rather than from `storage`).

The signing keys must be created before the Coffer contract itself. Yet we need to later assign the Coffer contract address to validator signing keys. The only way to achieve this procedure is through the following steps:

- [ ] **Step 1:** Create signing keys with `0x00` credentials
- [ ] **Step 2:** Make deposit with 32 ETH using signing keys from Step 1
- [ ] **Step 3:** Create Coffer contract through CofferFactory (pass signing public key from Step 1)
- [ ] **Step 4:** Perform one-time `BLSToExecutionChange` to transform `0x00` → `0x01` with Coffer Contract as withdrawal credential
- [ ] **Step 5:** Call Coffer function `convertToCompounding()` to convert from `0x01` → `0x02`

> **Gas Optimization Note:**
> - Reading validator public key costs essentially 0 gas (~3x2 gas for PUSH32)
> - Value is embedded directly into contract bytecode at deploy time
> - Cold SLOAD would cost 2100 gas (or 100 gas if warm)
> - **Savings:** ~2090 gas per cold read

## Safety Guidelines

There are possible attempts in which a bad actor could create malicious Coffer contracts. The most obvious example is setting `issueSize` greater than the effective balance of the validator on the beacon chain. Below are various scenarios and their safety levels:

### Initialization

#### Starting with Inactive Validator

Since setting up a Coffer contract takes multiple steps (multiple transactions and consensus layer interactions), it's better to start with an **inactive validator**.

**Why?** If a validator is active at creation and some holder buys a bond right away, the validator cannot increase its `issueSize` while there is a single unmatured bond. There is a higher chance that the validator would like to increase `issueSize` since the validator starts with 32 ETH.

> **Good thing is:** When a validator initiates `validatorAddFundsToConsensus(bytes32, uint128)`, it doesn't have to wait for the amount to be deposited to the validator on the beacon chain since the contract increases `issueSize` right away if the deposit is successful.

### Validator status

Before buying a bond ceratin conditions must be thoroughly checked both on execution and consensus layer in order for that bond to be safe and be able to repay at maturity.

#### **UNSAFE Scenarios**

> [!CAUTION]
> **Missmatch consensus public and withdrawal credentials**
>
> A malicious actor can create a Coffer contract and assign a wrong public key (could be a key of a random honest validator). Or when a validator with `0x00` credentials is created, it can assign a wrong address. This should always be checked on execution and consensus layer before any interactions.

> [!CAUTION]
> **Unfinished setup of validator**
>
> Validator should set up `0x02` withdrawal credentials so that all Coffer functions are able to execute properly.

> [!CAUTION]
> **`issueSize` in Coffer contract is too big**
>
> Validator can set up `issueSize` so it's greater than effective balance minus possible penalties that could happen before **minimum** duration has passed. Slashing and leaking for not performing duties should be considered. Also validator can be unsafe

> [!CAUTION]
> **`allowExit` should be true**
TODO

#### **PARTIALLY SAFE Scenarios**

> [!WARNING]
> **`issueSize` in Coffer contract is sometimes enough**
>
> Validator can have `issueSize` so it's greater than effective balance minus possible penalties that could happen before **maximum** duration has passed, but are less than effective balance minus possible penalties that could happen before **minimum** duration has passed. We considered this validator partially safe. Holder can choose if it's willing to risk and buy bond from validator.

#### **SAFE Scenarios**

> [!NOTE]
> **`issueSize` in Coffer contract covers all penalties**
>
> Validator should have `issueSize` less than effective balance minus possible penalties that could happen before **maximum** duration has passed. When this validator issues the first bond, `issueSize` locks up and cannot be changed until all bonds are repaid.

### Reasnonable holder risk

If stake of all validators on network drops bellow `safeTotalStake` penalties will be calculated less than it should so buying bond from that validator will start to become a little bit less safer. Holder is taking minor risk there, minor for few reasons.
1. When validator is penalized both hoder and validator lose
2. Because of chrun limit, if total stake of network is droping down, it's droping very slowly
3. Even if all bad things happen, holder is losing very small amount.

---

## Restrictions

### Changing Offer Parameters

> [!IMPORTANT]
> Validators **CANNOT** change `exitsAllowed` in the Coffer contract and it cannot **INCREASE** `issueSize`, `interestRate` and `safeTotalStake` while some bonds are not matured. This would give the validator the ability to manipulate amounts Coffer is responsible to handle for its own benefit at the expense of a holder.

### Granting Full Exit to Holders

**Example Scenario:**
- Validator with 32 ETH issuing 5 ETH with 2% yield over a 1-year period
- Makes sense if validator's stake yields 2.5%
- Problem: Validator cannot earn 5 ETH in 1 year

> [!NOTE]
> A holder must have the ability to fully exit the validator to repay the bond and receive the principal with earned interest as expected. Therefore, it's expected for that validator to allow full exits; otherwise, the holder wouldn't be able to repay a bond until the validator stakes enough ETH on the consensus layer, which could be a much longer period than the holder accepted.

**Key Points:**
- Validator with allowed full exit can prevent holder from initiating exit by depositing the required amount
- When full exits are allowed, every holder with a matured bond can initiate a full exit when there's insufficient ETH on Coffer contract
- Allowing full exit is an option that can be changed (only when validator has no unmatured bonds)
- Validators with larger stakes (issue size exceeds validator's effective balance by at least 32 ETH) can make full exits forbidden
- In restricted scenarios, holders can only initiate partial withdrawals with the amount needed to fulfill bond conditions at maturity

---

## Invariants

TODO

---

<div align="center">

**Built with love for the Ethereum ecosystem**

</div>
