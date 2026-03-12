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
- [Testing](#testing)
  - [Environment Setup](#environment-setup)
  - [Deployment Scripts](#deployment-scripts)
  - [Invariant Testing](#invariant-testing)
  - [Integration Tests (Mock Validation)](#integration-tests-mock-validation)
- [Validator Considerations](#validator-considerations)
  - [Setup Steps](#setup-steps)
  - [Initialization](#initialization)
  - [Safety Guidelines](#safety-guidelines)
- [Restrictions](#restrictions)
  - [Changing Offer Parameters](#changing-offer-parameters)
  - [Granting Full Exit to Holders](#granting-full-exit-to-holders)

---

## Quick Overview

Coffer is a **decentralized and trustless peer-to-pool protocol** that allows validators to issue bonds backed by their stake, enabling ETH holders to earn interest on their ETH securely. A holder receives a fixed rate from the validator and locks in their ETH for an agreed-upon period. At maturity, the holder can claim their bond trustlessly. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When a holder buys a bond, an NFT is minted, allowing the holder to transfer their bond to a third party.

---

## Whitepaper

A detailed description of the protocol can be found in the [**Coffer Whitepaper**](https://github.com/tomoglava/coffer-whitepaper/blob/main/whitepaper-v0.1.pdf).

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
| **`ICofferBondNft.sol`** | Interface for the core contract CofferBondNft.sol |
| **`IDepositContract.sol`** | Ethereum 2.0 deposit contract interface |

### Roles

#### **Validators**
- Considered the owner of the contract
- Full control over Coffer parameters

#### **Holders**
Can call the following functions:
- `buyBond(uint32, uint32) external payable`
- `holderWithdrawFromExecution(uint256) external`
- `holderWithdrawFromConsensus(uint256) external payable`

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
MINIMUM_VALUE_TO_ACCEPT=100000000000000000
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

> **Important:** It is crucial to make the validator signing public key `immutable` to ensure the validator cannot change it later and perform malicious activities. This is also more gas efficient (reading from an `immutable` variable rather than from `storage`).

The signing keys must be created before the Coffer contract itself. Yet we need to later assign the Coffer contract address to validator signing keys. The only way to achieve this is through the following steps:

- [ ] **Step 1:** Create signing keys with `0x00` credentials
- [ ] **Step 2:** Make a deposit with 32 ETH using signing keys from Step 1
- [ ] **Step 3:** Create Coffer contract through CofferFactory (pass signing public key from Step 1)
- [ ] **Step 4:** Perform one-time `BLSToExecutionChange` to transform `0x00` → `0x01` with the Coffer contract as the withdrawal credential
- [ ] **Step 5:** Call Coffer function `convertToCompounding()` to convert from `0x01` → `0x02`

> **Gas Optimization Note:**
> - Reading validator public key costs essentially 0 gas (~3x2 gas for PUSH32)
> - Value is embedded directly into contract bytecode at deploy time
> - Cold SLOAD would cost 2100 gas (or 100 gas if warm)
> - **Savings:** ~2090 gas per cold read

## Safety Guidelines

There are scenarios in which a bad actor could create malicious Coffer contracts. The most obvious example is setting `issueSize` greater than the effective balance of the validator on the beacon chain. Before buying a bond, certain conditions must be thoroughly checked on both the execution and consensus layers for that bond to be safe and repayable at maturity. Below are various scenarios and their safety levels:

#### **UNSAFE Scenarios**

> [!CAUTION]
> **Mismatched consensus public key and withdrawal credentials**
>
> A malicious actor can create a Coffer contract and assign a wrong public key (e.g., a key of a random honest validator). Or when a validator with `0x00` credentials is created, it can assign a wrong address. This should always be checked on the execution and consensus layers before any interactions.

> [!CAUTION]
> **Unfinished setup of validator**
>
> The validator should set up `0x02` withdrawal credentials so that all Coffer functions can execute properly.

> [!CAUTION]
> **`issueSize` in Coffer contract is too big**
>
> A validator can set `issueSize` to be greater than effective balance minus possible penalties that could happen before **minimum** duration has passed. Slashing and inactivity leak penalties should be considered.

> [!CAUTION]
> **`exitAllowed` should be true if validator effective balance minus `issueSize` is less than 32**
>
> If the validator's effective balance minus `issueSize` is less than 32 ETH, partial withdrawals cannot bring enough ETH to the Coffer contract (the beacon chain limits partial withdrawals to maintain a 32 ETH minimum for compounding validators). In this scenario, the holder's only way to claim a matured bond is a full validator exit. If `exitAllowed` is `false`, the holder cannot trigger an exit and must wait for the validator to voluntarily deposit enough ETH or for the validator to earn enough ETH through network issuance, which can take much longer than the bond duration. Therefore, any validator where `effective balance - issueSize < 32 ETH` **must** set `exitAllowed = true` to be considered safe.


#### **PARTIALLY SAFE Scenarios**

> [!WARNING]
> **`issueSize` in Coffer contract is sometimes enough**
>
> A validator can have an `issueSize` that is greater than the effective balance minus possible penalties that could happen before **maximum** duration has passed, but is less than effective balance minus possible penalties that could happen before **minimum** duration has passed. Such a validator is considered partially safe. The holder can choose if they are willing to take the risk and buy a bond from the validator.

> [!WARNING]
> **`safeTotalStake` should be less than network total stake**
>
> If `safeTotalStake` is set higher than the actual network total stake, the penalty calculations in the `Penalty` library will **underestimate** real penalties. This happens because both `correlationPenalty` and `missingAttestations` divide by `safeTotalStake`, and a larger denominator produces a smaller penalty estimate. As a result, the `issueSize` (which subtracts estimated penalties from the effective balance) will be larger than it should be, meaning the validator may not have enough balance to cover all outstanding bonds if it gets high penalties. Validators should set `safeTotalStake` to a value slightly **below** the real network total stake to ensure penalties are conservatively estimated.

#### **SAFE Scenarios**

> [!TIP]
> **`issueSize` in Coffer contract covers all penalties**
>
> A validator should have an `issueSize` less than the effective balance minus possible penalties that could happen before **maximum** duration has passed. When this validator issues its first bond, `issueSize` becomes locked and cannot be changed until all bonds are repaid.

> [!TIP]
> **`exitAllowed` is properly configured**
>
> If the validator's `effective balance - issueSize < 32 ETH`, `exitAllowed` must be set to `true`. Partial withdrawals cannot bring enough ETH to the Coffer contract because the beacon chain enforces a 32 ETH minimum for compounding validators. Without exit capability, the holder cannot trigger a full validator exit and must depend on the validator voluntarily depositing ETH or earning enough through network issuance, which can take much longer than the bond duration.

> [!TIP]
> **`safeTotalStake` is conservatively set**
>
> `safeTotalStake` must be set at or below the actual network total stake. Since both `correlationPenalty` and `missingAttestations` in the `Penalty` library divide by `safeTotalStake`, a value that is too high will underestimate penalties, making the `issueSize` appear safer than it actually is. A conservative (slightly below actual) value ensures penalty estimates are accurate or slightly overestimated, protecting bond holders.

### Reasonable Holder Risk

If the stake of all validators on the network drops below `safeTotalStake`, penalties will be calculated slightly lower than they should be, so buying a bond from that validator will become slightly less safe. The holder is taking an extremely minor risk for a few reasons:
1. When a validator is penalized, both the holder and the validator lose
2. Because of the churn limit, if the total stake of the network is dropping, it drops very slowly
3. Even if the worst things happen, the holder loses a very small amount of ETH.

---

## Restrictions

### Changing Offer Parameters

> [!IMPORTANT]
> Validators **CANNOT** change `exitAllowed` in the Coffer contract, and they cannot **INCREASE** `issueSize`, `interestRate`, or `safeTotalStake` while there are unmatured bonds. This would give the validator the ability to manipulate the amounts the Coffer contract handles, benefiting themselves at the expense of holders.

> [!NOTE]
> Since the validator can decrease `issueSize`, `interestRate`, and `safeTotalStake` whenever the Coffer contract becomes unsafe for whatever reason, the validator can adjust these parameters to restore safety while there are outstanding bonds. The only situation in which the validator cannot make the Coffer contract safe is if `exitAllowed` isn't true and `issueSize` is too low to adjust. But if the validator has `exitAllowed` set to true, or set to false with sufficient `issueSize`, it is extremely unlikely for the Coffer contract to reach a severely unsafe state.


### Granting Full Exit to Holders

**Example Scenario:**
- Validator with 32 ETH issuing 5 ETH with 2% yield over a 1-year period
- Makes sense if validator's stake yields 2.5%
- Problem: Validator cannot earn 5 ETH in 1 year

> [!NOTE]
> A holder must have the ability to fully exit the validator to repay the bond and receive the principal with earned interest as expected. Therefore, the validator is expected to allow full exits; otherwise, the bond wouldn't be repayable until the validator stakes enough ETH on the consensus layer, which could be a much longer period than the holder accepted.

**Key Points:**
- A validator that allows full exits can prevent a holder from initiating exit by depositing the required ETH amount
- When full exits are allowed, every holder with a matured bond can initiate a full exit when there's insufficient ETH in the Coffer contract
- Allowing full exits is an option that can be changed (only when the validator has no unmatured bonds)
- Validators with larger stakes (effective balance exceeds the issue size by at least 32 ETH) can make full exits forbidden
- In restricted scenarios, holders can only initiate partial withdrawals with the amount of ETH needed to fulfill bond conditions at maturity

> [!NOTE]
> A simple solution for the validator is to initiate a partial withdrawal so that the Coffer contract balance increases up to the holder's bond value. Or, if the validator has enough ETH outside the validator, they can send it to the Coffer contract to top up the balance for the holder. That will prevent the holder from initiating a full exit.

---

## Invariants

### Contract Invariants (enforced by code)

- **issueSize conservation**: `issueSize + sum(active bondMaturityValues) = totalIssuableCapacity` (capacity = cumulative penalty-adjusted deposits minus explicit issueSize decreases)
- **Parameter monotonicity**: While `outstandingBonds > 0`: issueSize, interestRate, safeTotalStake can only decrease; exitAllowed can only go false→true
- **Validator execution withdrawal lock**: Validator cannot withdraw from execution while `outstandingBonds > 0`
- **outstandingBonds accuracy**: Equals the number of bonds with `bondMaturityValue > 0`
- **Bond-NFT bijection**: Each active bond maps 1:1 to a live NFT (mint on buy, burn on full withdrawal/redeem)
- **Version monotonicity**: `version` strictly increases on any parameter change that affects holder safety
- **bondMaturityValue >= principal**: Interest is always non-negative

### Cross-Layer Safety Invariant (not enforceable on-chain)

The solvency property:

```
issueSize + sum(active bondMaturityValues) <= (effectiveBalance_consensus + cofferBalance) - maxPenalties
```

Justified by:

- Validator sets issueSize ≤ effectiveBalance - maxPenalties at creation
- issueSize can only decrease while bonds outstanding (except validatorAddFundsToConsensus which adds penalty-adjusted deposit amount)
- cofferBalance is locked — validator cannot withdraw from execution while outstandingBonds > 0
- Consensus withdrawals go to coffer contract (total consensus + coffer stays constant minus penalties)
- For the nth bond with (n-1) bonds outstanding: remaining issueSize is already reduced by bonds 1..(n-1), and since issueSize cannot be increased, bond n is safe if the initial configuration was correct

### Known Approximation

`validatorAddFundsToConsensus` computes issueSize additively per deposit: `issueSize += addMaximumPenalty(deposit)`. Due to the quadratic correlation penalty (`balance² * 3 / (safeTotalStake * 1e18)`), the sum of individual penalty-adjusted amounts is slightly larger than the true combined penalty-adjusted amount. This means issueSize may be marginally overestimated. The overestimate is negligible for typical validator sizes.

---

<div align="center">

**Built with love for the Ethereum ecosystem**

</div>
