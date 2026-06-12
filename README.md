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
  - [Deployment](#deployment)
- [Validator Considerations](#validator-considerations)
  - [Setup Steps](#setup-steps)
  - [Evaluating a Coffer](#evaluating-a-coffer)
    - [Before You Buy](#before-you-buy)
    - [Issuance Buffer](#issuance-buffer)
    - [Exit Mechanics](#exit-mechanics)
  - [Redeeming Bonds Early](#redeeming-bonds-early)
- [Risk Factors](#risk-factors)
  - [Extreme Consensus-Layer Events](#extreme-consensus-layer-events)
    - [Non-Finalization (Inactivity Leak)](#non-finalization-inactivity-leak)
    - [Correlated Slashing](#correlated-slashing)
- [Restrictions](#restrictions)
  - [Changing Offer Parameters](#changing-offer-parameters)
  - [Granting Full Exit to Holders](#granting-full-exit-to-holders)
- [Protocol Fees](#protocol-fees)
  - [Fee Curve](#fee-curve)
  - [How the Fee Is Applied](#how-the-fee-is-applied)
  - [Immutability and Administration](#immutability-and-administration)
  - [Fee-Related Events](#fee-related-events)
- [Invariants](#invariants)
  - [Contract Invariants](#contract-invariants-enforced-by-code)
  - [Cross-Layer Invariant](#cross-layer-invariant-not-enforceable-on-chain)

---

## Quick Overview

Coffer is a **permissionless, non-custodial peer-to-peer protocol** that allows validators to issue bonds backed by their stake, enabling ETH holders to earn interest on their ETH. A holder receives a fixed rate from the validator and commits to that rate for an agreed-upon period. At maturity, the holder can claim their bond by calling the contract. This enables validators to unlock liquidity from a major portion of their locked-up ETH. When a holder buys a bond, an NFT is minted, allowing the holder to transfer their bond to a third party. Each bond purchase pays a small, time-based protocol fee deducted from the bond's interest (see [Protocol Fees](#protocol-fees)).

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
| **`FeeCurve.sol`** | Shared, protocol-wide fee schedule. Resolves the current fee (in basis points) and the fee recipient for `buyBond` |

### Libraries

| Library | Purpose |
|---------|---------|
| **`Interest.sol`** | Pure function for calculating interest given amount, duration, and interest rate |

### Interfaces

| Interface | Description |
|-----------|-------------|
| **`ICoffer.sol`** | Minimal interface for reading bond data from a Coffer contract |
| **`ICofferBondNft.sol`** | Interface for the core contract CofferBondNft.sol |
| **`ICofferBondsRedeemedEarly.sol`** | Interface for the pull-based early bond redemption contract |
| **`IFeeCurve.sol`** | Interface for the shared protocol fee schedule contract |
| **`IDepositContract.sol`** | Ethereum 2.0 deposit contract interface |

### Clone Architecture (CWIA)

Each Coffer is deployed as a minimal proxy clone using Solady's `LibClone`. At construction time the factory deploys the shared contracts once (`CofferBondNft`, `CofferBondsRedeemedEarly`, and the `FeeCurve`) and a single Coffer implementation contract. Every `createCoffer` call creates a lightweight clone pointing to that implementation.

88 bytes of immutable data are appended to each clone's bytecode via the Clones With Immutable Args (CWIA) pattern:

| Arg | Type | Byte Offset | Reason |
|-----|------|-------------|--------|
| CofferBondNft address | `address` | 0 | Shared across all Coffers, never changes |
| CofferBondsRedeemedEarly address | `address` | 20 | Shared across all Coffers, never changes |
| Validator BLS public key (part 1) | `bytes32` | 40 | Must be immutable for trust (see [Setup Steps](#setup-steps)) |
| Validator BLS public key (part 2) | `bytes16` | 72 | Must be immutable for trust (see [Setup Steps](#setup-steps)) |

These values are read via `extcodecopy` in assembly, costing ~6 gas versus 2,100 for a cold `SLOAD`. Because the clone's bytecode is deployed once and never changes, CWIA args cannot be altered by anyone: not the validator, not the factory, not an upgrade.

The shared `FeeCurve` address is **not** a CWIA arg. It is stored as an immutable (`FEE_CURVE`) on the `Coffer` implementation itself, set in the implementation's constructor when `CofferFactory` deploys it. Since every clone delegates to that single implementation, all clones read the same `FEE_CURVE` value, and like the CWIA args it cannot be changed after deployment.

The remaining parameters (validator address, interest rate, durations, minimum value, issue size buffer, exit allowed, and the starting balance used to seed the initial `issueSize`) are set via `initialize()` and stored in regular storage. These are the parameters validators can later modify, subject to the [restrictions](#changing-offer-parameters) documented below.

### Roles

Four roles. The Protocol Admin owns the shared `FeeCurve` (set to the deployer of `CofferFactory`) and can update the protocol fee recipient. The Validator is the owner of a given `Coffer` clone (using `Ownable2Step`, with `renounceOwnership` disabled). The Holder is the current owner of a given bond NFT, with authority scoped to that `bondId`. Anyone else can only call the entrypoints listed below.

**Holder** (current owner of `bondId`):
- `Coffer.holderWithdrawFromExecution(uint256)`
- `Coffer.holderWithdrawFromConsensus(uint256)`
- `CofferBondsRedeemedEarly.claim(address payable)` (when there is a pending claim)

**Anyone**:
- `Coffer.buyBond(uint32, uint32) returns (uint256 bondId)` (rejects the validator)
- `Coffer.receive()` (any ETH transfer credits `issueSize`)
- `CofferFactory.createCoffer(...)` (caller becomes the validator of the new Coffer)
- `CofferFactory.predictCofferAddress(...)` (view)
- `CofferBondsRedeemedEarly.deposit(...)` (no access control by design)
- `FeeCurve.claim()` (permissionless poke, sends pooled protocol fees to the current fee recipient)
- `FeeCurve.collectFee()` (no access control, called by Coffer clones during `buyBond` to deposit the fee)

**Protocol Admin** (owner of the shared `FeeCurve`, set to the deployer of `CofferFactory`):
- `FeeCurve.setFeeRecipient(address)` (redirects where future bond fees are sent, the fee amounts themselves are immutable)

**Validator**: every other state-changing function on `Coffer`, e.g. `changeInterestRate`, `changeMinimumAndMaximumDuration`, `changeMinimumValueToAccept`, `changeIssueSize`, `changeIssueSizeBufferBps`, `changeExitAllowed`, `changeCofferActivity`, `validatorWithdrawFromExecution`, `validatorWithdrawFromConsensus`, `validatorAddFundsToConsensus`, `redeemBondsEarly`, and `convertToCompounding`. Protocol-internal calls between contracts (NFT mint/burn/metadata-update, factory registration) are gated to the issuing/owning contract and are not user-callable.

### Deployment

Coffer must only be deployed on chains where the EIP-7002 withdrawal and EIP-7251 consolidation predeploys exist: Ethereum **mainnet** (post-Pectra) and **Hoodi**. On a chain without them, a `staticcall` to the (codeless) predeploy returns empty data, which is read as a zero fee, so a consensus-withdrawal request silently no-ops while still marking the bond `consensusWithdrawClosed` as true. Verify non-empty code at the three system-contract addresses before deploying or buying. This is an accepted, documented deployment constraint of this mainnet/Hoodi-only protocol.

---

## Validator Considerations

### Setup Steps

> **Important:** It is crucial to make the validator signing public key `immutable` to ensure the validator cannot change it later and perform malicious activities. This is also more gas efficient (reading from an `immutable` variable rather than from `storage`).

#### Recommended Flow (0x02 Direct, requires Pectra / EIP-7251)

CofferFactory uses CREATE2 deterministic deployment, so the Coffer address can be predicted before deployment. This allows validators to deposit with `0x02` compounding credentials directly, skipping the `BLSToExecutionChange` and `convertToCompounding()` steps.

1. Create BLS signing keys
2. Call `CofferFactory.predictCofferAddress(yourAddress, pubKeyPart1, pubKeyPart2)` to compute the Coffer contract address
3. Make a deposit between `MIN_ACTIVATION_BALANCE` and `MAX_EFFECTIVE_BALANCE` (consensus-layer parameters, currently 32-2048 ETH) using `0x02` withdrawal credentials pointing to the predicted Coffer address
4. Create Coffer contract through `CofferFactory.createCoffer(...)` with matching `_startingBalance` (deploys at the predicted address)

#### Validators with 0x00 (or 0x01) withdrawal credentials

For validators already created with `0x00` credentials:

1. Create signing keys with `0x00` credentials
2. Make a deposit of `MIN_ACTIVATION_BALANCE` (the consensus-layer minimum, currently 32 ETH) using the signing keys from step 1
3. Create Coffer contract through CofferFactory (pass the signing public key from step 1)
4. Perform one-time `BLSToExecutionChange` to transform `0x00` → `0x01` with the Coffer contract as the withdrawal credential
5. Call Coffer function `convertToCompounding()` to convert from `0x01` → `0x02`

### Evaluating a Coffer

Before buying, verify the conditions below on the execution and consensus layers, and evaluate the risk factors that follow.

#### Before You Buy

**Withdrawal credentials do not match the Coffer address**

EIP-7002 authenticates a withdrawal request against the 20-byte execution address embedded in the validator's credentials. Any mismatch between that address and the Coffer's address makes the validator's stake inaccessible to the Coffer. The check applies to every credential type:

- `0x02` / `0x01`: the 20-byte address embedded in the credentials must equal the Coffer's address.
- `0x00`: no withdrawal address is committed on-chain yet, so buying a bond requires trusting the eventual `BLSToExecutionChange` will target this Coffer (cross-reference *Validator credentials are not 0x02*).

The holder must verify this on the execution and consensus layers before any interaction, regardless of which credential type the validator used.

**Validator credentials are not 0x02**

`convertToCompounding()` and EIP-7002 withdrawal requests require the validator to have 0x02 (compounding) withdrawal credentials. If the validator's credentials are still 0x00 or 0x01, these functions cannot execute. The bond cannot be satisfied as designed until credentials are upgraded to 0x02. The holder must verify credential type on the consensus layer.

#### Issuance Buffer

`issueSizeBufferBps` scales down the validator's issuable capacity:

```
issueSize = consensusBalance * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR
```

where 1% = 100 and BUFFER_DENOMINATOR = 10000 (basis points).

The buffer creates headroom between what the validator issues and what they hold on the consensus layer. A higher buffer means a smaller issueSize.

The validator sets the buffer. The holder evaluates whether the chosen value, combined with the amount of ETH already issued, is adequate for the bond's duration given events the validator may face: missing attestations, going offline, or being slashed. A validator that operates several validators, or several Coffers under common control, carries higher correlated-slashing exposure, since a single cause can slash them together. The holder weighs the buffer against that concentration. A validator operating near the top of its issue size without a buffer that reflects its concentration is one a holder can choose to avoid. Network-wide events (a non-finalizing period, or large-scale correlated slashing) are unbounded and are covered separately under Risk Factors.

#### Exit Mechanics

The beacon chain caps partial withdrawals at the active-validator floor, `MIN_ACTIVATION_BALANCE` (a consensus-layer parameter, currently 32 ETH, which could change in a future fork).

**The contract does not reserve this floor for you.** `issueSize` is seeded purely as `startingBalance * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR`, with no automatic `MIN_ACTIVATION_BALANCE` deduction, and the validator can set `issueSize` to any value while `outstandingBonds == 0`. The holder must therefore verify the floor condition below before buying.

When `exitAllowed` is `false`, holders can recover only via partial withdrawals, which cannot reduce the consensus balance below `MIN_ACTIVATION_BALANCE`. Before buying, the holder should confirm that the total of all outstanding bond maturity values (including the bond being bought) stays within what partial withdrawals can deliver:

```
sum(outstanding bondMaturityValues) <= consensusBalance + executionBalance - MIN_ACTIVATION_BALANCE
```

with margin for the bond's duration. If this does not hold, recovery would require a full exit, which `exitAllowed = false` forbids. The holder would then depend on the validator voluntarily depositing ETH.

When `exitAllowed` is `true`, a holder with a matured bond can initiate a full exit when the contract holds insufficient ETH, so the `MIN_ACTIVATION_BALANCE` floor does not cap recovery. Note: consensus balance is not static. Slashing, inactivity leaks, or missed attestations can reduce it after evaluation, so holders of long-duration bonds should size their margin accordingly.

### Redeeming Bonds Early

A validator can redeem outstanding bonds before maturity by calling `redeemBondsEarly`. This is particularly important when the validator needs `outstandingBonds == 0` to change bond parameters such as interest rate, issue size, exit permissions, or issue size buffer.

When bonds are redeemed early, the maturity values are sent to the `CofferBondsRedeemedEarly` contract rather than directly to each bond holder. Holders then claim their funds individually by calling `claim()` on that contract.

This pull-based pattern prevents a griefing attack where a bond NFT is transferred to a contract that rejects ETH (non-payable or reverting `receive()`). Without this pattern, such a transfer would permanently block the validator from redeeming that bond, locking the `outstandingBonds` counter and consuming `issueSize` capacity indefinitely.

---

## Risk Factors

### Extreme Consensus-Layer Events

Some risks are beyond what any buffer can cover. These are network-wide events where all validators, all holders, and all participants are exposed. The correlated-slashing entry below also distinguishes the bounded, smaller-scale case, which the buffer can address, from the network-wide case, which it cannot. Holders should be aware of these when evaluating a Coffer.

#### Non-Finalization (Inactivity Leak)

The inactivity leak activates when the chain stops finalizing (requires more than one-third of stake offline from a cross-cutting cause). Penalties in this regime grow quadratically over time. A flat percentage buffer cannot track this growth, so in a sustained leak the validator's balance may fall below what is needed to cover outstanding bonds. Holders of bonds that span such a period may face:

1. **Total loss, validator stake depleted**: if the leak reduces the validator's consensus balance to zero or below outstanding bond obligations, there is nothing to recover.
2. **Partial recovery with race**: if some balance remains but is insufficient, holders compete for the execution-layer balance via `holderWithdrawFromExecution`. This race also applies across already-consensus-closed bonds: a bond closed via an EIP-7002 request (its ETH in transit) may claim a cover-in-place bond's present ETH first, with the cover-in-place holder made whole once the in-transit ETH lands. The protocol stays solvent across this first-come-first-served reordering because contract balance plus in-transit consensus ETH always covers the total reserved, so it is harmless in the normal regime. Only the undercollateralized or `exitAllowed = false` cases above can turn the reordering into a shortfall.
3. **Consensus-locked residue**: when `exitAllowed = false`, partial withdrawals are capped at `consensus balance - MIN_ACTIVATION_BALANCE` (the consensus-layer activation floor, currently 32 ETH). Remaining bond value stays on the consensus layer until the validator voluntarily initiates a withdrawal or exits.

#### Correlated Slashing

The consensus-layer slashing penalty scales with the total stake slashed within the same window, which produces two distinct cases. Small-scale correlated slashing, for example a single operator's validators slashed together by a common cause, remains a bounded fraction of the validator's balance. It is part of what the holder weighs when evaluating the buffer and the validator's concentration before buying (see Issuance Buffer), and a buffer can be sized against it. Correlated slashing on Ethereum mainnet has so far been of this scale, with the largest events involving tens of validators.

Large-scale correlated slashing, where a substantial fraction of total network stake is slashed in the same window, is the catastrophic case addressed here. The penalty can approach the entire balance, beyond what any buffer can cover. Like a non-finalizing period, it is a network-wide event: validators lose stake, holders lose bond coverage, and all participants are exposed together. The protocol does not attempt to model or bound it on-chain. Holders of long-duration bonds should be aware that such events, however unlikely, are not covered by any on-chain mechanism.

---

## Restrictions

### Changing Offer Parameters

Validators cannot **CHANGE** `exitAllowed` to `false` in the Coffer contract, and they cannot **INCREASE** `issueSize` or `interestRate`, **INCREASE** `maximumDuration`, or **DECREASE** `issueSizeBufferBps` while there are outstanding bonds. This would give the validator the ability to manipulate the amounts the Coffer contract handles, benefiting themselves at the expense of holders. Every restricted change is gated on `outstandingBonds == 0`, and a bond counts as outstanding while its `bondMaturityValue` is non-zero, including matured bonds that have not yet been redeemed.

Decreasing `issueSize`, `interestRate`, and `maximumDuration`, increasing `issueSizeBufferBps`, as well as turning `exitAllowed` from `false → true`, can only work in the holder's favor.


### Granting Full Exit to Holders

**Example Scenario:**
- Validator at the minimum activation balance (32 ETH) issuing 5 ETH with 2% yield over a 1-year period
- Makes sense if validator's stake yields 2.5%
- Problem: Validator cannot earn 5 ETH in 1 year

A holder must have the ability to fully exit the validator to repay the bond and receive the principal with earned interest as expected. Therefore, the validator is expected to allow full exits. Otherwise, the bond wouldn't be repayable until the validator stakes enough ETH on the consensus layer, which could be a much longer period than the holder accepted.

**Key Points:**
- A validator that allows full exits can prevent a holder from initiating exit by depositing the required ETH amount
- When full exits are allowed, every holder with a matured bond can initiate a full exit when there's insufficient ETH in the Coffer contract
- Allowing full exits is an option that can be changed (only when the validator has no outstanding bonds)
- Validators with larger stakes (consensus balance exceeds the issue size by at least `MIN_ACTIVATION_BALANCE`, currently 32 ETH) can make full exits forbidden
- In restricted scenarios, holders can only initiate partial withdrawals with the amount of ETH needed to fulfill bond conditions at maturity

A simple solution for the validator is to initiate a partial withdrawal so that the Coffer contract balance increases up to the holder's bond value. Or, if the validator has enough ETH outside the validator, they can send it to the Coffer contract to top up the balance for the holder. That will prevent the holder from initiating a full exit.

---

## Protocol Fees

Every bond purchase pays a protocol fee. The fee is taken from the bond's **interest**, never from the principal, so the holder bears it: the maturity value the holder receives at the end is `principal + interest - fee`. At purchase time the fee is deposited into the shared `FeeCurve` contract, where it pools in `sAccruedFees`, and the validator receives the principal minus the fee. The fee recipient, or anyone acting as a permissionless poke, later withdraws the pooled fees by calling `FeeCurve.claim()`.

The fee schedule lives in a single shared `FeeCurve` contract (`src/FeeCurve.sol`), deployed once by `CofferFactory` and referenced by every Coffer clone through the implementation-level immutable `FEE_CURVE`.

### Fee Curve

The fee is time-based: it depends only on how long the `FeeCurve` has been deployed (days since its `START_TIME`), not on the individual bond's duration or size. The curve is sampled from `f(t) = 10% - 9% * e^(-k t)`, with `k` chosen so the curve is ~99% of the way to 10% by year 10. It is stored as a hardcoded, piecewise-linearly interpolated breakpoint table, expressed in basis points (1% = 100 bps):

| Day | 0 | 90 | 180 | 365 | 730 | 1095 | 1460 | 1825 | 2555 | 3650+ |
|-----|---|-----|-----|-----|-----|------|------|------|------|-------|
| Fee (bps) | 100 | 197 | 283 | 432 | 642 | 774 | 857 | 910 | 964 | 990 |

The fee starts at **1%** at launch and rises asymptotically to a **9.9%** plateau after ~10 years (day 3650). Between breakpoints the value is linearly interpolated.

### How the Fee Is Applied

In `Coffer.buyBond`, after the interest is computed:

```
(feeBps, feeRecipient) = FeeCurve.getFee()   // feeBps sampled from the curve at "now"
fee = interest * feeBps / 10000
require(fee <= principal)                       // reverts with FeeExceedsPrincipal otherwise
bondMaturityValue = principal + interest - fee
FeeCurve.collectFee{value: fee}()              // fee pooled in FeeCurve, recipient pulls via claim()
send(validator, principal - fee)
```

- `feeBps` is at most 990 (9.9% of interest), so net interest is always positive and `bondMaturityValue` is always greater than `principal`.
- The `FeeExceedsPrincipal` guard only binds in extreme configurations where the computed fee would exceed the principal (a very high interest rate combined with a very long duration).
- During `buyBond` the fee is deposited into the shared `FeeCurve` via `collectFee()`, where it pools for later `claim()` by the recipient, and `principal - fee` is forwarded to the validator. `issueSize` is decremented by the net `bondMaturityValue`.

### Immutability and Administration

The curve (the fee amounts) is **immutable**: the breakpoints live in code with no setter. The only mutable parameter is the fee **recipient**, changeable by the `FeeCurve` owner (the protocol admin) via `setFeeRecipient(address)`. A holder can therefore rely on the fee for a given purchase date being fixed and publicly verifiable in advance.

The fee depends only on the calendar **date** (days since `FeeCurve` deployment), not on the individual transaction. A `buyBond` signed on one UTC day but included on the next therefore realizes that next day's fee, at most ~1.08 bps of interest higher (the steepest segment of the curve, days 0-90, and zero after the day-3650 plateau). Because the fee is taken from interest (never principal) and is paid to the protocol rather than the validator, this is a bounded, no-loss-of-principal timing nuance, not a value a validator or proposer can manipulate for gain. Holders who want exact terms across a day boundary should price against the next breakpoint's value.

### Fee-Related Events

- `BondFeePaid(uint256 indexed bondId, address indexed feeRecipient, uint128 indexed feeAmount, uint256 feeBps)`: emitted by `Coffer.buyBond` when a non-zero fee is charged.
- `FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient)`: emitted by `FeeCurve.setFeeRecipient`.
- `FeeCollected(uint256 indexed amount)`: emitted by `FeeCurve.collectFee` when a Coffer deposits a fee into the shared pool.
- `FeesClaimed(address indexed to, uint256 indexed amount)`: emitted by `FeeCurve.claim` when pooled fees are sent to the recipient.

---

## Invariants

### Contract Invariants (enforced by code)

- **issueSize conservation**: `issueSize + sum(bondMaturityValues) = totalIssuableCapacity` (capacity = cumulative buffer-adjusted deposits + execution-layer receive() deposits minus explicit issueSize decreases). The protocol fee does not affect this accounting: it is paid out of the validator's principal payout in `buyBond`, not from the bond backing, and each `bondMaturityValue` is already net of the fee
- **receive() issueSize top-up**: `receive()` increases `issueSize` by `msg.value`. Beacon chain withdrawals (EIP-4895) credit balance without code execution and do not trigger `receive()`, so all `receive()` invocations are execution-layer transfers with real ETH backing
- **Parameter monotonicity**: While `outstandingBonds > 0`, `issueSize`, `interestRate`, and `maximumDuration` can only decrease, `issueSizeBufferBps` can only increase, and `exitAllowed` can only go `false`→`true`
- **Validator execution withdrawal bound**: Validator can withdraw from execution up to `issueSize` while preserving `totalConsensusReserved`. Withdrawals are unrestricted when `outstandingBonds == 0`
- **outstandingBonds accuracy**: Equals the number of bonds with `bondMaturityValue > 0`
- **Bond-NFT bijection**: Each active bond maps 1:1 to a live NFT (mint on buy, burn on full withdrawal/redeem)
- **Version monotonicity**: `version` strictly increases on any parameter change that affects holder protections, and on `validatorWithdrawFromExecution`
- **bondMaturityValue >= principal**: `bondMaturityValue = principal + interest - fee`. The protocol fee is capped at 9.9% of the *interest* (never the principal), so net interest stays non-negative and the maturity value never drops below the principal. `buyBond` reverts with `FeeExceedsPrincipal` in the extreme case where the computed fee would exceed the principal

### Cross-Layer Invariant (not enforceable on-chain)

The solvency property:

```
issueSize + sum(bondMaturityValues) <= (consensusBalance + cofferContractBalance)
```

If it holds with `n` outstanding bonds (`n > 0`), it is preserved when the `(n+1)`th bond is bought. Buying a bond decreases `issueSize` and increases `sum(bondMaturityValues)` by the same maturity value, so the left side is unchanged. Consensus withdrawals go to the coffer contract, meaning `consensusBalance` decreases while `cofferContractBalance` increases by the same amount, leaving the right side unchanged. When the validator adds funds to consensus, `issueSize` increases only by the buffer-adjusted deposit amount (`deposit * (BUFFER_DENOMINATOR - issueSizeBufferBps) / BUFFER_DENOMINATOR`), so the left side grows no more than the right side, preserving the inequality.

The base case (`0 → 1`) depends on the validator's initial configuration being correct, which cannot be enforced on-chain (see [Evaluating a Coffer](#evaluating-a-coffer)). When `outstandingBonds == 0`, the property may not hold. The validator can withdraw freely and modify parameters which is harmless since no bond holders exist to be affected. However, if the solvency property does hold when `outstandingBonds == 0`, front-run protection guarantees it is preserved when the first bond is bought.

---

<div align="center">

**Built with love for the Ethereum ecosystem**

</div>
