# Coffer

---

## Table of Contents

- [Quick Overview](#quick-overview)
- [Whitepaper](#whitepaper)
- [Architecture](#architecture)
  - [Core Contracts](#core-contracts)
  - [Libraries](#libraries)
  - [Interfaces](#interfaces)
  - [Clone Architecture (CWIA)](#clone-architecture-cwia)
  - [Roles](#roles)
- [Testing](#testing)
  - [Environment Setup](#environment-setup)
  - [Deployment Scripts](#deployment-scripts)
  - [Unit Tests](#unit-tests)
  - [Fuzz Testing](#fuzz-testing)
  - [Invariant Testing](#invariant-testing)
  - [Integration Tests (Mock Validation)](#integration-tests-mock-validation)
- [Validator Considerations](#validator-considerations)
  - [Setup Steps](#setup-steps)
  - [Safety Guidelines](#safety-guidelines)
    - [Configuration Requirements](#configuration-requirements)
    - [Undercollateralized Scenarios](#undercollateralized-scenarios)
    - [Collateralized Without Maximum-Duration Penalties Applied](#collateralized-without-maximum-duration-penalties-applied)
    - [Collateralized Against Understated Penalties](#collateralized-against-understated-penalties)
    - [Fully Collateralized Scenarios](#fully-collateralized-scenarios)
  - [Redeeming Bonds Early](#redeeming-bonds-early)
- [Risk Factors](#risk-factors)
  - [safeTotalStake Drift](#safetotalstake-drift)
  - [Protocol-Upgrade Risk for Long-Duration Bonds](#protocol-upgrade-risk-for-long-duration-bonds)
  - [Inactivity-Leak Regime](#inactivity-leak-regime)
  - [Correlated Slashing](#correlated-slashing)
- [Restrictions](#restrictions)
  - [Changing Offer Parameters](#changing-offer-parameters)
  - [Granting Full Exit to Holders](#granting-full-exit-to-holders)
- [Invariants](#invariants)
  - [Contract invariants](#contract-invariants-enforced-by-code)
  - [Cross-Layer Safety invariant](#cross-layer-safety-invariant-not-enforceable-on-chain)
  - [Known Approximation](#known-approximation)

---

## Quick Overview

Coffer is a **decentralized and trustless peer-to-pool protocol** that allows validators to issue bonds backed by their stake, enabling ETH holders to earn interest on their ETH securely. A holder receives a fixed rate from the validator and commits to that rate for an agreed-upon period. At maturity, the holder can claim their bond trustlessly. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When a holder buys a bond, an NFT is minted, allowing the holder to transfer their bond to a third party.

---

## Whitepaper

A detailed description of the protocol can be found in the [**Coffer Whitepaper**](https://github.com/tomoglava/coffer-whitepaper/blob/main/whitepaper-v0.1.pdf).

---

## Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| **`CofferFactory.sol`** | Factory contract for creating Coffers |
| **`Coffer.sol`** | Individual Coffer contract managing validator-holder relationships |
| **`CofferBondNft.sol`** | ERC-721 contract representing transferable Coffer bonds |
| **`CofferBondsRedeemedEarly.sol`** | Pull-based claim contract for early bond redemptions |

### Libraries

| Library | Purpose |
|---------|---------|
| **`Interest.sol`** | Pure function for calculating interest given amount, duration, and interest rate |
| **`Penalty.sol`** | Pure function for calculating penalties for slashing and missing attestations |

### Interfaces

| Interface | Description |
|-----------|-------------|
| **`ICoffer.sol`** | Minimal interface for reading bond data from a Coffer contract |
| **`ICofferBondNft.sol`** | Interface for the core contract CofferBondNft.sol |
| **`ICofferBondsRedeemedEarly.sol`** | Interface for the pull-based early bond redemption contract |
| **`IDepositContract.sol`** | Ethereum 2.0 deposit contract interface |

### Clone Architecture (CWIA)

Each Coffer is deployed as a minimal proxy clone using Solady's `LibClone`. The factory deploys a single Coffer implementation contract at construction time; every `createCoffer` call creates a lightweight clone pointing to it.

88 bytes of immutable data are appended to each clone's bytecode via the Clones With Immutable Args (CWIA) pattern:

| Arg | Type | Byte Offset | Reason |
|-----|------|-------------|--------|
| CofferBondNft address | `address` | 0 | Shared across all Coffers, never changes |
| CofferBondsRedeemedEarly address | `address` | 20 | Shared across all Coffers, never changes |
| Validator BLS public key (part 1) | `bytes32` | 40 | Must be immutable for trust (see [Setup Steps](#setup-steps)) |
| Validator BLS public key (part 2) | `bytes16` | 72 | Must be immutable for trust (see [Setup Steps](#setup-steps)) |

These values are read via `extcodecopy` in assembly, costing ~6 gas versus 2,100 for a cold `SLOAD`. Because the clone's bytecode is deployed once and never changes, CWIA args cannot be altered by anyone: not the validator, not the factory, not an upgrade.

The remaining parameters (interest rate, durations, minimum value, safe total stake, exit allowed, validator address) are set via `initialize()` and stored in regular storage. These are the parameters validators can later modify, subject to the [restrictions](#changing-offer-parameters) documented below.

### Roles

Three roles. The Validator is the owner of a given `Coffer` clone (using `Ownable2Step`; `renounceOwnership` is disabled). The Holder is the current owner of a given bond NFT, with authority scoped to that `bondId`. Anyone else can only call the entrypoints listed below.

**Holder** (current owner of `bondId`):
- `Coffer.holderWithdrawFromExecution(uint256)`
- `Coffer.holderWithdrawFromConsensus(uint256)`
- `CofferBondsRedeemedEarly.claim(address payable)` (when there is a pending claim)

**Anyone**:
- `Coffer.buyBond(uint32, uint32)` (rejects the validator)
- `Coffer.receive()` (any ETH transfer credits `issueSize`)
- `CofferFactory.createCoffer(...)` (caller becomes the validator of the new Coffer)
- `CofferFactory.predictCofferAddress(...)` (view)
- `CofferBondsRedeemedEarly.deposit(...)` (no access control by design)

**Validator**: every other state-changing function on `Coffer`. Protocol-internal calls between contracts (NFT mint/burn/metadata-update, factory registration) are gated to the issuing/owning contract and are not user-callable.

---

## Testing

### Environment Setup

The `.env` file lives at the **monorepo root** (`coffer/.env`), one level above `coffer-smart-contracts/`. The deployment scripts reference it via `../.env`.

Example `.env` with all variables the scripts read:

```
HOODI_RPC_URL=http://your-execution-node:8545

# Deployed contract addresses (auto-filled by scripts)
HOODI_COFFER_FACTORY_ADDRESS=
HOODI_COFFER_BOND_NFT_ADDRESS=
HOODI_COFFER_BONDS_REDEEMED_EARLY_ADDRESS=
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

Deployment scripts **auto-update** `.env` via FFI (`sed`): `HOODI_COFFER_FACTORY_ADDRESS`, `HOODI_COFFER_BOND_NFT_ADDRESS`, `HOODI_COFFER_BONDS_REDEEMED_EARLY_ADDRESS`, and `HOODI_COFFER_ADDRESS` are written automatically after each script run.

**Hoodi** is the recommended testnet because validators operate there identically to mainnet. The same EIP-7002 withdrawal and EIP-7251 consolidation request contracts are active, making it the closest environment for end-to-end testing.

### Deployment Scripts

Two-step deployment flow in `script/`:

**Step 1 - `DeployCofferFactory.s.sol`**

Deploys `CofferFactory` (which internally deploys `CofferBondNft` and `CofferBondsRedeemedEarly`) and auto-writes `HOODI_COFFER_FACTORY_ADDRESS`, `HOODI_COFFER_BOND_NFT_ADDRESS`, and `HOODI_COFFER_BONDS_REDEEMED_EARLY_ADDRESS` to `.env`.

```
cd coffer-smart-contracts
forge script script/DeployCofferFactory.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --private-key <DEPLOYER_PRIVATE_KEY>
```

**Step 2 - `CreateCoffer.s.sol`**

Reads Coffer offer parameters from `.env` (`VALIDATOR_PUBLIC_KEY`, `INTEREST_RATE`, etc.), calls `factory.createCoffer(...)`, and writes `HOODI_COFFER_ADDRESS` back to `.env`. You must source `.env` first so the `vm.env*()` cheatcodes can read the variables.

```
cd coffer-smart-contracts
set -a && source ../.env && set +a
forge script script/CreateCoffer.s.sol \
  --rpc-url $HOODI_RPC_URL \
  --broadcast \
  --private-key <VALIDATOR_PRIVATE_KEY>
```

> **Note:** Both deployment scripts use FFI (`sed`) to write back to `.env`. `ffi` is shipped commented out in `foundry.toml` (line 7) for safety; uncomment `ffi = true` before running either script.

### Invariant Testing

Invariant tests (also called stateful fuzz tests) explore random sequences of contract calls to verify that critical properties always hold, no matter what order or combination of actions occurs.

There are six invariant suites: `Coffer`, `CofferFactory`, `CofferBondNft`, `CofferBondsRedeemedEarly`, `Interest`, and `Penalty`.

#### Enabling invariant tests

By default the `no_match_path` line in `[profile.default]` of `foundry.toml` is **active**, which excludes invariant and integration tests from a normal `forge test` run. To include them, either run with an explicit path filter (e.g. `forge test --mp "test/invariant/*"`) or comment that line out.

#### Non-strict vs strict mode

Each suite that includes intentionally-reverting handler functions (invalid inputs, expected failures) has two test contracts: a **non-strict** variant and a **strict** variant.

| Mode | `fail_on_revert` | What it tests |
|------|-------------------|---------------|
| **Non-strict** | `false` | Runs all handlers, including ones that intentionally revert. Verifies invariants hold even when invalid calls are mixed in. |
| **Strict** | `true` | Runs only valid handlers (excludes intentionally-reverting ones). Any unexpected revert fails the test immediately. |

#### Running non-strict mode

The default `[invariant]` section in `foundry.toml` already has `fail_on_revert = false`, so non-strict invariants run with no config changes:

```toml
[invariant]
runs = 512
depth = 64
fail_on_revert = false
```

Then run:

```
forge test --mp "test/invariant/*"
```

#### Running strict mode

The strict profile (`[profile.strict.invariant]`) already has `fail_on_revert = true`. No config changes needed:

```
forge test --mp "test/invariant/*" --profile strict
```

### Integration Tests (Mock Validation)

Located in `test/integration/mock/`, with two fork test files:

- **`EIP7002ForkValidation.t.sol`**: validates our EIP-7002 (withdrawal request) mock against the real mainnet predeploy
- **`EIP7251ForkValidation.t.sol`**: validates our EIP-7251 (consolidation request) mock against the real mainnet predeploy

These tests fork mainnet at a pinned post-Pectra block (22,400,000) to compare fee calculation and request queueing behavior between the real predeploys and our mocks. Tests auto-skip if `MAINNET_RPC_URL` is not set (graceful no-op).

To run them:

1. Uncomment the `[rpc_endpoints]` section in `foundry.toml`
2. Set `MAINNET_RPC_URL` in `.env` (or export it)
3. Run:
   ```
   MAINNET_RPC_URL=http://your-mainnet-node:8545 forge test --mp "test/integration/*" -vvv
   ```

These tests verify that our Solidity mocks (used in unit tests) faithfully replicate the behavior of the real EIP-7002 and EIP-7251 system contracts.

### Unit Tests

Located in `test/unit/`, covering all contracts and libraries individually:

| Test File | Covers |
|-----------|--------|
| `CofferMainOps.t.sol` | Bond lifecycle: buy, withdraw from execution/consensus |
| `CofferValidatorOps.t.sol` | Validator-side operations: withdrawals, parameter changes |
| `CofferHolderOps.t.sol` | Holder-side operations |
| `CofferFactory.t.sol` | Factory deployment and `createCoffer` |
| `CofferBondNft.t.sol` | NFT mint/burn and access control |
| `CofferBondNftTokenUri.t.sol` | On-chain token URI metadata |
| `CofferBondsRedeemedEarlyTest.t.sol` | Pull-based claim and deposit |
| `Interest.t.sol` | Interest calculation edge cases |
| `Penalty.t.sol` | Penalty calculations for slashing and attestations |
| `EIP7002Mock.t.sol` | EIP-7002 mock contract behavior |
| `EIP7251Mock.t.sol` | EIP-7251 mock contract behavior |
| `GasComparison.t.sol` | Gas usage benchmarks |
| `RefundMarginalGas.t.sol` | On-chain refund branch gas measurement |

Run with:

```
forge test --mp "test/unit/*"
```

### Fuzz Testing

Foundry fuzz tests are configured with `runs = 1024` in `foundry.toml`. Functions
that accept bounded numeric inputs (durations, amounts, rates) are automatically
fuzzed with random values when run via `forge test`. No separate config is needed.

```
forge test --mp "test/unit/*"
```

---

## Validator Considerations

### Setup Steps

> **Important:** It is crucial to make the validator signing public key `immutable` to ensure the validator cannot change it later and perform malicious activities. This is also more gas efficient (reading from an `immutable` variable rather than from `storage`).

#### Recommended Flow (0x02 Direct, requires Pectra / EIP-7251)

CofferFactory uses CREATE2 deterministic deployment, so the Coffer address can be predicted before deployment. This allows validators to deposit with `0x02` compounding credentials directly, skipping the `BLSToExecutionChange` and `convertToCompounding()` steps.

- [ ] **Step 1:** Create BLS signing keys
- [ ] **Step 2:** Call `CofferFactory.predictCofferAddress(yourAddress, pubKeyPart1, pubKeyPart2)` to compute the Coffer contract address
- [ ] **Step 3:** Make a deposit with 32–2048 ETH using `0x02` withdrawal credentials pointing to the predicted Coffer address
- [ ] **Step 4:** Create Coffer contract through `CofferFactory.createCoffer(...)` with matching `_startingBalance` (deploys at the predicted address)

#### Validators with 0x00 (or 0x01) withdrawal credentials

For validators already created with `0x00` credentials:

- [ ] **Step 1:** Create signing keys with `0x00` credentials
- [ ] **Step 2:** Make a deposit with 32 ETH using signing keys from Step 1
- [ ] **Step 3:** Create Coffer contract through CofferFactory (pass signing public key from Step 1)
- [ ] **Step 4:** Perform one-time `BLSToExecutionChange` to transform `0x00` → `0x01` with the Coffer contract as the withdrawal credential
- [ ] **Step 5:** Call Coffer function `convertToCompounding()` to convert from `0x01` → `0x02`

### Safety Guidelines

There are scenarios in which a bad actor could create malicious Coffer contracts. The most obvious example is setting `issueSize` greater than the consensus balance of the validator on the beacon chain. Before buying a bond, certain conditions must be thoroughly checked on both the execution and consensus layers for that bond to be safe and repayable at maturity. Below are the configuration prerequisites the holder must verify, followed by various scenarios and their collateralization levels:

#### Configuration Requirements

> [!CAUTION]
> **Mismatched consensus public key and withdrawal credentials**
>
> EIP-7002 authenticates a withdrawal request against the 20-byte execution address embedded in the validator's credentials. Any mismatch between that address and the Coffer's address makes the validator's stake inaccessible to the Coffer. The check applies to every credential type:
>
> - `0x02` / `0x01`: the 20-byte address embedded in the credentials must equal the Coffer's address.
> - `0x00`: no withdrawal address is committed on-chain yet, so buying a bond requires trusting the eventual `BLSToExecutionChange` will target this Coffer (cross-reference *Unfinished setup of validator*).
>
> The holder must verify this on the execution and consensus layers before any interaction, regardless of which credential type the validator used.

> [!CAUTION]
> **Unfinished setup of validator**
>
> The validator should set up `0x02` withdrawal credentials so that all Coffer functions can execute properly.

#### Undercollateralized Scenarios

> [!CAUTION]
> **`issueSize` in Coffer contract is too big**
>
> A validator can set `issueSize` to be greater than consensus balance minus possible penalties that could happen before **minimum** duration has passed. Slashing and inactivity leak penalties should be considered.

> [!CAUTION]
> **`exitAllowed` should be true if validator `consensus balance - issueSize - maxPenalties` is less than 32 ETH**
>
> If the validator's `consensus balance - issueSize - maxPenalties` is less than 32 ETH, partial withdrawals cannot bring enough ETH to the Coffer contract (the beacon chain limits partial withdrawals to maintain a 32 ETH minimum for compounding validators). In this scenario, the holder's only way to claim a matured bond is a full validator exit. If `exitAllowed` is `false`, the holder cannot trigger an exit and must wait for the validator to voluntarily deposit enough ETH or for the validator to earn enough ETH through network issuance, which can take much longer than the bond duration.

#### Collateralized Without Maximum-Duration Penalties Applied

> [!WARNING]
> **`issueSize` in Coffer contract is sometimes enough**
>
> A validator can have an `issueSize` that is greater than the consensus balance minus possible penalties that could happen before **maximum** duration has passed, but is less than the consensus balance minus possible penalties that could happen before **minimum** duration has passed. Such a validator is considered partially collateralized. The holder can choose if they are willing to take the risk and buy a bond from the validator.

#### Collateralized Against Understated Penalties

> [!WARNING]
> **`safeTotalStake` should be less than network total stake**
>
> If `safeTotalStake` is set higher than the actual network total stake, the penalty calculations in the `Penalty` library will **underestimate** real penalties. This happens because both `correlationPenalty` and `missingAttestations` divide by `safeTotalStake`, and a larger denominator produces a smaller penalty estimate. As a result, the `issueSize` (which subtracts estimated penalties from the consensus balance) will be larger than it should be, meaning the validator may not have enough balance to cover all outstanding bonds if it gets high penalties. Validators should set `safeTotalStake` to a value slightly **below** the real network total stake to ensure penalties are conservatively estimated.

#### Fully Collateralized Scenarios

> [!TIP]
> **`issueSize` in Coffer contract covers all penalties**
>
> A validator should have an `issueSize` less than the consensus balance minus possible penalties that could happen before **maximum** duration has passed. When this validator issues its first bond, `issueSize` cannot be increased until all bonds are repaid, preserving collateralization for existing holders.

> [!TIP]
> **`exitAllowed` is properly configured**
>
> If the validator's `consensus balance - issueSize - maxPenalties < 32 ETH`, `exitAllowed` must be set to `true`. Partial withdrawals cannot bring enough ETH to the Coffer contract because the beacon chain enforces a 32 ETH minimum for compounding validators. Without exit capability, the holder cannot trigger a full validator exit and must depend on the validator voluntarily depositing ETH or earning enough through network issuance, which can take much longer than the bond duration.

> [!TIP]
> **`safeTotalStake` is at or below actual network stake**
>
> Since both `correlationPenalty` and `missingAttestations` in the `Penalty` library divide by `safeTotalStake`, a value that is too high will underestimate penalties, making the `issueSize` appear safer than it actually is. A conservative (slightly below actual) value ensures penalty estimates are accurate or slightly overestimated, protecting bond holders.

### Redeeming Bonds Early

A validator can redeem outstanding bonds before maturity by calling `redeemBondsEarly`. This is
particularly important when the validator needs `outstandingBonds == 0` to change bond parameters
such as interest rate, issue size, exit permissions, or safe total stake.

When bonds are redeemed early, the maturity values are sent to the `CofferBondsRedeemedEarly`
contract rather than directly to each bond holder. Holders then claim their funds individually
by calling `claim()` on that contract.

This pull-based pattern prevents a griefing attack where a bond NFT is transferred to a contract
that rejects ETH (non-payable or reverting `receive()`). Without this pattern, such a transfer
would permanently block the validator from redeeming that bond, locking the `outstandingBonds`
counter and consuming `issueSize` capacity indefinitely.

---

## Risk Factors

### `safeTotalStake` Drift

If the stake of all validators on the network drops below `safeTotalStake`, penalties will be calculated slightly lower than they should be. This makes buying a bond from that validator slightly less safe. The risk is extremely minor for two reasons. First, when a validator is penalized, both the holder and the validator lose money, so the validator has no incentive to cause such an event. Second, because of the churn limit, the total stake of the network can only drop very slowly.

### Protocol-Upgrade Risk for Long-Duration Bonds

Penalty calculations in `Penalty.sol` snapshot four consensus-layer parameters (`INITIAL_SLASHING_PENALTY_QUOTIENT`, `PROPORTIONAL_SLASHING_MULTIPLIER`, `SLASHING_PENALTY_DURATION_IN_EPOCH`, `MISSED_ATTESTATION_FACTOR`) at the time of deployment. Ethereum executes roughly one to two hard forks per year and has historically adjusted these values (`PROPORTIONAL_SLASHING_MULTIPLIER`, `INITIAL_SLASHING_PENALTY_QUOTIENT`). Because Coffer contracts are non-upgradeable, values baked in at deployment persist regardless of future consensus-layer changes. If a fork **increases** penalty strength, the on-chain calculation underestimates the real worst-case and `issueSize` provisioning may be insufficient to cover a validator's actual post-penalty balance, exposing holders to partial recovery. If a fork **decreases** penalty strength, the on-chain calculation overestimates, which disadvantages the validator (reduced `issueSize` headroom) but keeps holders fully covered. The risk is asymmetric (holder loses or validator inconvenienced) and grows with bond duration. Holders should size bond duration against their tolerance for this tail risk.

### Inactivity-Leak Regime

`Penalty.sol` models finalizing-chain attestation penalties correctly but does not model the inactivity-leak regime. In a sustained non-finalization period, `get_inactivity_penalty_deltas` accumulates a per-validator inactivity score that grows by +4 per missed epoch, so the cumulative penalty over a leak is quadratic in epochs rather than linear. The Coffer formula is linear, so under a sustained leak the `issueSize` provisioning may sit above the validator's actual post-leak balance. Holders of bonds that span such a period may face one or more of:

1. **Total loss, validator stake depleted**: if the leak reduces the validator's consensus balance to zero or below the sum of outstanding bond obligations plus accrued penalties, there is nothing to recover on the consensus layer. Both validator and holders lose their stake.
2. **Partial recovery with race**: if some balance remains but is insufficient to cover all outstanding bonds, holders compete with each other and with the validator (via `validatorWithdrawFromExecution`, bounded by `issueSize`) for whatever ETH sits on the execution layer. First callers of `holderWithdrawFromExecution` recover in full; later callers recover partially or not at all.
3. **Consensus-locked residue**: when `exitAllowed = false` and the partial consensus withdrawal caps at `consensus_balance - 32 ETH` (the active-validator floor), any remainder of `bondMaturityValue` stays on the consensus layer. The single-shot guard on `holderWithdrawFromConsensus` prevents re-triggering, so the holder must wait for the validator to voluntarily initiate a partial withdrawal, to exit the validator, or (for 0x01 credentials) for auto-sweeping of rewards above 32 ETH. Compounding (0x02) validators have no auto-sweep until effective balance exceeds 2048 ETH.

The single-shot guard on `holderWithdrawFromConsensus` is intentional: it prevents a matured holder from repeatedly pulling a compounding validator's rewards down to 32 ETH. The trade-off is the regime above. Sustained non-finalization has never occurred on Ethereum mainnet post-Merge; triggering it requires more than one-third of stake offline from a cross-cutting cause. Holders should factor this regime-change tail risk into their safety evaluation.

### Correlated Slashing

The `slashing()` function in `Penalty.sol` computes the correlation-penalty term as `balance * balance * PROPORTIONAL_SLASHING_MULTIPLIER / safeTotalStake`. This matches the Ethereum consensus-layer formula **only when this validator is the sole slashed validator within the `SLASHING_PENALTY_DURATION_IN_EPOCH` window** (currently 8192 epochs, roughly 36 days). The true consensus-layer formula is `effective_balance * min(sum(slashings) * 3, total_balance) / total_balance`, which saturates at the full effective balance once `sum(slashings) * 3` reaches `total_balance`. In a large correlated slashing event the realized penalty can approach the validator's full effective balance, several orders of magnitude above the Coffer formula's estimate. At saturation `issueSize` provisioning sits well above the validator's real post-penalty balance, and the Coffer may be unable to honour all outstanding bonds. No on-chain bound is offered for this tail because any finite bounded choice would be arbitrary, and bounding by the full effective balance would set `issueSize = 0` in every deploy and make the protocol unusable. Large-scale correlated slashing has not occurred on post-Merge Ethereum mainnet; the largest correlated events in the public record involve tens of validators. Holders of long-duration bonds should factor this tail risk into their safety evaluation.

---

## Restrictions

### Changing Offer Parameters

> [!IMPORTANT]
> Validators cannot **CHANGE** `exitAllowed` to `false` in the Coffer contract, and they cannot **INCREASE** `issueSize`, `interestRate`, `safeTotalStake`, or `maximumDuration` while there are unmatured bonds. This would give the validator the ability to manipulate the amounts the Coffer contract handles, benefiting themselves at the expense of holders.

> [!NOTE]
> Decreasing `issueSize`, `interestRate`, `safeTotalStake`, and `maximumDuration` as well as turning `exitAllowed` from `false → true`, can only make the contract safer for the holder.


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
- Validators with larger stakes (consensus balance exceeds the issue size by at least 32 ETH) can make full exits forbidden
- In restricted scenarios, holders can only initiate partial withdrawals with the amount of ETH needed to fulfill bond conditions at maturity

> [!NOTE]
> A simple solution for the validator is to initiate a partial withdrawal so that the Coffer contract balance increases up to the holder's bond value. Or, if the validator has enough ETH outside the validator, they can send it to the Coffer contract to top up the balance for the holder. That will prevent the holder from initiating a full exit.

---

## Invariants

### Contract Invariants (enforced by code)

- **issueSize conservation**: `issueSize + sum(bondMaturityValues) = totalIssuableCapacity` (capacity = cumulative penalty-adjusted deposits + execution-layer receive() deposits minus explicit issueSize decreases)
- **receive() issueSize top-up**: `receive()` increases `issueSize` by `msg.value`. Beacon chain withdrawals (EIP-4895) credit balance without code execution and do not trigger `receive()`, so all `receive()` invocations are execution-layer transfers with real ETH backing
- **Parameter monotonicity**: While `outstandingBonds > 0`: `issueSize`, `interestRate`, `safeTotalStake`, `maximumDuration` can only decrease; `exitAllowed` can only go `false`→`true`
- **Validator execution withdrawal bound**: Validator can withdraw from execution up to `issueSize` while preserving `totalConsensusReserved`; unrestricted when `outstandingBonds == 0`
- **outstandingBonds accuracy**: Equals the number of bonds with `bondMaturityValue > 0`
- **Bond-NFT bijection**: Each active bond maps 1:1 to a live NFT (mint on buy, burn on full withdrawal/redeem)
- **Version monotonicity**: `version` strictly increases on any parameter change that affects holder safety
- **bondMaturityValue >= principal**: Interest is always non-negative

### Cross-Layer Safety Invariant (not enforceable on-chain)

The solvency property:

```
issueSize + sum(bondMaturityValues) <= (consensusBalance + cofferContractBalance) - maxPenalties
```

If it holds with `n` outstanding bonds (`n > 0`), it is preserved when the `(n+1)`th bond is bought. Buying a bond decreases `issueSize` and increases `sum(bondMaturityValues)` by the same maturity value, so the left side is unchanged. Consensus withdrawals go to the coffer contract, meaning `consensusBalance` decreases while `cofferContractBalance` increases by the same amount, leaving the right side unchanged. When the validator adds funds to consensus, `issueSize` increases only by the penalty-adjusted deposit amount (`deposit - maxPenalties`), so the left side grows no more than the right side, preserving the inequality. 

The base case (`0 → 1`) depends on the validator's initial configuration being correct, which cannot be enforced on-chain (see [Safety Guidelines](#safety-guidelines)). When `outstandingBonds == 0`, the property may not hold. The validator can withdraw freely and modify parameters which is harmless since no bond holders exist to be affected. However, if the solvency property does hold when `outstandingBonds == 0`, front-run protection guarantees it is preserved when the first bond is bought.

### Known Approximation

`validatorAddFundsToConsensus` computes issueSize additively per deposit: `issueSize += addMaximumPenalty(deposit)`. Due to the quadratic correlation penalty (`balance² * 3 / (safeTotalStake * 1e18)`), the sum of individual penalty-adjusted amounts is slightly larger than the true combined penalty-adjusted amount. This means issueSize may be marginally overestimated. The overestimate is negligible for typical validator sizes.

---

<div align="center">

**Built with love for the Ethereum ecosystem**

</div>
