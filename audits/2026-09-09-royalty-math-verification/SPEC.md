# Royalty distribution verification: system model and invariants

Scope: the money path from a Release's address balance to a rights holder's claimable balance.
This document is the single source of truth for the simulator (Sonnet), the test campaign
(Opus), and the prover feasibility study. Every claim below cites the Move source it models.

Source roots (scratchpad `github-root/misofm/`, pinned at the revisions the testnet packages
were published from):

| Package | File | Notes |
|---|---|---|
| `royalty_pool` | `royalty-pool/sources/pool.move` | accumulator pool |
| `royalty_pool` | `royalty-pool/sources/stake.move` | stake share + registrations |
| `routed_stake` | `routed-stake/sources/routed_stake.move` | wraps a stake, routes rewards into a child pool |
| `hikida` | `clones/royalty-pool/build/royalty_pool/sources/dependencies/hikida/hikida.move` | address-balance redeem |
| `bps` | `musicos/build/musicos/sources/dependencies/bps/bps.move` | basis-point math |
| `musicos` | `musicos/sources/release.move` | split sum rule |
| `musicos_actions` | `musicos-actions/release_revenue_distributor/sources/release_revenue_distributor.move` | release → recordings |

Reference commit for the accounting design: royalty-pool `27e2ceb` "Exact accounting:
full-precision reward debt and deposit carry". Its message states the invariant this
campaign must confirm: `balance·P == Σ(shares·index − debt) + carry + forfeited`.

---

## 1. Stage A: Release → Recordings (`release_revenue_distributor::distribute`)

Inputs: a Release with `n` tracks, each with `split_bps: u64`, and a total input `T: u64`
(the amount redeemed from the release's address balance).

Rules (all from `release_revenue_distributor.move` and `bps.move`):

- A1. `Σ split_bps == 10_000` is enforced at Release construction
  (`release.move:233`, `EInvalidTrackSplitsSum`). The distributor does not re-check it.
- A2. Per track `i`: `amount_i = floor(T * split_i / 10_000)` (`bps::apply`, `bps.move:153`,
  via `mul_bps`, which widens before multiplying so no overflow for u64 inputs).
- A3. `amount_i` is sent to the recording's address (`send_funds`), including when
  `amount_i == 0` (no zero-skip in the loop; verify in simulation whether `send_funds` of a
  zero balance is accepted; the Move test suite has a case for it).
- A4. Remainder `R = T − Σ amount_i` is sent back to the Release's own address balance.
- A5. `redeem_all_and_distribute` is a no-op when the settled balance is zero; it does not abort.
- A6. Hikida `redeem_balance_impl` aborts on zero (`ENoValueToRedeem = 1`), so any caller that
  calls redeem directly with `value == 0` aborts. The plugin path guards this (A5).

Derived facts to check:

- A-D1. `0 ≤ R < n` (each floor loses less than one unit, sum over `n` tracks).
- A-D2. `R` is not lost: it stays on the Release and is included in the next `T`. Over
  repeated distributions the remainder is bounded by `n − 1` at any time, and total delivered
  to recordings equals total revenue minus the current remainder.
- A-D3. Distribution is order-independent for a fixed `T` and split vector.
- A-D4. A track with `split_bps == 0` receives 0 forever. (Design: allowed by the sum rule.)
- A-D5. If `T < 10_000 / min_nonzero_split` some tracks receive 0 this round. Dust is not lost
  (A-D2) but accrues on the Release until `T` is large enough. Crank dust floor 10 000 makes
  this rare; the simulator should quantify starvation under adversarial splits (e.g. one track
  at 1 bps).

Invariant tags: **I-A1 (conservation): `T == Σ amount_i + R`** — provable with sui-prover
(loop over a vector with a sum ghost; the prover's spec-reference has vector-sum idioms).
**I-A2 (bound): `R < n`** — provable. **I-A3 (monotone fairness): `amount_i ≤ amount_j` when
`split_i ≤ split_j`** — provable, floor is monotone.

---

## 2. Stage B: Recording → Pool (`pool::deposit` family)

### 2.1 Pool state (`pool.move`)

```
PRECISION P = 1_000_000_000_000_000_000  (u128, = 1e18)   pool.move:95
cumulative_reward_per_share: u256   (call it `index`, in units of P per share)
carry: u128                         (< staked_shares at every fold; sub-share remainder)
staked_shares: u64                  (sum of registered stake amounts)
cumulative_deposits: u128           (monotone; informational)
balance: Balance<T>                 (real funds held by the pool)
```

### 2.2 Deposit (`pool.move:198-220`)

Preconditions: `staked_shares > 0` (else abort `ENoStakedShares = 1`); `value > 0`
(else abort `EInvalidValue = 6`).

```
numerator = value·P + carry                       (u128)
index    += numerator / staked_shares             (u256 ← u128)
carry     = numerator % staked_shares             (u128)
cumulative_deposits += value
balance  += value
```

Overflow analysis (must be reproduced bit-exactly by the model):

- `value·P`: value < 2^64, P < 2^60 → product < 2^124. Plus carry (< 2^64) fits u128. **Never overflows for any u64 value.**
- `numerator / staked_shares` fits u128, widened to u256; `index` grows by at most
  `value·P` per deposit. With lifetime deposits `D` (u128 for `cumulative_deposits`, but
  realistically < 2^64), `index ≤ D·P` (when staked_shares = 1) < 2^128 · 2^60 = 2^188 < 2^256.
  `index` itself cannot overflow before `cumulative_deposits` (u128) overflows, which needs
  2^128 units ≈ 3.4e38 total deposits. Not reachable.
- `carry < staked_shares ≤ 2^64` always (it is a modulus).

### 2.3 Registration (`pool.move:255-275`, `stake.move:46-54`)

`register_stake(pool, stake)` with `amount = stake.value()` and `currency = type_name<Currency>`:

```
assert !stake.has_registration(currency)         (EAlreadyRegistered = 2)
debt = amount·index                              (u256, full precision)
stake.registrations[currency] = Registration{pool_id, debt}
staked_shares += amount
```

**Registrations are keyed by the `Currency` type name, not by pool id**
(`stake.move:36-42`, `VecMap<TypeName, Registration>`; `register_stake` checks
`has_registration(&currency)` and aborts `EAlreadyRegistered`). Consequently a
`Stake<Share>` can be registered in **at most one pool per currency**, and `unregister_stake`
/ `claim_rewards` / `pending_rewards` additionally check that the stored `pool_id` matches
the pool being called (`EPoolIdMismatch = 4`; `pending_rewards` returns 0 instead of
aborting). The model must key registrations by currency and include a negative scenario:
register the same stake in a second pool of the same currency → abort 2. Realistic flows use
one currency (SUI) so this is a one-pool-per-stake rule in practice. `stake::new` asserts
`amount > 0` (`stake.move:73-88`); the amount is `stake.value()` and is immutable.

Note `amount·index`: `amount < 2^64`, `index < 2^188` (from 2.2) → `< 2^252`. Fits u256 with
16 bits of headroom. **The simulator must use true u256 arithmetic and check this product
does not overflow at each step (I-B7).**

### 2.4 Reward calculation (`pool.move:416-418`)

```
calculate_reward(amount, debt, index) = ((amount·index − debt) / P) as u64
```

- `amount·index ≥ debt` always holds because `index` is monotone and `debt` was set as
  `amount·index_at_registration` and only ever increased by `reward·P` on claim, which is
  ≤ the accrued amount (floor). This is invariant **I-B3** (no underflow).
- The u64 cast is safe iff the reward never exceeds the pool balance (I-B1). The cast is
  not checked in Move; a violation aborts the tx (arithmetic error), it does not mint.

### 2.5 Claim (`pool.move:313-339`)

```
reward = calculate_reward(amount, debt, index)
debt  += reward·P
balance.split(reward)     → returned Balance<T> (aborts if balance < reward)
```

Claiming with `reward == 0` is allowed and returns a zero balance (caller must
`destroy_zero` or spend it; `routed_stake::sweep` handles this at
`routed_stake.move:206-236`).

### 2.6 Unregister (`pool.move:282-309`)

```
assert calculate_reward(amount, debt, index) == 0   (ELastClaimIndexMismatch = 5)
staked_shares -= amount
registration removed
```

The sub-unit residue `(amount·index − debt) mod P` (strictly less than P, i.e. less than
one token unit) is **forfeited** and stays in `balance`. This is by design (commit 27e2ceb).
The model tracks it as `forfeited` so conservation can be stated exactly.

### 2.7 Other deposit entry points

- `receive_and_deposit` (`pool.move:225-231`): receives a `Balance<T>` object sent to the
  pool and calls `deposit`. Same preconditions.
- `sweep_and_deposit` (`pool.move:241-249`): redeems the pool's own address balance and
  deposits. Aborts `ENoSettledFunds = 7` on zero settled funds. This is the recovery path
  for funds parked at the pool address by `routed_stake::sweep` when the pool had no
  stakers (see 3.3).

### 2.8 Pool invariants

Let `S` = set of live registrations in pool `p`, each with `(amount_r, debt_r)`.
Let `owed_r = amount_r·index − debt_r` (u256, in P-units).
Let `claimable_r = owed_r / P` (u64), `residue_r = owed_r mod P`.
Let `forfeited` = Σ residues of registrations that have been unregistered (model ghost).
Let `paid_r` = cumulative units transferred out to registration r (model ghost).

| ID | Statement | Kind |
|---|---|---|
| I-B1 | **Solvency**: `balance ≥ Σ claimable_r` for all r ∈ S. A claim never fails for lack of funds. | provable (state invariant) + simulation |
| I-B2 | **Exact conservation**: `balance·P == Σ owed_r + carry + forfeited`. Equivalently `cumulative_deposits·P == Σ (paid_r·P + owed_r) + carry + forfeited` (with `paid` over all registrations ever). | simulation (ghost-state), prover with ghost variables possible |
| I-B3 | **No underflow**: `amount_r·index ≥ debt_r` for all live r. | provable |
| I-B4 | **Carry bound**: `carry < staked_shares` after every deposit; `carry == 0` when pool is fresh. | provable |
| I-B5 | **Index monotone**: `index` never decreases; strictly increases on each deposit with `value·P + carry ≥ staked_shares` (always, since P > 2^59 > any u64 staked_shares? no: staked_shares can be up to 2^64 > P; so index can stay equal when `value·P + carry < staked_shares`, i.e. when staked_shares > 1e18·value. Document; simulator must test staked_shares > 1e18 case). | provable |
| I-B6 | **Pro-rata fairness**: for any registration held with constant amount over a window where index moves from `i0` to `i1`, `paid + claimable == floor(amount·(i1−i0)/P)` accumulated (the existing Move test's `check()` formula). Two registrations with equal amount registered at the same index have identical claimable at all times. | simulation |
| I-B7 | **No overflow**: `amount·index < 2^256`, `value·P + carry < 2^128`, `cumulative_deposits < 2^128`. | provable given a bound on cumulative_deposits; simulation with extreme inputs |
| I-B8 | **Residue bound**: `residue_r < P` (trivial), so **forfeited per unregister < 1 unit**. Total forfeited ≤ number of unregisters (in units). | provable |
| I-B9 | **Claim idempotence**: two consecutive claims with no deposit in between: second returns 0. | provable |
| I-B10 | **Late-joiner isolation**: a stake registered after a deposit has `claimable == 0` for that deposit; it cannot claim any of it later (its debt equals amount·index at registration). | provable |
| I-B11 | **Unregister safety**: unregister only succeeds when `claimable == 0`; the caller can always reach that state by claiming first (I-B1 guarantees the claim succeeds). | provable |
| I-B12 | **Deposit with no stakers aborts** (not silently absorbed). Funds sent to the pool address before any stake exist are not lost: `sweep_and_deposit` recovers them once a staker exists. | simulation of the crank pre-check |

Corner cases to model explicitly:

- staked_shares > P (needs total stake > 1e18 units; u64 permits up to 1.8e19). Index
  increments can be zero; carry accumulates up to staked_shares − 1 ≈ 2^64. `numerator`
  still fits u128. Rewards are eventually paid when carry rolls over. **Simulator must
  test this and confirm conservation still holds.**
- staked_shares == 1 with huge value: index += value·P exactly.
- Single-unit deposits (value = 1) repeated many times with many stakers: exercises carry.
- Register/unregister churn between deposits.
- Register, deposit, transfer stake ownership? Stakes are objects; ownership transfer does
  not touch registration. Out of scope for accounting (no state change).

---

## 3. Stage C: Routed stake (`routed_stake.move`)

A `RoutedStake` wraps a `Stake` (the "recording stake") registered in a recording pool
(`stake_pool`) and forwards its claimed rewards into a child pool (`routed_pool`, the
composition pool) that is derived from the same parent.

### 3.1 Operations

- `new` (L94-112): creates routed stake, derived from parent. Stake is `Option`; starts
  filled by construction in the recording flow.
- `register` (L125-133) / `unregister` (L139-147): delegate to pool `register_stake` /
  `unregister_stake` on the wrapped stake.
- `unstake` (L154-169): takes the stake out; aborts via `stake::destroy` if any registration
  remains (`stake.move:93-106`).
- `restake` (L173-188): puts a stake back.
- `sweep` (L206-236):
  ```
  assert derived_from(parent) for self and routed_pool
  assert stake.is_some()                                   (ENoStake)
  reward = stake_pool.claim_rewards(stake)
  if reward == 0: destroy_zero; return
  if routed_pool.staked_shares() == 0:
      reward.send_funds(routed_pool_address)   // parks at pool address
  else:
      routed_pool.deposit(reward)
  emit RoutedStakeSweptEvent
  ```

### 3.2 Invariants

| ID | Statement | Kind |
|---|---|---|
| I-C1 | **Sweep conservation**: `claimed == deposited_into_child + parked_at_child_address`. No funds are destroyed. | provable |
| I-C2 | **No loss from delayed sweep**: rewards accrued to the routed stake in `stake_pool` remain claimable indefinitely (I-B1 + I-B10 applied to `stake_pool`). Sweeping late yields the same total as sweeping after every deposit, modulo the child pool's own floor/carry when the sum is split differently (**not** bit-identical: depositing 3+4 into the child is not the same as depositing 7 for the child's per-share floors, but conservation I-B2 holds in both; simulator must show `|late − eager| ≤ 1 unit per staker per sweep` and, over the long run, per-staker difference bounded by number of sweeps). | simulation |
| I-C3 | **Parked-funds recoverability**: funds parked by sweep when child has no stakers are exactly recovered by `sweep_and_deposit` once a staker registers (I-B12). | simulation |
| I-C4 | **Composition of floors**: end-to-end from release amount `T` to a composition-pool staker with share `s` of `Σ`: received `≈ T·split_i/10_000 · s/Σ` with total absolute error bounded by `(number of floor operations)` units: floor at A2, floor at recording-pool per-share, floor at child-pool per-share. **Simulator must measure max and mean per-staker error against exact rational.** | simulation (differential against a rational oracle) |

### 3.3 Fragility notes (already visible from reading)

- F1. `sweep` parks funds at the child pool's address when the child has no stakers. Those
  funds are recoverable only through `sweep_and_deposit`, which any caller can invoke once a
  staker exists. If nobody ever registers in the child pool, the funds sit at that address
  forever (not lost on chain, but not distributable). This is the composition-pool cold-start
  case; the crank must pre-check `routed_pool.staked_shares() > 0` or accept parked funds.
- F2. `sweep` requires `stake.is_some()`; a routed stake that has been `unstake`d cannot be
  swept and its recording-pool rewards accrue to the stake object, not the routed stake. If
  the stake is `restake`d later, rewards are intact (I-C2).
- F3. `pool::unregister_stake` forfeits the sub-unit residue by design. Repeated
  register/unregister cycles each forfeit < 1 unit. An attacker cannot extract value from
  this (forfeit benefits the pool balance, which no one can claim without shares; it is dead
  balance). Simulator should quantify total `forfeited` under churn.
- F4. `calculate_reward`'s `as u64` cast is the only unchecked narrowing on the money path.
  It is safe under I-B1; the simulator must assert `owed/P < 2^64` explicitly.
- F5. `cumulative_deposits` is u128 and unbounded; `index` growth is bounded by it. Not a
  realistic risk (see 2.2), but the model must still perform the overflow check.
- F6. Zero-amount `send_funds` in Stage A (A3) for tracks that floor to 0. Confirm behavior
  in the Move test rather than assume; if `send_funds` of zero aborts, a large release with
  a 1-bps track could be un-distributable when `T < 10_000`. The crank dust floor 10 000
  covers exactly this boundary: with `T ≥ 10_000` every track with `split ≥ 1` gets ≥ 1.
  **The simulator must test T in [1, 10_000) with a 1-bps track.**

---

## 4. Differential oracle

The simulator is only trustworthy if it agrees with the real Move VM. The oracle is:

1. Bit-exact Rust model implementing exactly the formulas in §2 and §3 with `u256`.
2. A scenario → Move test generator that emits a `#[test]` performing the same operation
   sequence against the real `royalty_pool` and `routed_stake` packages, asserting after every
   step: `pool.balance().value()`, `pool.staked_shares()`, `pool.cumulative_reward_per_share()`,
   `pool.carry()` (if exposed; otherwise assert pending rewards per stake via
   `pool::pending_rewards`, `pool.move:345-365`), and each stake's `pending_rewards`.
3. `sui move test` run on the generated file. Any mismatch = model bug or Move bug; both are
   findings.

Expected abort codes are part of the oracle: the Move test uses
`#[expected_failure(abort_code = N, location = ...)]` per scenario that is designed to abort.

---

## 5. Realistic magnitudes

| Quantity | Realistic | Stress |
|---|---|---|
| stake amounts | 1 .. 1e13 (SUPPLY in existing tests) | 1 .. 2^64−1 |
| deposits | 1 .. 1e12 | 1 .. 2^64−1 |
| stakers per pool | 1 .. 100 | 1 .. 10_000 (vector cost only) |
| tracks per release | 1 .. 20 | 1 .. 1024 (splits sum 10 000 with 1-bps minimum) |
| deposits per pool lifetime | 1 .. 1e5 | 1e7 (for cumulative overflow check, do the arithmetic, not the loop) |

---

## 6. Deliverables of the campaign

- `royalty-sim` Rust crate (Sonnet): see `TASKS-SONNET.md`.
- Fuzz + differential campaign (Opus): see `TASKS-OPUS.md`; output `REPORT.md`.
- Prover feasibility: see `PROVER.md`. Status: the prover runs locally and already proves
  function-level specs for `deposit`, `register_stake`, and `claim_rewards` against the real
  package (`prover-pool-specs/`), covering I-B3, I-B4, I-B5, I-B9, I-B10 and the per-deposit
  step of I-B2.
- Final verification (Fable): re-run the campaign from the manifest, reproduce any finding
  against Move directly, and decide publication.
